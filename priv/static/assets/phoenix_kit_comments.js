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
        // take it (LiveView's own window-level handler only stops the
        // browser opening it), so without this a drop did nothing. Claimed
        // in the capture phase, before the editor sees it; only drags that
        // carry files, so text and the editor's own drags are left alone.
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
          // As they are: a file from the desktop has its real name, and
          // `named/2` would have renamed a photo called "image.png" to
          // "pasted-…" — it is for screenshots, which arrive nameless.
          const files = Array.prototype.slice.call(e.dataTransfer.files || []);
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

  // PhoenixKitCommentsStickToBottom: a thread whose box is at the bottom
  // (oldest first, a chat) opens at its newest comment and follows new ones
  // while the reader is at its end; someone reading back is never pulled
  // down. The thread does not scroll itself: the nearest scrolling ancestor
  // (a drawer, a popup) or the page does.
  //
  // "The end" is the end of the THREAD (the list and the box under it, the
  // hook element's parent), not the bottom of what scrolls it: a page or a
  // panel with more below the thread was scrolled past it to its own end.
  // The scroller is looked up every time, not once at mount: a drawer
  // opened on two comments does not scroll yet, and a lookup at mount
  // settled on the page for good — it scrolled the page behind the drawer
  // and never followed the drawer once it filled. A thread that starts out
  // of sight is not moved to on opening: the reader is looking at something
  // else. Nothing listens to the page's scroll: whether the reader is at
  // the end is measured when it matters (before a patch, on a resize).
  (function() {
    window.PhoenixKitCommentsHooks = window.PhoenixKitCommentsHooks || {};
    if (window.PhoenixKitCommentsHooks.PhoenixKitCommentsStickToBottom) return;

    // Within this much of the visible bottom counts as "at the end".
    var SLACK = 48;

    // The nearest ancestor that scrolls now; null for the page.
    function scroller(el) {
      for (var p = el.parentElement; p && p !== document.body && p !== document.documentElement; p = p.parentElement) {
        var y = window.getComputedStyle(p).overflowY;
        if ((y === "auto" || y === "scroll") && p.scrollHeight > p.clientHeight + 1) return p;
      }
      return null;
    }

    // The bottom of what the reader can see, in viewport coordinates.
    function visibleBottom(box) {
      return box ? box.getBoundingClientRect().bottom : window.innerHeight;
    }

    // How far the thread's end is below what can be seen (negative: above).
    function gap(hook) {
      return hook.target.getBoundingClientRect().bottom - visibleBottom(scroller(hook.el));
    }

    // Brings the thread's end into sight. Only ever down.
    function toEnd(hook) {
      var box = scroller(hook.el);
      var dy = hook.target.getBoundingClientRect().bottom - visibleBottom(box);
      if (dy <= 0) return;
      if (box) box.scrollTop += dy; else window.scrollBy(0, dy);
    }

    window.PhoenixKitCommentsHooks.PhoenixKitCommentsStickToBottom = {
      mounted: function() {
        var self = this;
        this.target = this.el.parentElement || this.el;
        this.height = this.target.offsetHeight;
        requestAnimationFrame(function() {
          // A comment link (`#…`) keeps its own place.
          if (self.gone || window.location.hash) return;
          if (self.el.getBoundingClientRect().top < visibleBottom(scroller(self.el))) toEnd(self);
        });
        // Pictures and GIFs size themselves after loading; the box under
        // the list opens. Followed when the thread's end was in sight
        // before it grew: the growth is what moved it away. (The first
        // call, on observe, sees no growth — it used to scroll a comment
        // link's thread to the end regardless.)
        if (window.ResizeObserver) {
          this.ro = new window.ResizeObserver(function() {
            var h = self.target.offsetHeight;
            var grown = h - self.height;
            self.height = h;
            if (grown > 0 && gap(self) - grown < SLACK) toEnd(self);
          });
          this.ro.observe(this.target);
        }
      },
      beforeUpdate: function() { this.stuck = gap(this) < SLACK; },
      updated: function() {
        if (this.stuck) toEnd(this);
        this.height = this.target.offsetHeight;
      },
      destroyed: function() {
        this.gone = true;
        if (this.ro) this.ro.disconnect();
      }
    };
  })();

  // PhoenixKitCommentsTimeAgo: a comment's "… ago" kept current in the page's
  // language (Intl.RelativeTimeFormat: "now", "1 min ago", "2 h ago"; a
  // week and more shows the date). Re-applied after every LiveView patch,
  // which puts the server's text back. One timer for all of them.
  (function() {
    window.PhoenixKitCommentsHooks = window.PhoenixKitCommentsHooks || {};
    if (window.PhoenixKitCommentsHooks.PhoenixKitCommentsTimeAgo) return;

    var live = new Set();
    var timer = null;

    function phrase(iso, locale) {
      var then = new Date(iso);
      if (isNaN(then)) return null;
      var secs = Math.round((then.getTime() - Date.now()) / 1000);
      var abs = Math.abs(secs);
      try {
        var rtf = new Intl.RelativeTimeFormat(locale || undefined, { numeric: "auto", style: "short" });
        if (abs < 45) return rtf.format(0, "second");
        // The unit is chosen from the ROUNDED value: choosing it from the
        // raw seconds wrote 3590 s as "60 min. ago", 86350 s as "24 hr.
        // ago" and 6.8 days as "7 days ago".
        var mins = Math.round(secs / 60);
        if (Math.abs(mins) < 60) return rtf.format(mins, "minute");
        var hours = Math.round(secs / 3600);
        if (Math.abs(hours) < 24) return rtf.format(hours, "hour");
        var days = Math.round(secs / 86400);
        if (Math.abs(days) < 7) return rtf.format(days, "day");
        return new Intl.DateTimeFormat(locale || undefined, { day: "numeric", month: "short", year: "numeric" }).format(then);
      } catch (_e) {
        return null;
      }
    }

    function apply(hook) {
      var t = hook.el.querySelector("time[datetime]");
      if (!t) return;
      var text = phrase(t.getAttribute("datetime"), hook.el.dataset.locale);
      if (text && t.textContent !== text) t.textContent = text;
    }

    function tick() { live.forEach(apply); }

    window.PhoenixKitCommentsHooks.PhoenixKitCommentsTimeAgo = {
      mounted: function() {
        live.add(this);
        apply(this);
        if (!timer) timer = setInterval(tick, 30000);
      },
      updated: function() { apply(this); },
      destroyed: function() {
        live.delete(this);
        if (live.size === 0 && timer) { clearInterval(timer); timer = null; }
      }
    };
  })();
})();
