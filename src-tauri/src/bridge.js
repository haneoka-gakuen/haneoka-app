// Injected at document start of every page: `window.haneokaApp` for the
// website's app hooks (src/lib/app-bridge.ts), element fullscreen and file
// downloads, which a web view drops.
(function installAppBridge() {
  if (window.top !== window || !__ORIGINS__.includes(location.origin) || window.haneokaApp) return;
  const internals = () => window.__TAURI_INTERNALS__;
  const invoke = (method, args) => internals().invoke("bridge", { method, args: args ?? {} });

  // The website tells the app apart by this token; requests keep the engine's own agent.
  const agent = `${navigator.userAgent} HaneokaApp/__VERSION__`;
  Object.defineProperty(Navigator.prototype, "userAgent", { configurable: true, get: () => agent });

  const locale = () => document.documentElement.dataset.locale || location.pathname.split("/")[2] || "en";
  const local = new Set(["openGameAccount", "addGameAccount"]);
  window.haneokaApp = Object.freeze({
    version: "__VERSION__",
    platform: "__PLATFORM__",
    capabilities: Object.freeze(["saveSnapshotV1", "saveSourcesV1", "accountKeysV1"]),
    call(method, args) {
      // The saves page is where the app's saves are read and shown.
      if (local.has(method)) {
        location.assign(`/${locale()}/saves/`);
        return Promise.resolve(null);
      }
      return invoke(method, args);
    },
  });

  // Element fullscreen: the element covers the page and the app window goes
  // fullscreen, the same on every platform.
  let fullscreen = null;
  const changed = (element) => {
    document.dispatchEvent(new Event("fullscreenchange"));
    element.dispatchEvent(new Event("fullscreenchange", { bubbles: true }));
  };
  const leave = () => {
    const element = fullscreen;
    if (!element) return;
    fullscreen = null;
    element.removeAttribute("data-app-fullscreen");
    element.style.cssText = element.dataset.appFullscreenStyle ?? "";
    delete element.dataset.appFullscreenStyle;
    invoke("fullscreen", { active: false }).catch(() => {});
    changed(element);
  };
  Object.defineProperty(Document.prototype, "fullscreenEnabled", { configurable: true, get: () => true });
  Object.defineProperty(Document.prototype, "fullscreenElement", { configurable: true, get: () => fullscreen });
  Element.prototype.requestFullscreen = function () {
    if (fullscreen === this) return Promise.resolve();
    leave();
    fullscreen = this;
    this.dataset.appFullscreenStyle = this.style.cssText;
    this.setAttribute("data-app-fullscreen", "");
    for (const [name, value] of [["position", "fixed"], ["inset", "0"], ["width", "100vw"], ["height", "100dvh"], ["max-width", "none"], ["max-height", "none"], ["margin", "0"], ["z-index", "2147483647"]])
      this.style.setProperty(name, value, "important");
    invoke("fullscreen", { active: true }).catch(() => {});
    changed(this);
    return Promise.resolve();
  };
  Document.prototype.exitFullscreen = function () {
    leave();
    return Promise.resolve();
  };
  addEventListener("keydown", (event) => {
    if (event.key === "Escape" && fullscreen) leave();
  });
  if (globalThis.screen?.orientation) {
    screen.orientation.lock = (orientation) => invoke("orientation", { orientation }).then(() => {});
    screen.orientation.unlock = () => void invoke("orientation", { orientation: "any" }).catch(() => {});
  }

  const encode = (buffer) => {
    const bytes = new Uint8Array(buffer);
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(binary);
  };
  const install = () => {
    // The app is what the download page offers.
    const style = document.createElement("style");
    style.textContent = '.nav li:has(> a[href$="/download/"]), .nav a[href$="/download/"] { display: none !important; }';
    document.documentElement.append(style);
    document.addEventListener(
      "click",
      (event) => {
        const link = event.target instanceof Element ? event.target.closest("a[download]") : null;
        if (!link || !link.href) return;
        const url = new URL(link.href, location.href);
        if (url.protocol !== "blob:" && url.protocol !== "data:" && url.origin !== location.origin) return;
        event.preventDefault();
        const name = link.getAttribute("download") || url.pathname.split("/").pop() || "download";
        fetch(url.href)
          .then((response) => response.blob())
          .then(async (blob) => invoke("download", { name, type: blob.type, data: encode(await blob.arrayBuffer()) }))
          .catch(() => {});
      },
      true,
    );
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", install, { once: true });
  else install();
})();
