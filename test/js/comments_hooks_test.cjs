// Run with: node --test test/js/comments_hooks_test.cjs
// Exercise the shipped bundle, including asynchronous MediaRecorder events.
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

function audio(getUserMedia, recorderOverrides = {}) {
  const recorders = [];
  class Recorder extends EventTarget {
    static isTypeSupported() { return true; }
    constructor() { super(); this.state = "inactive"; recorders.push(this); }
    start() { this.state = "recording"; }
    stop() {
      this.state = "inactive";
      queueMicrotask(() => {
        dispatch(this, "dataavailable", { data: new Blob(["recorded audio"]) });
        dispatch(this, "stop");
      });
    }
  }
  const definition = hooks({
    navigator: { mediaDevices: { getUserMedia } },
    MediaRecorder: Recorder,
    ...recorderOverrides
  }).PhoenixKitCommentsAudioRecorder;
  return { hook: mount(definition), definition, recorders };
}

function stream() {
  const track = { stopped: false, stop() { this.stopped = true; } };
  return { track, getTracks: () => [track] };
}

test("audio toggles and completed uploads stay within their composer", async () => {
  const media = stream();
  const { hook, definition } = audio(async () => media);
  const sibling = mount(definition);
  dispatch(hook.el, "phx-kit-comments-audio-toggle");
  await new Promise(setImmediate);
  assert.equal(hook.recording, true);
  assert.equal(sibling.recording, false);
  dispatch(hook.el, "phx-kit-comments-audio-toggle");
  await new Promise(setImmediate);
  assert.equal(media.track.stopped, true);
  assert.equal(hook.uploads.length, 1);
  assert.equal(hook.uploads[0].form, hook.el.form);
  assert.equal(await hook.uploads[0].files[0].text(), "recorded audio");
  assert.equal(sibling.uploads.length, 0);
});

test("a late microphone permission after destroy releases the stream", async () => {
  let resolve;
  const media = stream();
  const { hook, recorders } = audio(() => new Promise((done) => { resolve = done; }));
  const pending = hook.start();
  hook.destroyed();
  resolve(media);
  await pending;
  assert.equal(media.track.stopped, true);
  assert.equal(recorders.length, 0);
  assert.equal(hook.events.length, 0);
  assert.equal(hook.uploads.length, 0);
});

test("destroy stops an active recorder without uploading its final events", async () => {
  const media = stream();
  const { hook, recorders } = audio(async () => media);
  await hook.start();
  hook.destroyed();
  await Promise.resolve();
  assert.equal(media.track.stopped, true);
  assert.equal(recorders[0].state, "inactive");
  assert.equal(hook.uploads.length, 0);
  assert.deepEqual(hook.events.map((event) => event.name), ["audio_recording_started"]);
});

test("repeated starts while permission is pending request one stream", async () => {
  let resolve;
  let requests = 0;
  const { hook, recorders } = audio(() => {
    requests++;
    return new Promise((done) => { resolve = done; });
  });
  const first = hook.start();
  const second = hook.start();
  resolve(stream());
  await Promise.all([first, second]);
  assert.equal(requests, 1);
  assert.equal(recorders.length, 1);
  hook.destroyed();
});

test("a browser without MediaRecorder reports unsupported", async () => {
  const { hook } = audio(async () => stream(), { MediaRecorder: undefined });
  await hook.start();
  assert.equal(hook.events[0].payload.reason, "unsupported");
});

test("a recorder start failure reports an error and releases the microphone", async () => {
  const media = stream();
  class BrokenRecorder {
    static isTypeSupported() { return true; }
    constructor() { this.state = "inactive"; }
    addEventListener() {}
    start() { throw new Error("device lost"); }
  }
  const { hook } = audio(async () => media, { MediaRecorder: BrokenRecorder });
  await hook.start();
  assert.equal(media.track.stopped, true);
  assert.equal(hook.events[0].payload.reason, "start_failed");
});
