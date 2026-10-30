// phoenix_kit_comments JS hooks — folded into the host LiveSocket by core's
// :phoenix_kit_js_sources compiler (see PhoenixKit.Module.js_sources/0).
//
// These used to be inline <script> tags inside the component and settings
// templates. That works on a hard page load — the script runs during HTML
// parse, before app.js constructs the LiveSocket and snapshots
// window.PhoenixKitHooks — and fails on every LiveView NAVIGATION, because
// morphdom does not execute inserted <script> tags and the hooks map was
// fixed at construction. Verified on a dev box before this move: navigating
// to Settings -> Comments logged `unknown hook found for "InsertAtCursor"`
// four times and the template-variable inserter did nothing.
(function () {
  "use strict";

  window.PhoenixKitCommentsHooks = window.PhoenixKitCommentsHooks || {};

  // Audio recording in the comment composer.
  (function() {
    window.PhoenixKitCommentsHooks = window.PhoenixKitCommentsHooks || {};
    if (window.PhoenixKitCommentsHooks.PhoenixKitCommentsAudioRecorder) return;
    window.PhoenixKitCommentsHooks.PhoenixKitCommentsAudioRecorder = {
      mounted() {
        this._destroyed = false;
        this.starting = false;
        this.recording = false;
        this.recorder = null;
        this.stream = null;
        this.chunks = [];
        // The start/stop buttons dispatch the toggle ON THIS ELEMENT
        // (`JS.dispatch(..., to: "#<this recorder's id>")`), never on
        // window: a window-wide event was answered by every recorder on the
        // page, so with two open comment threads one click started two
        // recordings.
        this._onToggle = () => {
          if (this.recording) this.stop(); else this.start();
        };
        this.el.addEventListener("phx-kit-comments-audio-toggle", this._onToggle);
      },
      destroyed() {
        this._destroyed = true;
        this.el.removeEventListener("phx-kit-comments-audio-toggle", this._onToggle);
        this.cleanup();
      },
      async start() {
        if (this._destroyed || this.starting || this.recording) return;
        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia || typeof MediaRecorder === "undefined") {
          this.pushError("unsupported");
          return;
        }
        this.starting = true;
        let stream;
        try {
          stream = await navigator.mediaDevices.getUserMedia({ audio: true });
        } catch (err) {
          if (!this._destroyed) this.pushError("denied");
          return;
        } finally {
          this.starting = false;
        }
        // Permission may resolve after cancel, navigation, or moving to a
        // reply destroyed this hook. A late stream still owns a microphone.
        if (this._destroyed) {
          stream.getTracks().forEach((t) => t.stop());
          return;
        }
        this.stream = stream;
        try {
          const mimeType = MediaRecorder.isTypeSupported("audio/webm;codecs=opus")
            ? "audio/webm;codecs=opus"
            : "audio/webm";
          const recorder = this.recorder = new MediaRecorder(this.stream, { mimeType });
          this.chunks = [];
          recorder.addEventListener("dataavailable", (ev) => {
            if (this.recorder === recorder && ev.data && ev.data.size > 0) this.chunks.push(ev.data);
          });
          recorder.addEventListener("stop", () => {
            if (this.recorder === recorder) this.finalize(mimeType);
          });
          recorder.start();
        } catch (err) {
          this.pushError("start_failed");
          return;
        }
        this.recording = true;
        this.pushEventTo(this.el, "audio_recording_started", {});
      },
      stop() {
        if (this.recorder && this.recorder.state !== "inactive") {
          this.recorder.stop();
        }
      },
      finalize(mimeType) {
        const blob = new Blob(this.chunks, { type: mimeType });
        const ext = mimeType.indexOf("webm") >= 0 ? "webm" : "ogg";
        const name = "voice-" + new Date().toISOString().replace(/[:.]/g, "-") + "." + ext;
        const file = new File([blob], name, { type: mimeType });
        // Into THIS composer's file input, as the paste hook does:
        // `this.upload(name)` searches the whole LiveView, so with two open
        // composers it found two inputs, logged and dropped the recording
        // (it only logs, never throws, so the catch never saw it).
        const uploadName = this.el.dataset.uploadName || "attachment";
        const form = this.el.closest("form");
        const input = form && Array.prototype.find.call(
          form.querySelectorAll('input[type="file"][data-phx-upload-ref]'),
          (el) => el.name === uploadName
        );
        this.recording = false;
        this.cleanup();
        this.pushEventTo(this.el, "audio_recording_stopped", {});
        if (!input) {
          this.pushError("attach_failed");
          return;
        }
        try {
          this.uploadTo(form, uploadName, [file]);
        } catch (err) {
          this.pushError("attach_failed");
        }
      },
      cleanup() {
        const recorder = this.recorder;
        this.recorder = null;
        if (recorder && recorder.state !== "inactive") recorder.stop();
        if (this.stream) {
          this.stream.getTracks().forEach((t) => t.stop());
          this.stream = null;
        }
        this.chunks = [];
      },
      // A reason CODE, never prose. The server maps it to a translated
      // string: the old version pushed English sentences that landed in
      // the flash untranslated in every locale, and let any client paint
      // arbitrary text in the app's own error chrome.
      pushError(reason) {
        this.pushEventTo(this.el, "audio_recording_error", { reason: reason });
        this.cleanup();
        this.recording = false;
      }
    };
  })();

  // A file pasted into the comment composer (a screenshot, a copied image)
  // becomes one of the comment's attachments — the same LiveView upload the
  // attach button and the voice recorder feed, with its type and size
  // limits — instead of the editor's fallback, which wrote the image into
  // the comment's TEXT as a base64 data URL: it showed up, then the comment
  // could not be saved (hundreds of thousands of characters against a limit
  // of thousands).
  //
  // Listens in the CAPTURE phase on a wrapper round the editor, so it sees
  // the paste before the editor does. Only a paste with no text in it is
  // taken: Word and Excel put a picture of the copied cells on the
  // clipboard next to the text, and that paste is the text.
  (function() {
    window.PhoenixKitCommentsHooks = window.PhoenixKitCommentsHooks || {};
    if (window.PhoenixKitCommentsHooks.PhoenixKitCommentsPasteFiles) return;

    function named(file, index) {
      // A screenshot arrives as "image.png" or with no name at all.
      const generic = !file.name || /^image\.(png|jpe?g|gif|webp|bmp)$/i.test(file.name);
      if (!generic) return file;
      const ext = ((file.type || "image/png").split("/")[1] || "png").replace("jpeg", "jpg");
      const stamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
      const name = "pasted-" + stamp + (index > 0 ? "-" + (index + 1) : "") + "." + ext;
      return new File([file], name, { type: file.type || "image/png" });
    }

    function pastedFiles(clipboard) {
      if (!clipboard) return [];
      if ((clipboard.getData("text/plain") || "").trim() !== "") return [];
      const files = [];
      const items = clipboard.items || [];
      for (let i = 0; i < items.length; i++) {
        if (items[i].kind === "file") {
          const file = items[i].getAsFile();
          if (file) files.push(named(file, files.length));
        }
      }
      if (files.length === 0 && clipboard.files) {
        for (let i = 0; i < clipboard.files.length; i++) files.push(named(clipboard.files[i], i));
      }
      return files;
    }

    function hasFiles(dt) {
      return !!dt && Array.prototype.indexOf.call(dt.types || [], "Files") !== -1;
    }

    window.PhoenixKitCommentsHooks.PhoenixKitCommentsPasteFiles = {
      // Puts `files` into THIS composer's upload; says so when it cannot.
      // Shared by paste and drop, so both refuse and fail the same way.
      attach(files) {
        // Where a file cannot be attached (attachments off, an edit),
        // say so — never let the editor bake it into the text instead.
        if (this.el.dataset.attachments !== "true") {
          this.pushEventTo(this.el, "paste_refused", { reason: this.el.dataset.refuse || "attachments_off" });
          return;
        }
        // Upload into THIS composer's file input. `this.upload(name)`
        // searches the whole LiveView for an input of that name, so on a
        // host page with two open comment threads it found two, logged
        // "duplicate live file inputs" and dropped the paste in silence —
        // and it only logs, never throws, so the catch below never saw it.
        const name = this.el.dataset.uploadName || "attachment";
        const form = this.el.closest("form");
        const input = form && Array.prototype.find.call(
          form.querySelectorAll('input[type="file"][data-phx-upload-ref]'),
          (el) => el.name === name
        );
        if (!input) {
          this.pushEventTo(this.el, "paste_refused", { reason: "attach_failed" });
          return;
        }
        try {
          this.uploadTo(form, name, files);
        } catch (err) {
          this.pushEventTo(this.el, "paste_refused", { reason: "attach_failed" });
        }
      },
      setDragging(on) {
        const hint = this.el.querySelector("[data-drop-hint]");
        if (hint) hint.classList.toggle("hidden", !on);
        this.el.classList.toggle("pk-comments-dropping", on);
      },
      updated() {
        // LiveView patches restore the server's `hidden` class while a
        // file is over the editor (for example after an upload update).
        this.setDragging(this._depth > 0);
      },
      mounted() {
        this._depth = 0;
        this._onPaste = (e) => {
          const files = pastedFiles(e.clipboardData || window.clipboardData);
          if (files.length === 0) return;
          e.preventDefault();
          e.stopPropagation();
          this.attach(files);
        };
        // A file dragged in from the desktop. The editor inside does not
        // take it, so without this the browser opens the file in the tab
        // and the page is gone. Claimed in the capture phase, before the
        // editor sees it; only drags that carry files, so text and the
        // editor's own drags are left alone.
        this._onDragEnter = (e) => {
          if (!hasFiles(e.dataTransfer)) return;
          e.preventDefault();
          this._depth += 1;
          this.setDragging(true);
        };
        this._onDragOver = (e) => {
          if (!hasFiles(e.dataTransfer)) return;
          e.preventDefault();
          e.stopPropagation();
          if (e.dataTransfer) e.dataTransfer.dropEffect = "copy";
        };
        this._onDragLeave = (e) => {
          if (!hasFiles(e.dataTransfer)) return;
          this._depth = Math.max(0, this._depth - 1);
          if (this._depth === 0) this.setDragging(false);
        };
        this._onDrop = (e) => {
          if (!hasFiles(e.dataTransfer)) return;
          e.preventDefault();
          e.stopPropagation();
          this._depth = 0;
          this.setDragging(false);
          const files = Array.prototype.map.call(e.dataTransfer.files || [], (f, i) => named(f, i));
          if (files.length > 0) this.attach(files);
        };
        this.el.addEventListener("paste", this._onPaste, true);
        this.el.addEventListener("dragenter", this._onDragEnter, true);
        this.el.addEventListener("dragover", this._onDragOver, true);
        this.el.addEventListener("dragleave", this._onDragLeave, true);
        this.el.addEventListener("drop", this._onDrop, true);
      },
      destroyed() {
        this.el.removeEventListener("paste", this._onPaste, true);
        this.el.removeEventListener("dragenter", this._onDragEnter, true);
        this.el.removeEventListener("dragover", this._onDragOver, true);
        this.el.removeEventListener("dragleave", this._onDragLeave, true);
        this.el.removeEventListener("drop", this._onDrop, true);
      }
    };
  })();

  // Template-variable insertion on the settings page.
  (function() {
    window.PhoenixKitCommentsHooks = window.PhoenixKitCommentsHooks || {};
    if (window.PhoenixKitCommentsHooks.PhoenixKitCommentsInsertAtCursor) return;
    window.PhoenixKitCommentsHooks.PhoenixKitCommentsInsertAtCursor = {
      mounted() {
        this._lastInput = null;
        this._lastCursorPos = 0;
        this._abortController = null;
        this.setup();
      },
      updated() { this.setup(); },
      destroyed() {
        if (this._abortController) this._abortController.abort();
      },
      colorBadges() {
        var container = this.el;
        var input = this._lastInput;
        var val = input ? input.value : "";
        container.querySelectorAll("[data-field]").forEach(function(badge) {
          var used = val && val.indexOf(badge.dataset.field) !== -1;
          badge.classList.remove("badge-success", "badge-ghost");
          badge.classList.add(used ? "badge-success" : "badge-ghost");
        });
      },
      setup() {
        if (this._abortController) this._abortController.abort();
        this._abortController = new AbortController();
        var signal = this._abortController.signal;
        var self = this;
        var container = this.el;
        var trackCursor = function(input) {
          self._lastInput = input;
          self._lastCursorPos = input.selectionStart;
          self.colorBadges();
        };
        container.querySelectorAll("textarea, input[type='text']").forEach(function(input) {
          input.addEventListener("focus", function() { trackCursor(input); }, { signal: signal });
          input.addEventListener("keyup", function() { trackCursor(input); }, { signal: signal });
          input.addEventListener("click", function() { trackCursor(input); }, { signal: signal });
          input.addEventListener("input", function() { self.colorBadges(); }, { signal: signal });
        });
        self.colorBadges();
        container.querySelectorAll("[data-field]").forEach(function(badge) {
          badge.style.cursor = "pointer";
          badge.addEventListener("click", function(e) {
            e.preventDefault();
            var input = self._lastInput || container.querySelector("textarea, input[type='text']");
            if (!input) return;
            var val = badge.dataset.field;
            var pos = self._lastCursorPos || 0;
            input.value = input.value.slice(0, pos) + val + input.value.slice(pos);
            var newPos = pos + val.length;
            self._lastCursorPos = newPos;
            input.selectionStart = input.selectionEnd = newPos;
            input.focus();
            input.dispatchEvent(new Event("input", { bubbles: true }));
          }, { signal: signal });
        });
      }
    };
  })();
})();
