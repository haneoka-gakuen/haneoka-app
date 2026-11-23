import { bar, call, escape, icon, locale, setup, snackbar, t } from "./app.js";

const query = new URLSearchParams(location.search);
const server = query.get("server") === "jp" ? "jp" : "intl";
let selected = query.get("chapter") || "";
const openEpisode = query.get("episode") || "";
const labels = ["ja", "en", "zh-TW", "zh-CN", "ko"];
const name = (value) => typeof value === "string" ? value : value?.[labels.indexOf(locale)] || value?.find?.(Boolean) || "";
const size = (bytes) => new Intl.NumberFormat(locale, {
  style: "unit", unit: bytes >= 1e9 ? "gigabyte" : "megabyte", maximumFractionDigits: 1,
}).format(bytes / (bytes >= 1e9 ? 1e9 : 1e6));
const storage = document.getElementById("storage");
const installed = document.getElementById("installed");
const catalog = document.getElementById("catalog");
const dialog = document.getElementById("delete-dialog");
let state = { installed: [], catalogs: {}, bytes: 0 };
let busy = false;
let search = "";

await setup();
document.title = t("offlineStories");
document.getElementById("bar").innerHTML = bar({ title: t("offlineStories"), back: "index.html?choose" });
document.getElementById("catalog-title").textContent = t("offlineCatalog");
document.getElementById("delete-label").textContent = t("offlineDeleteConfirm");
document.getElementById("delete-cancel").textContent = t("cancel");
document.getElementById("delete-confirm").textContent = t("offlineDelete");
document.getElementById("catalog-actions").innerHTML =
  `<button class="button button--tonal" data-catalog="jp">${escape(t("offlineJp"))}</button>
  <button class="button button--tonal" data-catalog="intl">${escape(t("offlineIntl"))}</button>`;
let catalogServer = server;

const button = (label, action, extra = "", style = "tonal") =>
  `<button type="button" class="button button--${style}" data-action="${action}" ${extra}>${escape(t(label))}</button>`;

function paintStorage() {
  const player = state.pendingPlayer || state.player;
  const transfer = state.transfer;
  const progress = transfer?.total
    ? `<progress max="${transfer.total}" value="${transfer.bytes}" aria-label="${escape(t("offlineDownloading"))}"></progress>
      <span>${escape(size(transfer.bytes))} / ${escape(size(transfer.total))}</span>`
    : transfer ? `<span>${escape(t("offlineDownloading"))}</span>` : "";
  storage.innerHTML = `<h2 class="methods-title">${escape(t("offlineStorage"))}</h2>
    <div class="cluster">
      <span>${escape(size(state.bytes))}</span>
      ${player ? `<span>${escape(t("offlinePlayer"))} ${escape(player.version)}${state.pendingPlayer && state.player ? ` · ${escape(t("offlinePlayerPending"))}` : ""}</span>` : ""}
      ${button("offlineCheckPlayer", "update-player", busy ? "disabled" : "", "text")}
    </div>
    <div class="cluster offline-stories__transfer" aria-live="polite">${progress}
      ${transfer ? button("offlinePause", "pause", "", "text") : ""}
    </div>`;
}

function paintInstalled() {
  const expanded = new Set([...installed.querySelectorAll("details[open]")].map((element) => element.dataset.key));
  installed.innerHTML = `<h2 class="methods-title">${escape(t("offlineDownloaded"))}</h2>` + (state.installed.length
    ? state.installed.map(({ key, server: region, package: chapter }) => {
        const actions = `data-server="${region}" data-chapter="${escape(chapter.id)}" ${busy ? "disabled" : ""}`;
        return `<details class="offline-stories__chapter" data-key="${escape(key)}" ${key === `${server}/${selected}` || expanded.has(key) ? "open" : ""}>
          <summary>${escape(name(chapter.title) || chapter.id)} <span class="muted">${escape(t(region === "jp" ? "offlineJp" : "offlineIntl"))}</span></summary>
          <ul class="list">${chapter.episodes.map((episode) => `<li><button class="row" type="button" data-action="play" ${actions} data-episode="${escape(episode.id)}">
            <span class="row__text"><span class="row__title">${escape(name(episode.title) || episode.id)}</span></span>
            <span class="row__trail">${icon("chevron_right")}</span></button></li>`).join("")}</ul>
          <div class="cluster">
            ${button("offlineUpdate", "download", actions, "text")}
            ${button("offlineDelete", "delete", actions, "text")}
          </div>
        </details>`;
      }).join("")
    : `<p class="muted">${escape(t("offlineEmpty"))}</p>`);
}

