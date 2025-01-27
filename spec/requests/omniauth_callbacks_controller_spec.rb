# frozen_string_literal: true

require 'rails_helper'
require 'single_sign_on'

RSpec.describe Users::OmniauthCallbacksController do
  fab!(:user) { Fabricate(:user) }

  before do
    OmniAuth.config.test_mode = true
  end

  after do
    Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:google_oauth2] = nil
    Rails.application.env_config["omniauth.origin"] = nil
    OmniAuth.config.test_mode = false
  end

  describe ".find_authenticator" do
    it "fails if a provider is disabled" do
      SiteSetting.enable_twitter_logins = false

      expect do
        Users::OmniauthCallbacksController.find_authenticator("twitter")
      end.to raise_error(Discourse::InvalidAccess)
    end

    it "fails for unknown" do
      expect do
        Users::OmniauthCallbacksController.find_authenticator("twitter1")
      end.to raise_error(Discourse::InvalidAccess)
    end

    it "finds an authenticator when enabled" do
      SiteSetting.enable_twitter_logins = true

      expect(Users::OmniauthCallbacksController.find_authenticator("twitter"))
        .not_to eq(nil)
    end

    context "with a plugin-contributed auth provider" do

      let :provider do
        provider = Auth::AuthProvider.new
        provider.authenticator = Class.new(Auth::Authenticator) do
          def name
            'ubuntu'
          end

          def enabled?
            SiteSetting.ubuntu_login_enabled
          end
        end.new

        provider.enabled_setting = "ubuntu_login_enabled"
        provider
      end

      before do
        DiscoursePluginRegistry.register_auth_provider(provider)
      end

      after do
        DiscoursePluginRegistry.reset!
      end

      it "finds an authenticator when enabled" do
        SiteSetting.stubs(:ubuntu_login_enabled).returns(true)

        expect(Users::OmniauthCallbacksController.find_authenticator("ubuntu"))
          .to be(provider.authenticator)
      end

      it "fails if an authenticator is disabled" do
        SiteSetting.stubs(:ubuntu_login_enabled).returns(false)

        expect { Users::OmniauthCallbacksController.find_authenticator("ubuntu") }
          .to raise_error(Discourse::InvalidAccess)
      end
    end
  end

  context 'Google Oauth2' do
    before do
      SiteSetting.enable_google_oauth2_logins = true
    end

    it "should display the failure message if needed" do
      get "/auth/failure"
      expect(response.status).to eq(200)
      expect(response.body).to include(I18n.t("login.omniauth_error.generic"))
    end

    describe "request" do
      it "should error for non existant authenticators" do
        post "/auth/fake_auth"
        expect(response.status).to eq(404)
        get "/auth/fake_auth"
        expect(response.status).to eq(403)
      end

      it "should error for disabled authenticators" do
        SiteSetting.enable_google_oauth2_logins = false
        post "/auth/google_oauth2"
        expect(response.status).to eq(404)
        get "/auth/google_oauth2"
        expect(response.status).to eq(403)
      end

      it "should handle common errors" do
        OmniAuth::Strategies::GoogleOauth2.any_instance.stubs(:mock_request_call).raises(
          OAuth::Unauthorized.new(mock().tap { |m| m.stubs(:code).returns(403); m.stubs(:message).returns("Message") })
        )
        post "/auth/google_oauth2"
        expect(response.status).to eq(302)
        expect(response.location).to include("/auth/failure?message=request_error")

        OmniAuth::Strategies::GoogleOauth2.any_instance.stubs(:mock_request_call).raises(JWT::InvalidIatError.new)
        post "/auth/google_oauth2"
        expect(response.status).to eq(302)
        expect(response.location).to include("/auth/failure?message=invalid_iat")
      end

      it "should only start auth with a POST request" do
        post "/auth/google_oauth2"
        expect(response.status).to eq(302)
        get "/auth/google_oauth2"
        expect(response.status).to eq(200)
      end

      context "with CSRF protection enabled" do
        before { ActionController::Base.allow_forgery_protection = true }
        after { ActionController::Base.allow_forgery_protection = false }

        it "should be CSRF protected" do
          post "/auth/google_oauth2"
          expect(response.status).to eq(302)
          expect(response.location).to include("/auth/failure?message=csrf_detected")

          post "/auth/google_oauth2", params: { authenticity_token: "faketoken" }
          expect(response.status).to eq(302)
          expect(response.location).to include("/auth/failure?message=csrf_detected")

          get "/session/csrf.json"
          token = response.parsed_body["csrf"]

          post "/auth/google_oauth2", params: { authenticity_token: token }
          expect(response.status).to eq(302)
        end

        it "should not be CSRF protected if it is the only auth method" do
          get "/auth/google_oauth2"
          expect(response.status).to eq(200)
          SiteSetting.enable_local_logins = false
          get "/auth/google_oauth2"
          expect(response.status).to eq(302)
        end
      end
    end

    context "without an `omniauth.auth` env" do
      it "should return a 404" do
        get "/auth/eviltrout/callback"
        expect(response.code).to eq("404")
      end
    end

    describe 'when user not found' do
      let(:email) { "somename@gmail.com" }
      before do
        OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
          provider: 'google_oauth2',
          uid: '123545',
          info: OmniAuth::AuthHash::InfoHash.new(
            email: email,
            name: 'Some Name',
            first_name: "Some",
            last_name: "Name"
          ),
          extra: {
            raw_info: OmniAuth::AuthHash.new(
              email_verified: true,
              email: email,
              family_name: 'Huh',
              given_name: "Some Name",
              gender: 'male',
              name: "Some name Huh",
            )
          }
        )

        Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:google_oauth2]
      end

      it 'should return the right response' do
        destination_url = '/somepath'
        Rails.application.env_config["omniauth.origin"] = destination_url

        events = DiscourseEvent.track_events { get "/auth/google_oauth2/callback.json" }
        expect(events.any? { |e| e[:event_name] == :before_auth }).to eq(true)
        expect(events.any? { |e| e[:event_name] === :after_auth && Auth::GoogleOAuth2Authenticator === e[:params][0] && !e[:params][1].failed? }).to eq(true)

        expect(response.status).to eq(302)

        data = JSON.parse(cookies[:authentication_data])

        expect(data["email"]).to eq(email)
        expect(data["username"]).to eq("Some_Name")
        expect(data["auth_provider"]).to eq("google_oauth2")
        expect(data["email_valid"]).to eq(true)
        expect(data["can_edit_username"]).to eq(true)
        expect(data["name"]).to eq("Some Name")
        expect(data["destination_url"]).to eq(destination_url)
      end

      it 'should return the right response for staged users' do
        Fabricate(:user, username: "Staged_User", email: email, staged: true)

        destination_url = '/somepath'
        Rails.application.env_config["omniauth.origin"] = destination_url

        events = DiscourseEvent.track_events { get "/auth/google_oauth2/callback.json" }
        expect(events.any? { |e| e[:event_name] == :before_auth }).to eq(true)
        expect(events.any? { |e| e[:event_name] === :after_auth && Auth::GoogleOAuth2Authenticator === e[:params][0] && !e[:params][1].failed? }).to eq(true)

        expect(response.status).to eq(302)

        data = JSON.parse(cookies[:authentication_data])

        expect(data["email"]).to eq(email)
        expect(data["username"]).to eq("Staged_User")
        expect(data["auth_provider"]).to eq("google_oauth2")
        expect(data["email_valid"]).to eq(true)
        expect(data["can_edit_username"]).to eq(true)
        expect(data["name"]).to eq("Some Name")
        expect(data["destination_url"]).to eq(destination_url)
      end

      it 'should include destination url in response' do
        destination_url = '/cookiepath'
        cookies[:destination_url] = destination_url

        get "/auth/google_oauth2/callback.json"

        data = JSON.parse(cookies[:authentication_data])
        expect(data["destination_url"]).to eq(destination_url)
      end

      it 'should return an associate url when multiple login methods are enabled' do
        get "/auth/google_oauth2/callback.json"
        expect(response.status).to eq(302)

        data = JSON.parse(cookies[:authentication_data])
        expect(data["associate_url"]).to start_with('/associate/')

        SiteSetting.enable_local_logins = false
        get "/auth/google_oauth2/callback.json"
        data = JSON.parse(cookies[:authentication_data])
        expect(data["associate_url"]).to eq(nil)
      end

      describe 'when site is invite_only' do
        before do
          SiteSetting.invite_only = true
        end

        it 'should return the right response without any origin' do
          get "/auth/google_oauth2/callback.json"

          expect(response.status).to eq(302)

          data = JSON.parse(response.cookies["authentication_data"])

          expect(data["requires_invite"]).to eq(true)
        end

        it 'returns the right response for an invalid origin' do
          Rails.application.env_config["omniauth.origin"] = "/invitesinvites"

          get "/auth/google_oauth2/callback.json"

          expect(response.status).to eq(302)
        end

        it 'should return the right response when origin is invites page' do
          origin = Rails.application.routes.url_helpers.invite_url(
            Fabricate(:invite).invite_key,
            host: Discourse.base_url
          )

          Rails.application.env_config["omniauth.origin"] = origin

          get "/auth/google_oauth2/callback.json"

          expect(response.status).to eq(302)
          expect(response).to redirect_to(origin)

          data = JSON.parse(response.cookies["authentication_data"])

          expect(data["requires_invite"]).to eq(nil)
        end
      end
    end

    describe 'when user has been verified' do
      before do
        OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
          provider: 'google_oauth2',
          uid: '123545',
          info: OmniAuth::AuthHash::InfoHash.new(
            email: user.email,
            name: 'Some name',
            nickname: 'Somenickname'
          ),
          extra: {
            raw_info: OmniAuth::AuthHash.new(
              email_verified: true,
              email: user.email,
              family_name: 'Huh',
              given_name: user.name,
              gender: 'male',
              name: "#{user.name} Huh",
            )
          },
        )

        Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:google_oauth2]
      end

      it 'should return the right response' do
        expect(user.email_confirmed?).to eq(false)

        events = DiscourseEvent.track_events do
          get "/auth/google_oauth2/callback.json"
        end

        expect(events.map { |event| event[:event_name] }).to include(:user_logged_in, :user_first_logged_in)

        expect(response.status).to eq(302)

        data = JSON.parse(cookies[:authentication_data])

        expect(data["authenticated"]).to eq(true)
        expect(data["awaiting_activation"]).to eq(false)
        expect(data["awaiting_approval"]).to eq(false)
        expect(data["not_allowed_from_ip_address"]).to eq(false)
        expect(data["admin_not_allowed_from_ip_address"]).to eq(false)

        user.reload
        expect(user.email_confirmed?).to eq(true)
      end

      it 'should return the authenticated response with the correct path for subfolders' do
        set_subfolder "/forum"
        events = DiscourseEvent.track_events do
          get "/auth/google_oauth2/callback.json"
        end

        expect(response.headers["Set-Cookie"].match(/^authentication_data=.*; path=\/forum/)).not_to eq(nil)

        expect(events.map { |event| event[:event_name] }).to include(:user_logged_in, :user_first_logged_in)

        expect(response.status).to eq(302)

        data = JSON.parse(response.cookies["authentication_data"])

        expect(data["authenticated"]).to eq(true)
        expect(data["awaiting_activation"]).to eq(false)
        expect(data["awaiting_approval"]).to eq(false)
        expect(data["not_allowed_from_ip_address"]).to eq(false)
        expect(data["admin_not_allowed_from_ip_address"]).to eq(false)

        user.reload
        expect(user.email_confirmed?).to eq(true)
      end

      it "should confirm email even when the tokens are expired" do
        user.email_tokens.update_all(confirmed: false, expired: true)

        user.reload
        expect(user.email_confirmed?).to eq(false)

        events = DiscourseEvent.track_events do
          get "/auth/google_oauth2/callback.json"
        end

        expect(events.map { |event| event[:event_name] }).to include(:user_logged_in, :user_first_logged_in)

        expect(response.status).to eq(302)

        user.reload
        expect(user.email_confirmed?).to eq(true)
      end

      it "should treat a staged user the same as an unregistered user" do
        user.update!(staged: true, registration_ip_address: nil)

        user.reload
        expect(user.staged).to eq(true)
        expect(user.registration_ip_address).to eq(nil)

        events = DiscourseEvent.track_events do
          get "/auth/google_oauth2/callback.json"
        end

        expect(events.map { |event| event[:event_name] }).to include(:before_auth, :after_auth)

        expect(response.status).to eq(302)

        data = JSON.parse(cookies[:authentication_data])
        expect(data["username"]).to eq("Somenickname")

        user.reload
        expect(user.staged).to eq(true)
        expect(user.registration_ip_address).to eq(nil)

        # Now register
        UsersController.any_instance.stubs(:honeypot_value).returns(nil)
        UsersController.any_instance.stubs(:challenge_value).returns(nil)
        post "/u.json", params: {
          name: "My new name",
          username: "mynewusername",
          email: user.email
        }

        expect(response.status).to eq(200)

        user.reload
        expect(user.staged).to eq(false)
        expect(user.registration_ip_address).to be_present
        expect(user.name).to eq("My new name")
      end

      it "should activate user with matching email" do
        user.update!(password: "securepassword", active: false, registration_ip_address: "1.1.1.1")

        user.reload
        expect(user.active).to eq(false)
        expect(user.confirm_password?("securepassword")).to eq(true)

        get "/auth/google_oauth2/callback.json"

        user.reload
        expect(user.active).to eq(true)

        # Delete the password, it may have been set by someone else
        expect(user.confirm_password?("securepassword")).to eq(false)
      end

      it "should update name/username/email when sso_overrides is enabled" do
        SiteSetting.email_editable = false
        SiteSetting.auth_overrides_email = true
        SiteSetting.auth_overrides_name = true
        SiteSetting.auth_overrides_username = true

        UserAssociatedAccount.create!(provider_name: "google_oauth2", user_id: user.id, provider_uid: '123545')

        old_email = user.email
        user.update!(name: 'somename', username: 'somusername', email: 'email@example.com')

        get "/auth/google_oauth2/callback.json"
        expect(response.status).to eq(302)

        user.reload
        expect(user.email).to eq(old_email)
        expect(user.username).to eq('Somenickname')
        expect(user.name).to eq('Some name')
      end

      it "will not update email if not verified" do
        SiteSetting.email_editable = false
        SiteSetting.auth_overrides_email = true

        OmniAuth.config.mock_auth[:google_oauth2][:extra][:raw_info][:email_verified] = false

        UserAssociatedAccount.create!(provider_name: "google_oauth2", user_id: user.id, provider_uid: '123545')

        old_email = user.email
        user.update!(email: 'email@example.com')

        get "/auth/google_oauth2/callback.json"
        expect(response.status).to eq(302)

        user.reload
        expect(user.email).to eq('email@example.com')
      end

      it "shows error when auth_overrides_email causes a validation error" do
        SiteSetting.email_editable = false
        SiteSetting.auth_overrides_email = true

        UserAssociatedAccount.create!(provider_name: "google_oauth2", user_id: user.id, provider_uid: '123545')

        google_email = user.email
        user.update!(email: 'anotheremail@example.com')
        Fabricate(:user, email: google_email) # Another user has the google account email

        get "/auth/google_oauth2/callback"
        expect(response.status).to eq(200)
        expect(response.body).to include(I18n.t("errors.messages.taken"))
        expect(session[:current_user_id]).to eq(nil)

        user.reload
        expect(user.email).to eq('anotheremail@example.com')
      end

      context 'when user has TOTP enabled' do
        before do
          user.create_totp(enabled: true)
        end

        it 'should return the right response' do
          get "/auth/google_oauth2/callback.json"

          expect(response.status).to eq(302)

          data = JSON.parse(cookies[:authentication_data])

          expect(data["email"]).to eq(user.email)
          expect(data["omniauth_disallow_totp"]).to eq(true)

          user.update!(email: 'different@user.email')
          get "/auth/google_oauth2/callback.json"

          expect(response.status).to eq(302)
          expect(JSON.parse(cookies[:authentication_data])["email"]).to eq(user.email)
        end
      end

      context 'when user has security key enabled' do
        before do
          Fabricate(:user_security_key_with_random_credential, user: user)
        end

        it 'should return the right response' do
          get "/auth/google_oauth2/callback.json"

          expect(response.status).to eq(302)

          data = JSON.parse(cookies[:authentication_data])

          expect(data["email"]).to eq(user.email)
          expect(data["omniauth_disallow_totp"]).to eq(true)

          user.update!(email: 'different@user.email')
          get "/auth/google_oauth2/callback.json"

          expect(response.status).to eq(302)
          expect(JSON.parse(cookies[:authentication_data])["email"]).to eq(user.email)
        end
      end

      context 'when sso_payload cookie exist' do
        before do
          SiteSetting.enable_discourse_connect_provider = true
          SiteSetting.discourse_connect_secret = "topsecret"

          @sso = SingleSignOn.new
          @sso.nonce = "mynonce"
          @sso.sso_secret = SiteSetting.discourse_connect_secret
          @sso.return_sso_url = "http://somewhere.over.rainbow/sso"
          cookies[:sso_payload] = @sso.payload

          UserAssociatedAccount.create!(provider_name: "google_oauth2", provider_uid: '12345', user: user)

          OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
            provider: 'google_oauth2',
            uid: '12345',
            info: OmniAuth::AuthHash::InfoHash.new(
              email: 'someother_email@test.com',
              name: 'Some name'
            ),
            extra: {
              raw_info: OmniAuth::AuthHash.new(
                email_verified: true,
                email: 'someother_email@test.com',
                family_name: 'Huh',
                given_name: user.name,
                gender: 'male',
                name: "#{user.name} Huh",
              )
            },
          )

          Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:google_oauth2]
        end

        it 'should return the right response' do
          get "/auth/google_oauth2/callback.json"

          expect(response.status).to eq(302)

          data = JSON.parse(cookies[:authentication_data])

          expect(data["destination_url"]).to match(/\/session\/sso_provider\?sso\=.*\&sig\=.*/)
        end
      end

      context 'when user has not verified his email' do
        before do
          UserAssociatedAccount.create!(provider_name: "google_oauth2", provider_uid: '12345', user: user)
          user.update!(active: false)

          OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
            provider: 'google_oauth2',
            uid: '12345',
            info: OmniAuth::AuthHash::InfoHash.new(
              email: 'someother_email@test.com',
              name: 'Some name'
            ),
            extra: {
              raw_info: OmniAuth::AuthHash.new(
                email_verified: true,
                email: 'someother_email@test.com',
                family_name: 'Huh',
                given_name: user.name,
                gender: 'male',
                name: "#{user.name} Huh",
              )
            },
          )

          Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:google_oauth2]
        end

        it 'should return the right response' do
          get "/auth/google_oauth2/callback.json"

          expect(response.status).to eq(302)

          data = JSON.parse(cookies[:authentication_data])

          expect(user.reload.active).to eq(false)
          expect(data["authenticated"]).to eq(false)
          expect(data["awaiting_activation"]).to eq(true)
        end
      end

      it "doesn't attempt redirect to external origin" do
        post "/auth/google_oauth2?origin=https://example.com/external"
        get "/auth/google_oauth2/callback"

        expect(response.status).to eq 302
        expect(response.location).to eq "http://test.localhost/"

        cookie_data = JSON.parse(response.cookies['authentication_data'])
        expect(cookie_data["destination_url"]).to eq('/')
      end

      it "redirects to internal origin" do
        post "/auth/google_oauth2?origin=http://test.localhost/t/123"
        get "/auth/google_oauth2/callback"

        expect(response.status).to eq 302
        expect(response.location).to eq "http://test.localhost/t/123"

        cookie_data = JSON.parse(response.cookies['authentication_data'])
        expect(cookie_data["destination_url"]).to eq('/t/123')
      end

      it "redirects to internal origin on subfolder" do
        set_subfolder "/subpath"

        post "/auth/google_oauth2?origin=http://test.localhost/subpath/t/123"
        get "/auth/google_oauth2/callback"

        expect(response.status).to eq 302
        expect(response.location).to eq "http://test.localhost/subpath/t/123"

        cookie_data = JSON.parse(response.cookies['authentication_data'])
        expect(cookie_data["destination_url"]).to eq('/subpath/t/123')
      end

      it "never redirects to /auth/ origin" do
        post "/auth/google_oauth2?origin=http://test.localhost/auth/google_oauth2"
        get "/auth/google_oauth2/callback"

        expect(response.status).to eq 302
        expect(response.location).to eq "http://test.localhost/"

        cookie_data = JSON.parse(response.cookies['authentication_data'])
        expect(cookie_data["destination_url"]).to eq('/')
      end

      it "never redirects to /auth/ origin on subfolder" do
        set_subfolder "/subpath"

        post "/auth/google_oauth2?origin=http://test.localhost/subpath/auth/google_oauth2"
        get "/auth/google_oauth2/callback"

        expect(response.status).to eq 302
        expect(response.location).to eq "http://test.localhost/subpath"

        cookie_data = JSON.parse(response.cookies['authentication_data'])
        expect(cookie_data["destination_url"]).to eq('/subpath')
      end

      it "redirects to relative origin" do
        post "/auth/google_oauth2?origin=/t/123"
        get "/auth/google_oauth2/callback"

        expect(response.status).to eq 302
        expect(response.location).to eq "http://test.localhost/t/123"

        cookie_data = JSON.parse(response.cookies['authentication_data'])
        expect(cookie_data["destination_url"]).to eq('/t/123')
      end

      it "redirects with query" do
        post "/auth/google_oauth2?origin=/t/123?foo=bar"
        get "/auth/google_oauth2/callback"

        expect(response.status).to eq 302
        expect(response.location).to eq "http://test.localhost/t/123?foo=bar"

        cookie_data = JSON.parse(response.cookies['authentication_data'])
        expect(cookie_data["destination_url"]).to eq('/t/123?foo=bar')
      end

      it "removes authentication_data cookie on logout" do
        post "/auth/google_oauth2?origin=https://example.com/external"
        get "/auth/google_oauth2/callback"

        provider = log_in_user(Fabricate(:user))

        expect(cookies['authentication_data']).to be

        log_out_user(provider)

        expect(cookies['authentication_data']).to be_nil
      end

      it "removes disallowed characters from username" do
        username = "strange_name*&^"
        fixed_username = "strange_name"

        mock_auth("user.with.strange.username@gmail.com", username)

        get "/auth/google_oauth2/callback.json"
        data = JSON.parse(cookies[:authentication_data])

        expect(data["username"]).to eq(fixed_username)
      end
    end

    context 'when attempting reconnect' do
      fab!(:user2) { Fabricate(:user) }
      before do
        UserAssociatedAccount.create!(provider_name: "google_oauth2", provider_uid: '12345', user: user)
        UserAssociatedAccount.create!(provider_name: "google_oauth2", provider_uid: '123456', user: user2)

        OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
          provider: 'google_oauth2',
          uid: '12345',
          info: OmniAuth::AuthHash::InfoHash.new(
            email: 'someother_email@test.com',
            name: 'Some name'
          ),
          extra: {
            raw_info: OmniAuth::AuthHash.new(
              email_verified: true,
              email: 'someother_email@test.com',
              family_name: 'Huh',
              given_name: user.name,
              gender: 'male',
              name: "#{user.name} Huh",
            )
          },
        )

        Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:google_oauth2]
      end

      it 'should not reconnect normally' do
        # Log in normally
        post "/auth/google_oauth2"
        expect(response.status).to eq(302)
        expect(session[:auth_reconnect]).to eq(false)

        get "/auth/google_oauth2/callback.json"
        expect(response.status).to eq(302)
        expect(session[:current_user_id]).to eq(user.id)

        # Log into another user
        OmniAuth.config.mock_auth[:google_oauth2].uid = "123456"
        post "/auth/google_oauth2"
        expect(response.status).to eq(302)
        expect(session[:auth_reconnect]).to eq(false)

        get "/auth/google_oauth2/callback.json"
        expect(response.status).to eq(302)
        expect(session[:current_user_id]).to eq(user2.id)
        expect(UserAssociatedAccount.count).to eq(2)
      end

      it 'should redirect to associate URL if parameter supplied' do
        # Log in normally
        post "/auth/google_oauth2?reconnect=true"
        expect(response.status).to eq(302)
        expect(session[:auth_reconnect]).to eq(true)

        get "/auth/google_oauth2/callback.json"
        expect(response.status).to eq(302)
        expect(session[:current_user_id]).to eq(user.id)

        # Clear cookie after login
        expect(session[:auth_reconnect]).to eq(nil)

        # Disconnect
        UserAssociatedAccount.find_by(user_id: user.id).destroy

        # Reconnect flow:
        post "/auth/google_oauth2?reconnect=true"
        expect(response.status).to eq(302)
        expect(session[:auth_reconnect]).to eq(true)

        OmniAuth.config.mock_auth[:google_oauth2].uid = "123456"
        get "/auth/google_oauth2/callback.json"
        expect(response.status).to eq(302)
        expect(response.redirect_url).to start_with("http://test.localhost/associate/")

        expect(session[:current_user_id]).to eq(user.id)
        expect(UserAssociatedAccount.count).to eq(1) # Reconnect has not yet happened
      end

      it 'stores and redirects to \'origin\' parameter' do
        # Log in normally
        post "/auth/google_oauth2?origin=http://test.localhost/atesturl"
        expect(response.status).to eq(302)
        expect(session[:destination_url]).to eq("http://test.localhost/atesturl")

        get "/auth/google_oauth2/callback.json"
        expect(response.status).to eq(302)
        expect(response.redirect_url).to eq("http://test.localhost/atesturl")
      end
    end

    context 'after changing email' do
      def login(identity)
        OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
          provider: 'google_oauth2',
          uid: "123545#{identity[:username]}",
          info: OmniAuth::AuthHash::InfoHash.new(
            email: identity[:email],
            name: 'Some name'
          ),
          extra: {
            raw_info: OmniAuth::AuthHash.new(
              email_verified: true,
              email: identity[:email],
              family_name: 'Huh',
              given_name: identity[:name],
              gender: 'male',
              name: "#{identity[:name]} Huh",
            )
          },
        )

        Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:google_oauth2]

        get "/auth/google_oauth2/callback.json"
        expect(response.status).to eq(302)
        JSON.parse(cookies[:authentication_data])
      end

      it 'activates the correct email' do
        old_email = 'old@email.com'
        old_identity = { name: 'Bob',
                         username: 'bob',
                         email: old_email }
        user = Fabricate(:user, email: old_email)
        new_email = 'new@email.com'
        new_identity = { name: 'Bob',
                         username: 'boguslaw',
                         email: new_email }

        updater = EmailUpdater.new(guardian: user.guardian, user: user)
        updater.change_to(new_email)

        user.reload
        expect(user.email).to eq(old_email)

        response = login(old_identity)
        expect(response['authenticated']).to eq(true)

        user.reload
        expect(user.email).to eq(old_email)

        delete "/session/#{user.username}" # log out

        response = login(new_identity)
        expect(response['authenticated']).to eq(nil)
        expect(response['email']).to eq(new_email)
      end
    end

    context "when user is staged" do
      fab!(:staged_user) { Fabricate(
          :user,
          username: "staged_user",
          email: "staged.user@gmail.com",
          staged: true
        )
      }

      it "should use username of the staged user if username is not present in payload" do
        mock_auth(staged_user.email, nil)

        get "/auth/google_oauth2/callback.json"
        data = JSON.parse(cookies[:authentication_data])

        expect(data["username"]).to eq(staged_user.username)
      end

      it "should use username of the staged user if username in payload is the same" do
        mock_auth(staged_user.email, staged_user.username)

        get "/auth/google_oauth2/callback.json"
        data = JSON.parse(cookies[:authentication_data])

        expect(data["username"]).to eq(staged_user.username)
      end

      it "should override username of the staged user if payload contains a new username" do
        new_username = "new_username"
        mock_auth(staged_user.email, new_username)

        get "/auth/google_oauth2/callback.json"
        data = JSON.parse(cookies[:authentication_data])

        expect(data["username"]).to eq(new_username)
      end
    end

    def mock_auth(email, nickname)
      OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
        provider: 'google_oauth2',
        uid: '123545',
        info: OmniAuth::AuthHash::InfoHash.new(
          email: email,
          nickname: nickname
        ),
        extra: {
          raw_info: OmniAuth::AuthHash.new(email_verified: true)
        }
      )

      Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:google_oauth2]
    end
  end
end
