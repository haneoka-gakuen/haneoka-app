// Shared by the app's own pages: the bridge, language, the site's colours,
// icons, snackbars and links into the website.
import strings from "./strings.js";

export const call = (method, args = {}) => window.__TAURI_INTERNALS__
  ? window.__TAURI_INTERNALS__.invoke("bridge", { method, args })
  : Promise.reject(new Error("app_unavailable"));

const LOCALES = ["en", "ja", "ko", "zh-CN", "zh-TW"];
const fromTag = (tag) => {
  const value = (tag || "en").toLowerCase();
  if (value.startsWith("ja")) return "ja";
  if (value.startsWith("ko")) return "ko";
  if (/^zh-(tw|hk|mo|hant)/.test(value)) return "zh-TW";
  if (value.startsWith("zh")) return "zh-CN";
  return "en";
};

export let info = { origins: ["https://haneoka.org", "https://haneoka.com"], chosen: null, locale: null, theme: null };
export let locale = fromTag(navigator.language);

export const t = (key, params = {}) => {
  const text = strings[locale]?.[key] ?? strings.en[key] ?? key;
  return text.replace(/\{(\w+)\}/g, (_, name) => String(params[name] ?? ""));
};

export const number = (value) => (value == null ? "—" : new Intl.NumberFormat(locale).format(value));
export const date = (value, time = false) =>
  value == null
    ? ""
    : new Intl.DateTimeFormat(locale, time ? { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" } : { year: "numeric", month: "short", day: "numeric" }).format(new Date(value));

export const icon = (name, extra = "") => `<svg class="icon ${extra}" aria-hidden="true"><use href="icons.svg#${name}"></use></svg>`;

export const escape = (value) =>
  String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

let snackbarTimer = 0;
export function snackbar(message, options = {}) {
  let element = document.querySelector(".snackbar");
  if (!element) {
    element = document.createElement("div");
    element.className = "snackbar";
    element.setAttribute("role", "status");
    document.body.append(element);
  }
  element.replaceChildren(document.createTextNode(message));
  if (options.action) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "button button--text";
    button.textContent = options.action.label;
    button.addEventListener("click", () => { element.hidden = true; options.action.run(); });
    element.append(button);
  }
  element.hidden = false;
  clearTimeout(snackbarTimer);
  snackbarTimer = setTimeout(() => (element.hidden = true), options.action ? 8000 : 4000);
}

/** The site the reader chose; the first site until they choose. */
export const site = () => info.chosen || info.origins[0];

/** A website page on the chosen site, in the reader's language. */
export function openSite(path) {
  location.assign(site() + path.replace("{locale}", locale));
}

export function returnToSavePage(page, hasParent) {
  if (hasParent && history.length > 1) history.back();
  else location.replace(page);
}

const BAR_TOKENS = ["primary", "on-primary", "primary-container", "on-primary-container", "secondary-container", "on-secondary-container", "tertiary-container",
  "on-tertiary-container", "surface", "on-surface", "on-surface-variant", "surface-container-lowest", "surface-container-low", "surface-container",
  "surface-container-high", "surface-container-highest", "outline", "outline-variant", "error", "inverse-surface", "inverse-on-surface"];

const systemTheme = matchMedia("(prefers-color-scheme: dark)");
function applyTheme() {
  const root = document.documentElement;
  const theme = info.theme;
  const dark = typeof theme?.dark === "boolean" && theme.preference !== "system" ? theme.dark : systemTheme.matches;
  root.dataset.theme = dark ? "dark" : "light";
  const colors = theme?.dark === dark ? theme.colors : undefined;
  for (const name of BAR_TOKENS) {
    const property = `--md-sys-color-${name}`;
    if (colors?.[name]) root.style.setProperty(property, colors[name]);
    else root.style.removeProperty(property);
  }
  const surface = getComputedStyle(root).getPropertyValue("--md-sys-color-surface").trim();
  const rgb = surface.match(/^#([0-9a-f]{6})$/i)
    ? surface
    : (() => {
        const canvas = document.createElement("canvas").getContext("2d");
        canvas.fillStyle = surface;
        return canvas.fillStyle;
      })();
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(rgb.slice(i, i + 2), 16));
  call("systemBars", { color: rgb, dark: 0.299 * r + 0.587 * g + 0.114 * b < 128 }).catch(() => {});
}

/** Language, colours and bars for this page; resolves once the app answered. */
export async function setup() {
  document.documentElement.dataset.theme ??= systemTheme.matches ? "dark" : "light";
  try {
    info = { ...info, ...(await call("appInfo")) };
  } catch {}
  if (info.locale && LOCALES.includes(info.locale)) locale = info.locale;
  document.documentElement.lang = locale;
  applyTheme();
}

systemTheme.addEventListener("change", applyTheme);
addEventListener("pageshow", (event) => { if (event.persisted) void setup(); });

/** The top app bar: back, title and actions. */
export function bar({ title, back, actions = "" }) {
  return `<header class="bar">
    ${back ? `<a class="icon-button" href="${escape(back)}" aria-label="${escape(t("back"))}">${icon("arrow_back")}</a>` : ""}
    <h1>${escape(title)}</h1>
    ${actions}
    <div class="progress bar-progress" hidden></div>
  </header>`;
}

/** Reasons the bridge gives, as the reader reads them. */
export function failure(error) {
  const code = String(error?.message ?? error ?? "");
  if (code.includes("history_missing_session") || code.includes("no_session")) return t("errorMissingSession");
  if (code.includes("history_session_expired")) return t("errorSessionExpired");
  if (code.includes("history_response_invalid")) return t("errorResponseInvalid");
  if (code.includes("history_network_error")) return t("errorNetwork");
  if (code.includes("history_service_unavailable")) return t("errorServiceUnavailable");
  if (code.includes("history_version_unavailable")) return t("errorVersionUnavailable");
  if (code.includes("player_data_unrecognized")) return t("syncUnrecognized");
  if (code.includes("backup_password")) return t("wrongPassword");
  if (code.includes("adb_missing")) return t("adbMissing");
  if (code.includes("history_")) return t("errorGameReadFailed");
  return t("readFailed");
}

export const RELEASES = [
  { id: "com.bushiroad.sirius", name: "releaseJp", emblem: "release-bushimo.svg" },
  { id: "com.bilibili.sirius.official", name: "releaseIntlOfficial", emblem: "release-bilibili.svg" },
  { id: "com.bilibili.sirius", name: "releaseIntlStore", emblem: "release-bilibili.svg" },
];
export const emblem = (release, server) =>
  RELEASES.find((r) => r.id === release)?.emblem ?? (server === "jp" ? "release-bushimo.svg" : "release-bilibili.svg");

/** Material 3's eight-lobed "sunny" shape, for rank badges. */
export const sunny = (() => {
  const points = [];
  for (let i = 0; i < 96; i++) {
    const angle = (i / 96) * Math.PI * 2;
    const radius = 46 * (1 + 0.085 * Math.cos(angle * 8));
    points.push(`${(50 + radius * Math.cos(angle)).toFixed(2)},${(50 + radius * Math.sin(angle)).toFixed(2)}`);
  }
  return `<svg viewBox="0 0 100 100" aria-hidden="true"><polygon points="${points.join(" ")}" /></svg>`;
})();
