// Run with: node --test test/js/comments_hooks_test.cjs
// Exercise the shipped bundle.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

const bundle = fs.readFileSync(
  process.env.COMMENTS_HOOKS_BUNDLE || "priv/static/assets/phoenix_kit_comments.js", "utf8"
);

function classes(initial = []) {
  const values = new Set(initial);
  return {
    contains: (value) => values.has(value),
    toggle(value, on) { if (on) values.add(value); else values.delete(value); }
  };
}

function element(attachments = "true") {
  const el = new EventTarget();
  // Node's EventTarget needs an options object to match capture on removal.
  el.addEventListener = (name, listener, capture = false) =>
    EventTarget.prototype.addEventListener.call(el, name, listener, { capture });
  el.removeEventListener = (name, listener, capture = false) =>
    EventTarget.prototype.removeEventListener.call(el, name, listener, { capture });
  el.dataset = { attachments, uploadName: "attachment" };
  el.classList = classes();
  el.hint = { classList: classes(["hidden"]) };
  el.form = { querySelectorAll: () => [{ name: "attachment" }] };
  el.closest = () => el.form;
  el.querySelector = () => el.hint;
  return el;
}

function hooks(overrides = {}) {
  const window = {};
  vm.runInNewContext(bundle, { window, navigator: {}, File, Blob, ...overrides });
  return window.PhoenixKitCommentsHooks;
}

function mount(definition, el = element()) {
  const hook = Object.assign({ el, events: [], uploads: [] }, definition, {
    pushEventTo(target, name, payload) { this.events.push({ target, name, payload }); },
    uploadTo(form, name, files) { this.uploads.push({ form, name, files }); }
  });
  hook.mounted();
  return hook;
}

function dispatch(el, type, data = {}) {
  const event = new Event(type, { cancelable: true });
  Object.assign(event, data);
  el.dispatchEvent(event);
  return event;
}

function drag(files = []) { return { types: ["Files"], files }; }

test("drop uploads to its own form when two composers are open", () => {
  const definition = hooks().PhoenixKitCommentsPasteFiles;
  const first = mount(definition);
  const second = mount(definition);
  const file = new File(["pixels"], "photo.png", { type: "image/png" });

  assert.ok(dispatch(first.el, "drop", { dataTransfer: drag([file]) }).defaultPrevented);
  assert.equal(first.uploads.length, 1);
  assert.equal(first.uploads[0].form, first.el.form);
  assert.equal(first.uploads[0].files[0], file);
  assert.equal(second.uploads.length, 0);
});

for (const reason of ["attachments_off", "editing"]) {
  test(`drop is claimed and refused for ${reason}`, () => {
    const hook = mount(hooks().PhoenixKitCommentsPasteFiles, element("false"));
    hook.el.dataset.refuse = reason;
    const file = new File(["x"], "photo.png", { type: "image/png" });
    assert.ok(dispatch(hook.el, "drop", { dataTransfer: drag([file]) }).defaultPrevented);
    assert.equal(hook.events[0].name, "paste_refused");
    assert.equal(hook.events[0].payload.reason, reason);
    assert.equal(hook.uploads.length, 0);
  });
}

test("nested file drags keep their hint until the last leave or drop", () => {
  const hook = mount(hooks().PhoenixKitCommentsPasteFiles);
  for (let i = 0; i < 2; i++) dispatch(hook.el, "dragenter", { dataTransfer: drag() });
  dispatch(hook.el, "dragleave", { dataTransfer: drag() });
  assert.equal(hook.el.hint.classList.contains("hidden"), false);
  dispatch(hook.el, "dragleave", { dataTransfer: drag() });
  assert.equal(hook.el.hint.classList.contains("hidden"), true);
  dispatch(hook.el, "dragenter", { dataTransfer: drag() });
  dispatch(hook.el, "drop", { dataTransfer: drag() });
  assert.equal(hook.el.hint.classList.contains("hidden"), true);
});

