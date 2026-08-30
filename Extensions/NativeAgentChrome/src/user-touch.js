(() => {
  const bindings = [];
  let retired = false;

  function retire() {
    if (retired) return;
    retired = true;
    for (const [name, listener, options] of bindings) {
      window.removeEventListener(name, listener, options);
    }
  }

  function messageFailed(error) {
    if (/extension context invalidated/i.test(String(error?.message ?? error))) retire();
  }

  function report(kind, event) {
    if (retired || event.isTrusted !== true) return;
    // Existing pages can retain this listener after an extension reload. The
    // runtime may disappear or throw before a Promise.catch can handle it.
    try {
      const runtime = globalThis.chrome?.runtime;
      if (typeof runtime?.sendMessage !== "function") {
        retire();
        return;
      }
      Promise.resolve(runtime.sendMessage({
        type: "nativeagent.user-touch",
        kind,
      })).catch(messageFailed);
    } catch (error) {
      messageFailed(error);
    }
  }

  for (const [name, kind] of [
    ["pointerdown", "pointer"],
    ["keydown", "keyboard"],
    ["wheel", "scroll"],
    ["touchstart", "touch"],
  ]) {
    const listener = (event) => report(kind, event);
    const options = { capture: true, ...(name === "keydown" ? {} : { passive: true }) };
    bindings.push([name, listener, options]);
    window.addEventListener(name, listener, options);
  }
})();
