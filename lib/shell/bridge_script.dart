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

  const installDocument = () => {
  // The app is what the download page offers.
  const style = document.createElement("style");
  style.textContent = '.nav li:has(> a[href$="/download/"]), .nav a[href$="/download/"] { display: none !important; }';
  document.documentElement.append(style);

  // The colour the page shows at its top or bottom edge, as it will be once a
  // running colour transition ends, so the system bars change with the page.
  const rgba = (value) => {
    const match = /^(?:rgba?\(|color\(srgb\s+)([^)]+)\)/u.exec(value || "");
    if (!match) return null;
    const [r, g, b, a = 1] = match[1].split(/[\s,/]+/u).filter(Boolean).map(Number);
    const scale = value.startsWith("color(") ? 255 : 1;
    return { r: r * scale, g: g * scale, b: b * scale, a };
  };
  const over = (top, bottom) => {
    const a = top.a + bottom.a * (1 - top.a);
    if (!a) return { r: 0, g: 0, b: 0, a: 0 };
    const mix = (key) => (top[key] * top.a + bottom[key] * bottom.a * (1 - top.a)) / a;
    return { r: mix("r"), g: mix("g"), b: mix("b"), a };
  };
  const edgeSelector = ".app-shell, .app-shell__body, .top-app-bar, .scrim, .sheet-scrim, .sheet, dialog, [popover], [data-app-fullscreen]";
  let duration = 0;
  let styles, animations, opacities, surfaces, fills, boxes, backdrops;
  const cached = (cache, element, read) => {
    if (!cache.has(element)) cache.set(element, read(element));
    return cache.get(element);
  };
  const computed = (element) => cached(styles, element, (node) => getComputedStyle(node));
  const motion = (element) => cached(animations, element, (node) => node.getAnimations?.() ?? []);
  const box = (element) => cached(boxes, element, (node) => node.getBoundingClientRect());
  const contains = (element, x, y) => {
    const rect = box(element);
    return x >= rect.left && x < rect.right && y >= rect.top && y < rect.bottom
      && computed(element).visibility !== "hidden";
  };
  const target = (element, property, current) => {
    const transition = motion(element).find((animation) => animation.transitionProperty === property);
    if (!transition) return current;
    const timing = transition.effect.getComputedTiming();
    duration = Math.max(duration, Math.max(0, timing.endTime - (transition.currentTime ?? 0)));
    return transition.effect.getKeyframes().at(-1)?.[property === "background-color" ? "backgroundColor" : property] ?? current;
  };
  const opacity = (element) => element ? cached(opacities, element, (node) =>
    Number(target(node, "opacity", computed(node).opacity)) * opacity(node.parentElement)) : 1;
  const fill = (element) => cached(fills, element, (node) => {
    const colour = rgba(target(node, "background-color", computed(node).backgroundColor));
    return colour ? { ...colour, a: colour.a * opacity(node) } : null;
  });
  // Content scrolling past an edge is not the edge: use its scroll container.
  const surface = (element) => cached(surfaces, element, (node) => {
    let found = node;
    for (let parent = node; parent && parent !== document.body; parent = parent.parentElement) {
      const { overflowY } = computed(parent);
      if ((overflowY === "auto" || overflowY === "scroll") && parent.scrollHeight > parent.clientHeight) found = parent;
      if (computed(parent).position === "fixed") break;
    }
    return found;
  });
  let underneath = [];
  // Every layer painted at one point, composited top-down: page, scrims, sheets.
  const point = (x, y) => {
    let colour = { r: 0, g: 0, b: 0, a: 0 };
    const seen = new Set();
    // Modal inertness hides the underlying shell from hit testing, not from paint.
    const hits = document.elementsFromPoint(x, y).filter((node) => !node.closest(".nav, .nav-scrim"));
    for (const node of underneath) {
      if (hits.includes(node) || !contains(node, x, y)) continue;
      const ancestor = hits.findIndex((hit) => hit.contains(node));
      hits.splice(ancestor < 0 ? hits.length : ancestor, 0, node);
    }
    for (const hit of hits) {
      if (colour.a >= 0.99) break;
      if (hit instanceof HTMLDialogElement && hit.matches(":modal")) {
        const rect = box(hit);
        if (y < rect.top || y > rect.bottom || x < rect.left || x > rect.right) {
          const scrim = cached(backdrops, hit, (node) => rgba(getComputedStyle(node, "::backdrop").backgroundColor));
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
    const page = rgba(computed(document.documentElement).backgroundColor);
    return colour.a < 0.99 ? over(colour, page && page.a ? page : { r: 255, g: 255, b: 255, a: 1 }) : colour;
  };
  // Colour runs along one edge, as fractions of its width.
  const edge = (y) => {
    const runs = [];
    const step = 4;
    for (let start = 0; start < innerWidth; start += step) {
      const width = Math.min(step, innerWidth - start);
      const color = css(point(start + width / 2, y));
      const last = runs.at(-1);
      if (last?.color === color) last.width += width;
      else runs.push({ color, width });
    }
    return runs.map((run) => ({ color: run.color, width: run.width / innerWidth }));
  };
  const css = ({ r, g, b }) => `rgb(${Math.round(r)}, ${Math.round(g)}, ${Math.round(b)})`;
  const token = (style, name) => style.getPropertyValue(name).trim();
  let reported = "";
  const theme = () => {
    if (document.hidden || fullscreen) return;
    styles = new WeakMap(); animations = new WeakMap(); opacities = new WeakMap();
    surfaces = new WeakMap(); fills = new WeakMap(); boxes = new WeakMap(); backdrops = new WeakMap();
    const root = computed(document.documentElement);
    duration = 0;
    underneath = [".top-app-bar", ".app-shell__main", ".app-shell", "body", "html"]
      .map((selector) => document.querySelector(selector)).filter(Boolean);
    const overlays = [...document.querySelectorAll(".scrim, .sheet-scrim, .sheet.is-open, dialog[open], [popover]")];
    const covered = (y) => overlays.some((node) => {
      const rect = box(node);
      return rect.width > 0 && rect.top <= y && rect.bottom > y && computed(node).visibility !== "hidden";
    });
    const colours = (y) => document.querySelector("[data-shell]") && !covered(y)
      ? [{ color: css(point(innerWidth / 2, y)), width: 1 }] : edge(y);
    const header = document.querySelector(".top-app-bar") || document.body;
    const top = [{ color: target(header, "background-color", computed(header).backgroundColor), width: 1 }];
    const bottom = colours(innerHeight - 1);
    const message = {
      method: "theme",
      args: {
        dark: document.documentElement.dataset.theme === "dark",
        bar: top,
        bottom,
        duration: Math.round(duration),
        background: computed(document.body).backgroundColor,
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
  const spatial = new Set(["transform", "translate", "scale", "width", "height", "left", "right", "top", "bottom", "clip-path"]);
  const moving = (animation) => {
    if (animation.playState !== "running" || animation.effect?.getComputedTiming().activeDuration === Infinity) return false;
    if (animation.transitionProperty) return spatial.has(animation.transitionProperty);
    return animation.effect.getKeyframes().some((frame) => Object.keys(frame).some((key) => spatial.has(key) || key === "opacity"));
  };
  let queued = false;
  const queue = () => {
    if (queued || document.hidden) return;
    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      theme();
      // Follow motion (a sliding drawer, a fading scrim) until it settles.
      if (!fullscreen && [...document.querySelectorAll(edgeSelector), document.documentElement].some((node) =>
        node.getAnimations().some(moving))) queue();
    });
  };
  const watch = () => {
    if (!document.documentElement.dataset.locale || !document.querySelector("main")) return;
    requestAnimationFrame(() => requestAnimationFrame(() => {
      post({ method: "painted", args: {} });
    }));
    theme();
    const affects = (node) => node instanceof Element && (
      node === document.documentElement || node === document.body || node.matches(edgeSelector)
    );
    new MutationObserver((records) => {
      if (records.some((record) => affects(record.target) || (record.type === "childList" &&
        [...record.addedNodes, ...record.removedNodes].some((node) => node instanceof Element &&
          (node.matches(edgeSelector) || node.querySelector(edgeSelector)))))) queue();
    }).observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["class", "style", "open", "data-theme", "data-nav", "data-locale", "lang", "hidden"],
      childList: true,
      subtree: true,
    });
    // The app bar's scroll state changes its class; content scrolling keeps the same edge surfaces.
    for (const type of ["transitionstart", "transitionend", "transitioncancel", "animationstart", "animationend", "animationcancel"]) {
      addEventListener(type, (event) => { if (affects(event.target)) queue(); }, { capture: true, passive: true });
    }
    for (const type of ["resize", "pageshow"]) addEventListener(type, queue);
    for (const type of ["visibilitychange", "fullscreenchange", "astro:after-swap"]) document.addEventListener(type, queue);
    matchMedia("(prefers-color-scheme: dark)").addEventListener("change", queue);
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
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", installDocument, { once: true });
  else installDocument();
})();
''';
