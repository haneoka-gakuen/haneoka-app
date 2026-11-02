import 'dart:convert';

/// The JavaScript channel the page posts to.
const bridgeChannel = 'HaneokaAppChannel';

/// Injected at document start of every page: `window.haneokaApp` for the
/// website's app hooks (`src/lib/app-bridge.ts`), the page's colours for the
/// native bars and sheets, and file downloads, which a web view drops.
String bridgeScript({required String version, required String platform}) =>
    _script
        .replaceFirst('__VERSION__', jsonEncode(version))
        .replaceFirst('__PLATFORM__', jsonEncode(platform))
        .replaceFirst('__CHANNEL__', bridgeChannel);

const _script = r'''
(() => {
  if (window.haneokaApp) return;
  const channel = window.__CHANNEL__;
  const post = (message) => channel.postMessage(JSON.stringify(message));
  const pending = new Map();
  let next = 0;
  window.haneokaApp = Object.freeze({
    version: __VERSION__,
    platform: __PLATFORM__,
    call(method, args) {
      const id = ++next;
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        post({ id, method, args: args ?? {} });
      });
    },
  });
  Object.defineProperty(window, "__haneokaAppResolve", {
    value(id, error, value) {
      const call = pending.get(id);
      if (!call) return;
      pending.delete(id);
      if (error) call.reject(new Error(error));
      else call.resolve(value);
    },
  });

  // Element fullscreen, drawn by the app: the element covers the web view and
  // the app hides the system bars, the same on every platform.
  let fullscreen = null;
  const fullscreenChange = (element) => {
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
    post({ method: "fullscreen", args: { active: false } });
    fullscreenChange(element);
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
    post({ method: "fullscreen", args: { active: true } });
    fullscreenChange(this);
    return Promise.resolve();
  };
  Document.prototype.exitFullscreen = function () {
    leave();
    return Promise.resolve();
  };
  Object.defineProperty(window, "__haneokaAppExitFullscreen", { value: leave });
  if (globalThis.screen?.orientation) {
    screen.orientation.lock = (orientation) => {
      post({ method: "orientation", args: { orientation } });
      return Promise.resolve();
    };
    screen.orientation.unlock = () => post({ method: "orientation", args: { orientation: "any" } });
  }

  // The app is what the download page offers.
  const style = document.createElement("style");
  style.textContent = '.nav li:has(> a[href$="/download/"]), .nav a[href$="/download/"] { display: none !important; }';
  document.documentElement.append(style);

  // The colour the page shows at its top or bottom edge, as it will be once a
  // running colour transition ends, so the system bars change with the page.
  const rgba = (value) => {
    const match = /rgba?\(([^)]+)\)/u.exec(value || "");
    if (!match) return null;
    const [r, g, b, a = 1] = match[1].split(/[\s,/]+/u).filter(Boolean).map(Number);
    return { r, g, b, a };
  };
  const over = (top, bottom) => {
    const a = top.a + bottom.a * (1 - top.a);
    if (!a) return { r: 0, g: 0, b: 0, a: 0 };
    const mix = (key) => (top[key] * top.a + bottom[key] * bottom.a * (1 - top.a)) / a;
    return { r: mix("r"), g: mix("g"), b: mix("b"), a };
  };
  let duration = 0;
  const target = (element, property, current) => {
    const transition = element.getAnimations?.().find((animation) => animation.transitionProperty === property);
    if (!transition) return current;
    const timing = transition.effect.getComputedTiming();
    duration = Math.max(duration, Math.max(0, timing.endTime - (transition.currentTime ?? 0)));
    return transition.effect.getKeyframes().at(-1)?.[property === "background-color" ? "backgroundColor" : property] ?? current;
  };
  const fill = (element) => {
    const colour = rgba(target(element, "background-color", getComputedStyle(element).backgroundColor));
    if (!colour) return null;
    let opacity = 1;
    for (let node = element; node; node = node.parentElement) opacity *= Number(target(node, "opacity", getComputedStyle(node).opacity));
    return { ...colour, a: colour.a * opacity };
  };
  // Content scrolling past an edge is not the edge: use its scroll container.
  const surface = (element) => {
    let found = element;
    for (let node = element; node && node !== document.body; node = node.parentElement) {
      const { overflowY } = getComputedStyle(node);
      if ((overflowY === "auto" || overflowY === "scroll") && node.scrollHeight > node.clientHeight) found = node;
    }
    return found;
  };
  // Every layer painted at one point, composited top-down: page, scrims, sheets.
  const point = (x, y) => {
    let colour = { r: 0, g: 0, b: 0, a: 0 };
    const seen = new Set();
    for (const hit of document.elementsFromPoint(x, y)) {
      if (colour.a >= 0.99) break;
      if (hit instanceof HTMLDialogElement && hit.open) {
        const box = hit.getBoundingClientRect();
        if (y < box.top || y > box.bottom || x < box.left || x > box.right) {
          const scrim = rgba(getComputedStyle(hit, "::backdrop").backgroundColor);
          if (scrim && scrim.a > 0) colour = over(colour, scrim);
          continue;
        }
      }
      const layer = surface(hit);
      if (seen.has(layer)) continue;
      seen.add(layer);
      const own = fill(layer);
      if (own && own.a > 0) colour = over(colour, own);
    }
    const page = rgba(getComputedStyle(document.documentElement).backgroundColor);
    return colour.a < 0.99 ? over(colour, page && page.a ? page : { r: 255, g: 255, b: 255, a: 1 }) : colour;
  };
  // Colour runs along one edge, as fractions of its width.
  const edge = (y) => {
    const runs = [];
    const step = 4;
    for (let x = step / 2; x < innerWidth; x += step) {
      const colour = css(point(x, y));
      const last = runs.at(-1);
      if (last?.color === colour) last.width += step;
      else runs.push({ color: colour, width: step });
    }
    return runs.map((run) => ({ color: run.color, width: run.width / innerWidth }));
  };
  const css = ({ r, g, b }) => `rgb(${Math.round(r)}, ${Math.round(g)}, ${Math.round(b)})`;
  const token = (style, name) => style.getPropertyValue(name).trim();
  let reported = "";
  const theme = () => {
    const root = getComputedStyle(document.documentElement);
    duration = 0;
    // Hit testing skips inert and pointer-events: none content that is still
    // painted; lift both for this synchronous read, before any frame.
    const inert = [...document.querySelectorAll("[inert]")];
    for (const element of inert) element.inert = false;
    const hits = document.createElement("style");
    hits.dataset.haneokaApp = "";
    hits.textContent = "* { pointer-events: auto !important; }";
    document.documentElement.append(hits);
    let top, bottom;
    try {
      top = edge(1);
      bottom = edge(innerHeight - 1);
    } finally {
      hits.remove();
      for (const element of inert) element.inert = true;
    }
    const message = {
      method: "theme",
      args: {
        dark: document.documentElement.dataset.theme === "dark",
        bar: top,
        bottom,
        duration: Math.round(duration),
        background: getComputedStyle(document.body).backgroundColor,
        locale: document.documentElement.dataset.locale || document.documentElement.lang,
        colors: Object.fromEntries(
          ["primary", "on-primary", "primary-container", "on-primary-container", "secondary", "on-secondary",
           "secondary-container", "on-secondary-container", "tertiary", "on-tertiary", "error", "on-error",
           "surface", "on-surface", "on-surface-variant", "surface-container-lowest", "surface-container-low",
           "surface-container", "surface-container-high", "surface-container-highest", "outline",
           "outline-variant", "inverse-surface", "inverse-on-surface", "inverse-primary"]
            .map((name) => [name, token(root, "--md-sys-color-" + name)]),
        ),
      },
    };
    const text = JSON.stringify({ ...message, args: { ...message.args, duration: 0 } });
    if (text === reported) return;
    reported = text;
    channel.postMessage(JSON.stringify(message));
  };
  let queued = false;
  const queue = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      theme();
      // Follow motion (a sliding drawer, a fading scrim) until it settles.
      if (document.getAnimations().some((animation) => animation.playState === "running" && animation.effect?.getComputedTiming().activeDuration !== Infinity)) queue();
    });
  };
  const watch = () => {
    theme();
    // The app keeps its launch page up until the page has actually drawn.
    requestAnimationFrame(() => requestAnimationFrame(() => post({ method: "painted", args: {} })));
    const own = (node) => node instanceof HTMLStyleElement && "haneokaApp" in node.dataset;
    new MutationObserver((records) => {
      if (records.some((record) => record.type !== "childList" || ![...record.addedNodes, ...record.removedNodes].every(own))) queue();
    }).observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["class", "open", "data-theme", "hidden"],
      childList: true,
      subtree: true,
    });
    for (const type of ["scroll", "transitionstart", "transitionend", "animationstart", "animationend", "resize"]) addEventListener(type, queue, { capture: true, passive: true });
    matchMedia("(prefers-color-scheme: dark)").addEventListener("change", queue);
    addEventListener("pageshow", queue);
    document.addEventListener("astro:after-swap", queue);
  };
  if (document.readyState === "loading") addEventListener("DOMContentLoaded", watch, { once: true });
  else watch();

  const encode = (buffer) => {
    const bytes = new Uint8Array(buffer);
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(binary);
  };
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
        .then(async (blob) => post({ method: "download", args: { name, type: blob.type, data: encode(await blob.arrayBuffer()) } }));
    },
    true,
  );
})();
''';