test("the drop hint survives a LiveView patch during a file drag", () => {
  const hook = mount(hooks().PhoenixKitCommentsPasteFiles);
  dispatch(hook.el, "dragenter", { dataTransfer: drag() });
  hook.el.hint.classList.toggle("hidden", true); // Server-rendered class.
  hook.updated();
  assert.equal(hook.el.hint.classList.contains("hidden"), false);
  dispatch(hook.el, "dragleave", { dataTransfer: drag() });
  hook.updated();
  assert.equal(hook.el.hint.classList.contains("hidden"), true);
});

test("text drags and a text-plus-image paste are left to the editor", () => {
  const hook = mount(hooks().PhoenixKitCommentsPasteFiles);
  assert.equal(dispatch(hook.el, "drop", { dataTransfer: { types: ["text/plain"] } }).defaultPrevented, false);
  const clipboardData = {
    getData: () => "copied cells",
    files: [new File(["x"], "image.png", { type: "image/png" })]
  };
  assert.equal(dispatch(hook.el, "paste", { clipboardData }).defaultPrevented, false);
  assert.equal(hook.uploads.length, 0);
});

test("a screenshot paste is named and attached; a missing input is reported", () => {
  const hook = mount(hooks().PhoenixKitCommentsPasteFiles);
  const clipboardData = {
    getData: () => "",
    files: [new File(["x"], "image.png", { type: "image/png" })]
  };
  assert.ok(dispatch(hook.el, "paste", { clipboardData }).defaultPrevented);
  assert.match(hook.uploads[0].files[0].name, /^pasted-.+\.png$/);
  hook.el.form.querySelectorAll = () => [];
  dispatch(hook.el, "paste", { clipboardData });
  assert.equal(hook.events[0].payload.reason, "attach_failed");
});

test("destroy removes paste and drag listeners", () => {
  const hook = mount(hooks().PhoenixKitCommentsPasteFiles);
  hook.destroyed();
  assert.equal(dispatch(hook.el, "dragover", { dataTransfer: drag() }).defaultPrevented, false);
  assert.equal(hook.uploads.length, 0);
});

function stickWorld({ drawer = false, top = 120, height = 400, hash = "" } = {}) {
  const s = { height, page: 0, frames: [], observers: [], pageScrolls: [] };
  // The page's own scroller records any scroll made through it (the hook
  // scrolls the page with window.scrollBy, never by assigning this).
  const html = {
    style: {},
    clientHeight: 800,
    get scrollHeight() { return 3000; },
    get scrollTop() { return s.page; },
    set scrollTop(v) { s.pageScrolls.push(`scrollTop=${v}`); },
    addEventListener() {},
    removeEventListener() {}
  };
  const body = { style: {}, parentElement: html };
  const box = drawer && {
    style: { overflowY: "auto" },
    parentElement: body,
    clientHeight: 600,
    offset: 0,
    get scrollHeight() { return s.height + 20; },
    get scrollTop() { return this.offset; },
    set scrollTop(v) {
      this.offset = Math.max(0, Math.min(v, Math.max(0, this.scrollHeight - this.clientHeight)));
    },
    getBoundingClientRect: () => ({ top: 100, bottom: 700 }),
    addEventListener() {},
    removeEventListener() {}
  };
  const threadTop = () => (box ? 110 - box.scrollTop : top - s.page);
  // The hook's parent: the list and the box under it.
  const thread = {
    style: {},
    parentElement: box || body,
    get offsetHeight() { return s.height; },
    getBoundingClientRect: () => ({ top: threadTop(), bottom: threadTop() + s.height })
  };
  const list = {
    parentElement: thread,
    getBoundingClientRect: () => ({ top: threadTop(), bottom: threadTop() + s.height - 60 })
  };
  class Observer {
    constructor(callback) { this.callback = callback; s.observers.push(this); }
    observe() {}
    disconnect() { this.off = true; }
    fire() { if (!this.off) this.callback([]); }
  }
  const window = {
    innerHeight: 800,
    location: { hash },
    getComputedStyle: (el) => el.style,
    scrollBy: (_x, dy) => { s.page += dy; s.pageScrolls.push(dy); },
    addEventListener() {},
    removeEventListener() {},
    ResizeObserver: Observer
  };
  vm.runInNewContext(bundle, {
    window,
    navigator: {},
    document: { body, documentElement: html, scrollingElement: html },
    ResizeObserver: Observer,
    requestAnimationFrame: (f) => s.frames.push(f)
  });
  const hook = Object.assign({ el: list }, window.PhoenixKitCommentsHooks.PhoenixKitCommentsStickToBottom);
  hook.mounted();
  const observe = () => s.observers.forEach((o) => o.fire());
  return {
    s,
    box,
    hook,
    frame: () => s.frames.splice(0).forEach((f) => f()),
    observe,
    // A picture loading, the box under the list opening.
    grow(by) { s.height += by; observe(); },
    // A LiveView patch that adds to the thread.
    patch(by) { hook.beforeUpdate(); s.height += by; hook.updated(); observe(); }
  };
}

