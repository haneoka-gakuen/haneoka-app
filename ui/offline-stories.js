import { bar, call, escape, icon, locale, setup, snackbar, t } from "./app.js";

const query = new URLSearchParams(location.search);
const regions = ["jp", "en", "tw", "cn", "kr"];
const providerSections = {
  gbp: ["event", "band", "main", "afterlive", "card"],
  sekai: ["event", "unit", "character", "card", "area", "special", "mysekai", "live"],
};
const labelsBySource = {
  jp: "offlineJp", intl: "offlineIntl", gbp: "offlineGbp", sekai: "offlineSekai", community: "offlineCommunity",
};
const sourceLabel = (server) => {
  const [source, region] = server.split(".");
  const name = t(labelsBySource[source]);
  if (source === "jp" || source === "intl") return `Our Notes / ${name}`;
  return name + (region ? ` / ${region.toUpperCase()}` : "");
};
const [requestedSource, requestedRegion] = (query.get("server") || "").split(".");
const initialSource = Object.hasOwn(labelsBySource, requestedSource) ? requestedSource : "intl";
let selected = query.get("chapter") || "";
const openEpisode = query.get("episode") || "";
const labels = ["ja", "en", "zh-TW", "zh-CN", "ko"];
const name = (value) => typeof value === "string" ? value : value?.[labels.indexOf(locale)] || value?.find?.(Boolean) || "";
const size = (bytes) => {
  const [unit, divisor] = bytes >= 1e9 ? ["gigabyte", 1e9] : bytes >= 1e6 ? ["megabyte", 1e6]
    : bytes >= 1e3 ? ["kilobyte", 1e3] : ["byte", 1];
  return new Intl.NumberFormat(locale, { style: "unit", unit, maximumFractionDigits: 1 }).format(bytes / divisor);
};
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
document.getElementById("catalog-icon").innerHTML = icon("menu_book");
document.getElementById("catalog-title").textContent = t("offlineCatalog");
document.getElementById("delete-label").textContent = t("offlineDeleteConfirm");
document.getElementById("delete-cancel").textContent = t("cancel");
document.getElementById("delete-confirm").textContent = t("offlineDelete");
const catalogActions = document.getElementById("catalog-actions");
let catalogSource = initialSource;
const defaultRegion = ({ en: "en", "zh-TW": "tw", "zh-CN": "cn", ko: "kr" })[locale] || "jp";
let catalogRegion = regions.includes(requestedRegion) ? requestedRegion : defaultRegion;
let catalogSection = providerSections[catalogSource]?.includes(selected.split(".")[0]) ? selected.split(".")[0] : "event";
const catalogServer = () => providerSections[catalogSource] ? `${catalogSource}.${catalogRegion}` : catalogSource;
const selectedSection = () => providerSections[catalogSource] ? catalogSection : "";
const catalogKey = () => [catalogServer(), selectedSection()].filter(Boolean).join("/");
const initialServer = catalogServer();
const menu = (id, label, items, value) => `<label class="field offline-stories__filter">${escape(t(label))}
  <select id="${id}">${items.map(([key, text]) => `<option value="${key}" ${value === key ? "selected" : ""}>${escape(text)}</option>`).join("")}</select>
</label>`;

function paintFilters() {
  const sections = providerSections[catalogSource];
  if (sections && !sections.includes(catalogSection)) catalogSection = sections[0];
  catalogActions.innerHTML = [
    menu("offline-source", "offlineSource", Object.keys(labelsBySource).map((source) => [source, sourceLabel(source)]), catalogSource),
    sections ? menu("offline-region", "offlineRegion", regions.map((region) => [region, region.toUpperCase()]), catalogRegion) : "",
    sections ? menu("offline-section", "offlineSection", sections.map((section) => [section, t(`offlineSection_${section}`)]), catalogSection) : "",
    button("offlineLoadCatalog", "load-catalog", "", "filled", "menu_book"),
  ].join("");
}

async function loadCatalog(episode) {
  await run("offlineCatalog", { server: catalogServer(), section: selectedSection(), episode }, "offlineCatalogFailed");
}

const button = (label, action, extra = "", style = "tonal", glyph = "") =>
  `<button type="button" class="button button--${style}" data-action="${action}" ${extra}>${glyph ? icon(glyph) : ""}${escape(t(label))}</button>`;

function paintStorage() {
  const player = state.pendingPlayer || state.player;
  const transfer = state.transfer;
  const progress = transfer?.total && !transfer.discovering
    ? `<progress max="${transfer.total}" value="${transfer.bytes}" aria-label="${escape(t("offlineDownloading"))}"></progress>
      <span>${escape(size(transfer.bytes))} / ${escape(size(transfer.total))}</span>`
    : transfer ? `<progress aria-label="${escape(t("offlineDownloading"))}"></progress>
      <span>${escape(transfer.bytes ? size(transfer.bytes) : t("offlineDownloading"))}</span>` : "";
  storage.innerHTML = `<div class="story-storage__head">
    <span class="section-badge">${icon("sd_card")}</span>
    <div class="grow"><h2 class="row__supporting">${escape(t("offlineStorage"))}</h2>
    <strong class="story-storage__size">${escape(size(state.bytes))}</strong></div>
    <div class="story-player">${player ? `<span class="row__supporting">${escape(t("offlinePlayer"))} ${escape(player.version)}${state.pendingPlayer ? ` · ${escape(t("offlinePlayerPending"))}` : ""}</span>` : ""}
    ${button("offlineCheckPlayer", "update-player", busy ? "disabled" : "", "text", "refresh")}</div>
    </div>${transfer ? `<div class="story-transfer">${progress}${button("offlinePause", "pause", "", "tonal")}</div>` : ""}`;
}

