import Service from "@ember/service";
import { getOwner } from "@ember/application";
import { Promise } from "rsvp";
import { fileToImageData } from "discourse/lib/media-optimization-utils";
import { getAbsoluteURL, getURLWithCDN } from "discourse-common/lib/get-url";

/**
 * This worker follows a particular promise/callback flow to ensure
 * that the media-optimization-worker is installed and has its libraries
 * loaded before optimizations can happen. The flow:
 *
 * 1. optimizeImage called
 * 2. worker initialized and started
 * 3. message handlers for worker registered
 * 4. "install" message posted to worker
 * 5. "installed" message received from worker
 * 6. optimizeImage continues, posting "compress" message to worker
 *
 * When the worker is being installed, all other calls to optimizeImage
 * will wait for the "installed" message to be handled before continuing
 * with any image optimization work.
 */
export default class MediaOptimizationWorkerService extends Service {
  appEvents = getOwner(this).lookup("service:app-events");
  worker = null;
  workerUrl = getAbsoluteURL("/javascripts/media-optimization-worker.js");
  currentComposerUploadData = null;
  promiseResolvers = null;

  async optimizeImage(data, opts = {}) {
    this.usingUppy = data.id && data.id.includes("uppy");
    this.promiseResolvers = this.promiseResolvers || {};
    this.stopWorkerOnError = opts.hasOwnProperty("stopWorkerOnError")
      ? opts.stopWorkerOnError
      : true;

    let file = this.usingUppy ? data : data.files[data.index];
    if (!/(\.|\/)(jpe?g|png|webp)$/i.test(file.type)) {
      return this.usingUppy ? Promise.resolve() : data;
    }
    if (
      file.size <
      this.siteSettings
        .composer_media_optimization_image_bytes_optimization_threshold
    ) {
      return this.usingUppy ? Promise.resolve() : data;
    }
    await this.ensureAvailiableWorker();

    return new Promise(async (resolve) => {
      this.logIfDebug(`Transforming ${file.name}`);

      this.currentComposerUploadData = data;
      this.promiseResolvers[this.usingUppy ? file.id : file.name] = resolve;

      let imageData;
      try {
        if (this.usingUppy) {
          imageData = await fileToImageData(file.data);
        } else {
          imageData = await fileToImageData(file);
        }
      } catch (error) {
        this.logIfDebug(error);
        return this.usingUppy ? resolve() : resolve(data);
      }

      this.worker.postMessage(
        {
          type: "compress",
          fileId: file.id,
          file: imageData.data.buffer,
          fileName: file.name,
          width: imageData.width,
          height: imageData.height,
          settings: {
            resize_threshold: this.siteSettings
              .composer_media_optimization_image_resize_dimensions_threshold,
            resize_target: this.siteSettings
              .composer_media_optimization_image_resize_width_target,
            resize_pre_multiply: this.siteSettings
              .composer_media_optimization_image_resize_pre_multiply,
            resize_linear_rgb: this.siteSettings
              .composer_media_optimization_image_resize_linear_rgb,
            encode_quality: this.siteSettings
              .composer_media_optimization_image_encode_quality,
            debug_mode: this.siteSettings
              .composer_media_optimization_debug_mode,
          },
        },
        [imageData.data.buffer]
      );
    });
  }

  async ensureAvailiableWorker() {
    if (this.worker && this.workerInstalled) {
      return Promise.resolve();
    }
    if (this.installPromise) {
      return this.installPromise;
    }
    return this.install();
  }

  async install() {
    this.installPromise = new Promise((resolve) => {
      this.afterInstalled = resolve;
      this.logIfDebug("Installing worker.");
      this.startWorker();
      this.registerMessageHandler();
      this.worker.postMessage({
        type: "install",
        settings: {
          mozjpeg_script: getURLWithCDN("/javascripts/squoosh/mozjpeg_enc.js"),
          mozjpeg_wasm: getURLWithCDN("/javascripts/squoosh/mozjpeg_enc.wasm"),
          resize_script: getURLWithCDN(
            "/javascripts/squoosh/squoosh_resize.js"
          ),
          resize_wasm: getURLWithCDN(
            "/javascripts/squoosh/squoosh_resize_bg.wasm"
          ),
        },
      });
      this.appEvents.on("composer:closed", this, "stopWorker");
    });
    return this.installPromise;
  }

  startWorker() {
    this.logIfDebug("Starting media-optimization-worker");
    this.worker = new Worker(this.workerUrl); // TODO come up with a workaround for FF that lacks type: module support
  }

  stopWorker() {
    if (this.worker) {
      this.logIfDebug("Stopping media-optimization-worker...");
      this.workerInstalled = false;
      this.worker.terminate();
      this.worker = null;
    }
  }

  registerMessageHandler() {
    this.worker.onmessage = (e) => {
      switch (e.data.type) {
        case "file":
          let optimizedFile = new File([e.data.file], e.data.fileName, {
            type: "image/jpeg",
          });
          this.logIfDebug(
            `Finished optimization of ${optimizedFile.name} new size: ${optimizedFile.size}.`
          );

          if (this.usingUppy) {
            this.promiseResolvers[e.data.fileId](optimizedFile);
          } else {
            let data = this.currentComposerUploadData;
            data.files[data.index] = optimizedFile;
            this.promiseResolvers[optimizedFile.name](data);
          }

          break;
        case "error":
          this.logIfDebug(
            `Handling error message from image optimization for ${e.data.fileName}.`
          );

          if (this.stopWorkerOnError) {
            this.stopWorker();
          }

          if (this.usingUppy) {
            this.promiseResolvers[e.data.fileId]();
          } else {
            this.promiseResolvers[e.data.fileName](
              this.currentComposerUploadData
            );
          }
          break;
        case "installed":
          this.logIfDebug("Worker installed.");
          this.workerInstalled = true;
          this.afterInstalled();
          this.afterInstalled = null;
          this.installPromise = null;
          break;
        default:
          this.logIfDebug(`Sorry, we are out of ${e}.`);
      }
    };
  }

  logIfDebug(message) {
    if (this.siteSettings.composer_media_optimization_debug_mode) {
      // eslint-disable-next-line no-console
      console.log(message);
    }
  }
}
