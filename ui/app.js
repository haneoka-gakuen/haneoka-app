// Shared by the app's own pages: the bridge, language, the site's colours,
// icons, snackbars and links into the website.
import strings from "./strings.js";

export const call = (method, args = {}) => window.__TAURI_INTERNALS__.invoke("bridge", { method, args });

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
export function snackbar(message) {
  let element = document.querySelector(".snackbar");
  if (!element) {
    element = document.createElement("div");
    element.className = "snackbar";
    element.setAttribute("role", "status");
    document.body.append(element);
  }
  element.textContent = message;
  element.hidden = false;
  clearTimeout(snackbarTimer);
  snackbarTimer = setTimeout(() => (element.hidden = true), 4000);
}

/** The site the reader chose; the first site until they choose. */
export const site = () => info.chosen || info.origins[0];

/** A website page on the chosen site, in the reader's language. */
export function openSite(path) {
  location.assign(site() + path.replace("{locale}", locale));
}

const BAR_TOKENS = ["primary", "on-primary", "primary-container", "on-primary-container", "secondary-container", "on-secondary-container", "tertiary-container",
  "on-tertiary-container", "surface", "on-surface", "on-surface-variant", "surface-container-lowest", "surface-container-low", "surface-container",
  "surface-container-high", "surface-container-highest", "outline", "outline-variant", "error", "inverse-surface", "inverse-on-surface"];

/** Language, colours and bars for this page; resolves once the app answered. */
export async function setup() {
  try {
    info = { ...info, ...(await call("appInfo")) };
  } catch {}
  if (info.locale && LOCALES.includes(info.locale)) locale = info.locale;
  document.documentElement.lang = locale;
  const theme = info.theme;
  if (theme?.colors) {
    const dark = matchMedia("(prefers-color-scheme: dark)").matches;
    // The site's colours apply when the reader's light or dark setting matches them.
    if (Boolean(theme.dark) === dark) {
      for (const name of BAR_TOKENS) if (theme.colors[name]) document.documentElement.style.setProperty(`--md-sys-color-${name}`, theme.colors[name]);
    }
  }
  const surface = getComputedStyle(document.documentElement).getPropertyValue("--md-sys-color-surface").trim();
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

/** The top app bar: back, title and actions. */
export function bar({ title, back, actions = "" }) {
  return `<header class="bar">
    ${back ? `<a class="icon-button" href="${escape(back)}" aria-label="${escape(t("back"))}">${icon("arrow_back")}</a>` : ""}
    <h1>${escape(title)}</h1>
    ${actions}
  </header>`;
}

/** Reasons the bridge gives, as the reader reads them. */
export function failure(error) {
  const code = String(error?.message ?? error ?? "");
  if (code.includes("history_session_expired") || code.includes("no_session") || code.includes("history_missing_session")) return t("syncSessionExpired");
  if (code.includes("player_data_unrecognized") || code.includes("history_response_invalid")) return t("syncUnrecognized");
  if (code.includes("backup_password")) return t("wrongPassword");
  if (code.includes("adb_missing")) return t("adbMissing");
  if (code.includes("history_")) return t("syncFailed");
  return t("readFailed");
}

export const RELEASES = [
  { id: "com.bushiroad.sirius", name: "releaseJp", emblem: "release-bushimo.svg" },
  { id: "com.bilibili.sirius.official", name: "releaseIntlOfficial", emblem: "release-bilibili.svg" },
  { id: "com.bilibili.sirius", name: "releaseIntlStore", emblem: "release-bilibili.svg" },
];
export const emblem = (release, server) =>
  RELEASES.find((r) => r.id === release)?.emblem ?? (server === "jp" ? "release-bushimo.svg" : "release-bilibili.svg");