function paintInstalled() {
  const expanded = new Set([...installed.querySelectorAll("details[open]")].map((element) => element.dataset.key));
  installed.innerHTML = `<h2 class="section-title" id="library-title"><span class="section-badge">${icon("folder_special")}</span>${escape(t("offlineDownloaded"))}<span class="badge">${state.installed.length}</span></h2>` + (state.installed.length
    ? state.installed.map(({ key, server: region, package: chapter }) => {
        const actions = `data-server="${escape(region)}" data-chapter="${escape(chapter.id)}" ${busy ? "disabled" : ""}`;
        return `<details class="fold story-chapter" data-key="${escape(key)}" ${key === `${initialServer}/${selected}` || expanded.has(key) ? "open" : ""}>
          <summary><span class="row__text"><strong class="row__title">${escape(name(chapter.title) || chapter.id)}</strong><span class="row__supporting">${escape(sourceLabel(region))}</span></span>${icon("expand_more")}</summary>
          <div class="fold__body">
          <ul class="list">${chapter.episodes.map((episode) => `<li><button class="row" type="button" data-action="play" ${actions} data-episode="${escape(episode.id)}">
            <span class="row__text"><span class="row__title">${escape(name(episode.title) || episode.id)}</span></span>
            <span class="row__trail">${icon("chevron_right")}</span></button></li>`).join("")}</ul>
          <div class="cluster">
            ${chapter.missing_media ? `<span class="muted">${escape(t("offlineMissingMedia", { count: chapter.missing_media }))}</span>` : ""}
            ${button("offlineUpdate", "download", actions, "tonal", "refresh")}
            ${button("offlineDelete", "delete", actions, "text", "delete")}
          </div>
          </div>
        </details>`;
      }).join("")
    : `<p class="story-empty muted">${icon("folder_open")}${escape(t("offlineEmpty"))}</p>`);
}

const searchField = document.getElementById("offline-search-field");
const searchInput = document.getElementById("offline-search");
searchInput.setAttribute("aria-label", t("offlineSearch"));
searchInput.placeholder = t("offlineSearch");
searchInput.addEventListener("input", () => {
  search = searchInput.value;
  paintCatalog();
});

function paintCatalog() {
  const chapters = state.catalogs[catalogKey()]?.packages;
  searchField.hidden = !chapters?.length;
  const filter = search.trim().toLocaleLowerCase(locale);
  const matches = chapters?.filter((chapter) => {
    if (selected === chapter.id || !filter) return true;
    return [name(chapter.title), name(chapter.group), chapter.id, ...chapter.episodes.map((episode) => name(episode.title))]
      .some((text) => text.toLocaleLowerCase(locale).includes(filter));
  });
  catalog.innerHTML = matches?.length ? `<ul class="list">${matches.map((chapter) => {
    const cached = state.installed.some((row) => row.server === catalogServer() && row.package.id === chapter.id);
    const action = `data-server="${escape(catalogServer())}" data-chapter="${escape(chapter.id)}" ${busy || cached ? "disabled" : ""}`;
    return `<li class="row story-catalog-row" ${chapter.id === selected ? 'id="requested-chapter"' : ""}>
      <span class="row__text">
        <strong class="row__title">${escape(name(chapter.title) || chapter.id)}</strong>
        ${chapter.group || chapter.bytes ? `<span class="muted">${escape([name(chapter.group), chapter.bytes ? size(chapter.bytes) : ""].filter(Boolean).join(" · "))}</span>` : ""}
      </span>
      <button class="icon-button icon-button--tonal" type="button" data-action="download" ${action}
        aria-label="${escape(t(cached ? "offlineDownloaded" : "offlineDownload"))} · ${escape(name(chapter.title) || chapter.id)}"
        title="${escape(t(cached ? "offlineDownloaded" : "offlineDownload"))}">${icon(cached ? "check" : "download")}</button>
    </li>`;
  }).join("")}</ul>` : chapters ? `<p class="story-empty muted">${escape(t("offlineNoMatches"))}</p>` : "";
  catalogActions.querySelectorAll("select, button").forEach((element) => { element.disabled = busy; });
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

paintFilters();
catalogActions.addEventListener("change", async (event) => {
  if (event.target.id === "offline-source") catalogSource = event.target.value;
  if (event.target.id === "offline-region") catalogRegion = event.target.value;
  if (event.target.id === "offline-section") catalogSection = event.target.value;
  selected = "";
  search = "";
  searchInput.value = "";
  const filterId = event.target.id;
  paintFilters();
  document.getElementById(filterId)?.focus();
  paintCatalog();
  if (!state.catalogs[catalogKey()] && navigator.onLine) await loadCatalog();
});

document.querySelector("main").addEventListener("click", async (event) => {
  const control = event.target.closest("button");
  if (!control || control.disabled) return;
  const { action, server: region, chapter, episode } = control.dataset;
  const args = { server: region, chapter, episode, locale };
  switch (action) {
    case "load-catalog":
      await loadCatalog();
      break;
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
      document.getElementById("delete-chapter").textContent = control.closest("details")?.querySelector(".row__title")?.textContent || chapter;
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
  const chapter = state.installed.find((row) => row.server === initialServer && row.package.id === selected);
  if (chapter && openEpisode && (state.player || state.pendingPlayer)) {
    await run("offlinePlay", { server: initialServer, chapter: selected, episode: openEpisode, locale }, "offlinePlayFailed");
  } else {
    await loadCatalog(providerSections[catalogSource] || catalogSource === "community" ? openEpisode || selected : undefined);
    document.getElementById("requested-chapter")?.scrollIntoView({ block: "nearest" });
  }
} else if (state.player && navigator.onLine) {
  void call("offlinePlayerUpdate").then(refresh).catch(() => {});
}