test("a drawer opened on a short thread follows it once it fills; the page never moves", () => {
  const w = stickWorld({ drawer: true, height: 300 });
  w.frame();
  w.observe();
  assert.equal(w.box.scrollTop, 0);
  w.patch(500);
  // The thread's end (110 + 800) brought to the drawer's bottom (700).
  assert.equal(w.box.scrollTop, 210);
  assert.deepEqual(w.s.pageScrolls, []);
});

test("at the end, new pictures are followed; reading back is never pulled down", () => {
  const w = stickWorld({ drawer: true, height: 900 });
  w.frame();
  assert.equal(w.box.scrollTop, 310);
  w.grow(100);
  assert.equal(w.box.scrollTop, 410);
  w.box.scrollTop = 0;
  w.patch(100);
  w.grow(100);
  assert.equal(w.box.scrollTop, 0);
});

test("on a page, a thread out of sight stays put; one in sight opens at its own end", () => {
  const below = stickWorld({ top: 1500, height: 400 });
  below.frame();
  below.observe();
  assert.deepEqual(below.s.pageScrolls, []);
  // To the thread's end (300 + 1000 - 800), not to the page's bottom.
  const inSight = stickWorld({ top: 300, height: 1000 });
  inSight.frame();
  assert.deepEqual(inSight.s.pageScrolls, [500]);
});

test("a comment link keeps its place when the observer reports the first size", () => {
  const w = stickWorld({ drawer: true, height: 900, hash: "#comment-1" });
  w.frame();
  w.observe();
  assert.equal(w.box.scrollTop, 0);
});

test("a thread destroyed before its first frame scrolls nothing", () => {
  const w = stickWorld({ drawer: true, height: 900 });
  w.hook.destroyed();
  w.frame();
  assert.equal(w.box.scrollTop, 0);
  assert.equal(w.s.observers[0].off, true);
});

test("a dropped desktop file keeps its own name", () => {
  const hook = mount(hooks().PhoenixKitCommentsPasteFiles);
  // "image.png" is also what a pasted screenshot is called; only a paste is
  // renamed.
  const file = new File(["pixels"], "image.png", { type: "image/png" });
  dispatch(hook.el, "drop", { dataTransfer: drag([file]) });
  assert.equal(hook.uploads[0].files[0].name, "image.png");
});

function timeAgo(secondsAgo) {
  const intervals = [];
  const sandbox = {
    setInterval: (fn) => { intervals.push(fn); return intervals.length; },
    clearInterval: () => {}
  };
  const definition = hooks(sandbox).PhoenixKitCommentsTimeAgo;
  const time = {
    textContent: "server text",
    getAttribute: () => new Date(Date.now() - secondsAgo * 1000).toISOString()
  };
  const hook = Object.assign({ el: { dataset: { locale: "en" }, querySelector: () => time } }, definition);
  hook.mounted();
  hook.destroyed();
  return time.textContent;
}

test("time-ago picks its unit from the rounded value", () => {
  assert.equal(timeAgo(10), "now");
  assert.equal(timeAgo(5 * 60), "5 min. ago");
  // 3590 s used to read "60 min. ago", 86,350 s "24 hr. ago".
  assert.equal(timeAgo(3590), "1 hr. ago");
  assert.equal(timeAgo(86350), "yesterday");
  // 6.8 days used to read "7 days ago"; a week and more is a date.
  assert.doesNotMatch(timeAgo(6.8 * 86400), /ago/);
});