function paintCatalog() {
  const chapters = state.catalogs[catalogServer]?.packages;
  const searchInput = document.getElementById("offline-search");
  if (chapters?.length && !searchInput) {
    const input = document.createElement("input");
    input.type = "search";
    input.id = "offline-search";
    input.setAttribute("aria-label", t("offlineSearch"));
    input.placeholder = t("offlineSearch");
    input.value = search;
    input.addEventListener("input", () => { search = input.value; paintCatalog(); });
    catalog.before(input);
  }
  const filter = search.trim().toLocaleLowerCase(locale);
  catalog.innerHTML = chapters ? `<ul class="list">${chapters.filter((chapter) => {
    if (selected === chapter.id || !filter) return true;
    return [name(chapter.title), chapter.id, ...chapter.episodes.map((episode) => name(episode.title))]
      .some((text) => text.toLocaleLowerCase(locale).includes(filter));
  }).map((chapter) => {
    const cached = state.installed.some((row) => row.server === catalogServer && row.package.id === chapter.id);
    const action = `data-server="${catalogServer}" data-chapter="${escape(chapter.id)}" ${busy || cached ? "disabled" : ""}`;
    return `<li class="offline-stories__catalog-row" ${chapter.id === selected ? 'id="requested-chapter"' : ""}>
      <span class="row__text">
        <strong class="row__title">${escape(name(chapter.title) || chapter.id)}</strong>
        <span class="muted">${escape(size(chapter.bytes))}</span>
      </span>
      ${button(cached ? "offlineDownloaded" : "offlineDownload", "download", action)}
    </li>`;
  }).join("")}</ul>` : "";
  document.querySelectorAll("[data-catalog]").forEach((element) => {
    element.disabled = busy;
    element.setAttribute("aria-pressed", String(element.dataset.catalog === catalogServer));
  });
}

function paint() {
  paintStorage();
  paintInstalled();
  paintCatalog();
}

async function refresh() {
  state = await call("offlineStories");
  paint();
}

async function run(method, args, failure) {
  if (busy) return;
  busy = true;
  paint();
  const poll = setInterval(() => {
    void call("offlineTransfer").then((transfer) => {
      if (busy) { state.transfer = transfer; paintStorage(); }
    }).catch(console.error);
  }, 800);
  try {
    await call(method, args);
  } catch (error) {
    if (String(error) !== "paused") snackbar(t(failure));
  } finally {
    clearInterval(poll);
    busy = false;
    await refresh().catch(console.error);
  }
}

document.querySelector("main").addEventListener("click", async (event) => {
  const control = event.target.closest("button");
  if (!control || control.disabled) return;
  if (control.dataset.catalog) {
    catalogServer = control.dataset.catalog;
    selected = "";
    await run("offlineCatalog", { server: catalogServer }, "offlineCatalogFailed");
    return;
  }
  const { action, server: region, chapter, episode } = control.dataset;
  const args = { server: region, chapter, episode, locale };
  switch (action) {
    case "pause":
      await call("offlinePause").catch(console.error);
      break;
    case "update-player":
      await run("offlinePlayerUpdate", {}, "offlineDownloadFailed");
      break;
    case "download":
      await run("offlineDownload", args, "offlineDownloadFailed");
      break;
    case "play":
      await run("offlinePlay", args, "offlinePlayFailed");
      break;
    case "delete":
      dialog.returnValue = "cancel";
      dialog.showModal();
      await new Promise((resolve) => dialog.addEventListener("close", resolve, { once: true }));
      if (dialog.returnValue === "delete") await run("offlineDelete", args, "offlineDownloadFailed");
      break;
  }
});

await refresh().catch(() => snackbar(t("offlinePlayFailed")));
if (query.has("playerError")) snackbar(t("offlinePlayFailed"));
if (selected) {
  const chapter = state.installed.find((row) => row.server === server && row.package.id === selected);
  if (chapter && openEpisode && (state.player || state.pendingPlayer)) {
    await run("offlinePlay", { server, chapter: selected, episode: openEpisode, locale }, "offlinePlayFailed");
  } else {
    await run("offlineCatalog", { server }, "offlineCatalogFailed");
    document.getElementById("requested-chapter")?.scrollIntoView({ block: "center" });
  }
} else if (state.player && navigator.onLine) {
  void call("offlinePlayerUpdate").then(refresh).catch(() => {});
}
