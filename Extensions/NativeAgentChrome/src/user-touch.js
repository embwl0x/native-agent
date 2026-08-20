(() => {
  function report(kind, event) {
    if (event.isTrusted !== true) return;
    chrome.runtime.sendMessage({
      type: "nativeagent.user-touch",
      kind,
    }).catch(() => {});
  }

  window.addEventListener("pointerdown", (event) => report("pointer", event), {
    capture: true,
    passive: true,
  });
  window.addEventListener("keydown", (event) => report("keyboard", event), {
    capture: true,
  });
  window.addEventListener("wheel", (event) => report("scroll", event), {
    capture: true,
    passive: true,
  });
  window.addEventListener("touchstart", (event) => report("touch", event), {
    capture: true,
    passive: true,
  });
})();
