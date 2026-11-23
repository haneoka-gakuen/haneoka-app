import { bar, call, escape, icon, locale, openSite, setup, snackbar, t } from "./app.js";

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
const queue = document.getElementById("queue");
const browser = document.getElementById("browser");
const selection = new Set();
let managing = false;
let requestedGroupOpened = false;
const dialog = document.getElementById("delete-dialog");
let state = { installed: [], catalogs: {}, bytes: 0 };
let busy = false;
let search = "";

await setup();
document.title = t("offlineStories");
document.getElementById("bar").innerHTML = bar({ title: t("offlineStories"), back: "index.html?choose" });
document.querySelector(".story-disclosure").innerHTML = icon("expand_more");
document.getElementById("catalog-icon").innerHTML = icon("menu_book");
document.getElementById("catalog-title").textContent = t("offlineCatalog");
document.getElementById("delete-label").textContent = t("offlineBatchDelete");
document.getElementById("delete-cancel").textContent = t("cancel");
document.getElementById("delete-confirm").textContent = t("remove");
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
  storage.innerHTML = `<div class="story-storage__head">
    <span class="section-badge">${icon("sd_card")}</span>
    <div class="grow"><h2 class="row__supporting">${escape(t("offlineStorage"))}</h2>
    <strong class="story-storage__size">${escape(size(state.bytes))}</strong></div>
    <div class="story-player">${player ? `<span class="row__supporting">${escape(t("offlinePlayer"))} ${escape(player.version)}${state.pendingPlayer ? ` · ${escape(t("offlinePlayerPending"))}` : ""}</span>` : ""}
    ${button("offlineCheckPlayer", "update-player", busy ? "disabled" : "", "text", "refresh")}</div>
    </div>`;
}

function groups() {
  const grouped = new Map();
  for (const row of state.installed) {
    const chapter = row.package;
    const group = name(chapter.group);
    const key = JSON.stringify([row.server, chapter.groupId || group || chapter.id]);
    if (!grouped.has(key)) grouped.set(key, { key, title: group || name(chapter.title) || chapter.id, rows: [] });
    grouped.get(key).rows.push(row);
  }
  for (const group of grouped.values()) {
    group.rows.sort((a, b) => a.package.id.localeCompare(b.package.id, locale, { numeric: true }));
  }
  return [...grouped.values()];
}

function thumb(url, small = false) {
  return `<span class="story-thumb${small ? " story-thumb--small" : ""}">${icon("menu_book")}
    ${url ? `<img loading="lazy" decoding="async" alt="" src="${escape(url)}">` : ""}</span>`;
}
document.querySelector("main").addEventListener("error", (event) => {
  if (event.target.matches?.(".story-thumb img")) event.target.remove();
}, true);

function check(key, title, checked, group = false) {
  return `<input class="story-check" type="checkbox" data-${group ? "group" : "key"}="${escape(key)}"
    aria-label="${escape(title)}" ${checked ? "checked" : ""}>`;
}

function libraryGroup(group, expanded) {
  const { key, rows, title } = group;
  const artwork = rows.map(({ package: story }) => story.thumbnail || story.episodes[0].thumbnail).find(Boolean);
  const open = expanded.has(key) || (!requestedGroupOpened && rows.some(({ server, package: story }) =>
    server === initialServer && (story.groupId === selected || story.id === (openEpisode || selected))));
  const items = rows.map(({ key: storyKey, server, package: story }) => {
    const episode = story.episodes[0];
    const storyTitle = name(episode.title) || name(story.title) || story.id;
    const image = episode.thumbnail || story.thumbnail;
    const content = `${image ? thumb(image, true) : ""}<span class="row__text"><strong class="row__title">${escape(storyTitle)}</strong>
      ${managing ? "" : `<span class="row__supporting">${escape(t("offlineOpenStory"))}</span>`}</span>`;
    return `<li class="story-package">
      ${managing ? `<label class="row">${check(storyKey, storyTitle, selection.has(storyKey))}${content}</label>` :
        `<button class="row" data-action="open-story" data-server="${escape(server)}" data-chapter="${escape(story.id)}"
          data-episode="${escape(story.id)}" ${busy ? "disabled" : ""}>${content}${icon("chevron_right")}</button>`}
      ${story.missing_media ? `<span class="row__supporting story-receipt">${escape(t("offlineMissingMedia", { count: story.missing_media }))}</span>` : ""}
    </li>`;
  }).join("");
  return `<div class="story-group">${managing ? check(key, title, rows.every((row) => selection.has(row.key)), true) : ""}
    <details class="fold story-chapter" data-key="${escape(key)}" ${open ? "open" : ""}>
    <summary>${thumb(artwork)}<span class="row__text"><strong class="row__title">${escape(title)}</strong>
      <span class="row__supporting">${escape(sourceLabel(rows[0].server))} · ${escape(t("offlineEpisodes", { count: rows.length }))}</span></span>
      <span class="story-disclosure">${icon("expand_more")}</span></summary>
    <ul class="list fold__body">${items}</ul></details></div>`;
}

function paintInstalled() {
  const expanded = new Set([...installed.querySelectorAll("details[open]")].map((el) => el.dataset.key));
  const validKeys = new Set(state.installed.map((row) => row.key));
  for (const key of selection) if (!validKeys.has(key)) selection.delete(key);
  if (!state.installed.length) managing = false;
  const library = groups();
  installed.innerHTML = `<header class="story-heading"><h2 class="section-title" id="library-title">
    <span class="section-badge">${icon("folder_special")}</span>${escape(t("offlineLibrary"))}</h2>
    ${library.length ? button(managing ? "cancel" : "offlineManage", "manage", "", "text", managing ? "" : "checklist") : ""}</header>
    ${managing ? `<div class="story-selection"><label>${check("", t("offlineSelectAll"), selection.size === state.installed.length, true)}${escape(t("offlineSelectAll"))}</label>
      <span class="row__supporting" role="status">${escape(t("offlineSelected", { count: selection.size }))}</span>
      <div class="cluster">${button("offlineUpdate", "batch-update", selection.size && !busy ? "" : "disabled", "tonal", "refresh")}
      ${button("remove", "batch-delete", selection.size && !busy ? "" : "disabled", "text", "delete")}</div></div>` : ""}
    ${library.length ? library.map((group) => libraryGroup(group, expanded)).join("") :
      `<section class="empty"><span class="method__icon method__icon--empty">${icon("menu_book")}</span><h3>${escape(t("offlineEmpty"))}</h3>
      <p class="muted">${escape(t("offlineEmptyHelp"))}</p>${button("offlineLoadCatalog", "browse", "", "tonal", "public")}</section>`}`;
  requestedGroupOpened ||= library.length > 0;
  for (const box of installed.querySelectorAll("[data-group]")) {
    const rows = library.find((group) => group.key === box.dataset.group)?.rows || state.installed;
    box.indeterminate = !box.checked && rows.some((row) => selection.has(row.key));
  }
}

installed.addEventListener("change", (event) => {
  const box = event.target;
  if (!box.matches(".story-check")) return;
  const rows = box.hasAttribute("data-key") ? state.installed.filter((row) => row.key === box.dataset.key)
    : groups().find((group) => group.key === box.dataset.group)?.rows || state.installed;
  for (const row of rows) {
    if (box.checked) selection.add(row.key);
    else selection.delete(row.key);
  }
  paintInstalled();
  installed.querySelector(`input[data-${box.hasAttribute("data-key") ? "key" : "group"}="${CSS.escape(box.dataset.key ?? box.dataset.group)}"]`)?.focus();
});

function paintQueue() {
  const entries = state.queue || [];
  const transfer = state.transfer;
  const progress = transfer?.total && !transfer.discovering
    ? `<progress max="${transfer.total}" value="${transfer.bytes}" aria-label="${escape(t("offlineDownloading"))}"></progress>
      <span>${escape(size(transfer.bytes))} / ${escape(size(transfer.total))}</span>`
    : transfer ? `<progress aria-label="${escape(t("offlineDownloading"))}"></progress>
      <span>${escape(transfer.bytes ? size(transfer.bytes) : t("offlineDownloading"))}</span>` : "";
  queue.hidden = !entries.length && !transfer;
  if (queue.hidden) return;
  const statuses = { queued: "offlineQueued", downloading: "offlineDownloading", active: "offlineDownloading", paused: "offlinePaused", failed: "offlineFailed" };
  const queueRow = (entry) => {
    const actions = `data-server="${escape(entry.server)}" data-chapter="${escape(entry.chapter)}" ${entry.episode ? `data-episode="${escape(entry.episode)}"` : ""}`;
    return `<li class="story-queue-item"><span class="row__text"><strong class="row__title">${escape(name(entry.title) || entry.chapter)}</strong>
        <span class="row__supporting">${escape(sourceLabel(entry.server))} · ${escape(t(statuses[entry.state] || "offlineQueued"))}</span></span>
        ${entry.state === "failed" ? button("retry", "queue-retry", actions, "text") : ""}
        ${entry.state !== "downloading" && entry.state !== "active" ? `<button class="icon-button" data-action="queue-remove" ${actions} aria-label="${escape(t("remove"))}">${icon("delete")}</button>` : ""}</li>`;
  };
  const heading = `<header class="story-heading"><h2 class="section-title" id="queue-title"><span class="section-badge">${icon("download")}</span>
    ${escape(t("offlineQueue"))}<span class="badge">${entries.length || 1}</span></h2>
    ${entries.length ? button(state.queuePaused ? "offlineResume" : "offlinePause", state.queuePaused ? "queue-resume" : "queue-pause", "", "text") : button("offlinePause", "pause", "", "text")}</header>
    ${transfer ? `<div class="story-transfer">${progress}</div>` : ""}`;
  const focused = queue.contains(document.activeElement) ? document.activeElement : null;
  const expanded = queue.querySelector("details")?.open;
  queue.innerHTML = heading + `<ul class="list">${entries.slice(0, 2).map(queueRow).join("")}</ul>` +
    (entries.length > 2 ? `<details class="fold story-more" ${expanded ? "open" : ""}>
      <summary>${escape(t("offlineMoreJobs", { count: entries.length - 2 }))}${icon("expand_more")}</summary>
      <ul class="list fold__body">${entries.slice(2).map(queueRow).join("")}</ul></details>` : "");
  if (focused?.matches("summary")) queue.querySelector("summary")?.focus({ preventScroll: true });
  if (focused?.matches("button")) {
    const next = [...queue.querySelectorAll("button")].find((button) =>
      Object.keys(focused.dataset).every((key) => button.dataset[key] === focused.dataset[key]));
    next?.focus({ preventScroll: true });
  }
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
  const server = catalogServer();
  const saved = new Set(state.installed.filter((row) => row.server === server).map((row) => row.package.id));
  const pending = new Set(state.queue?.filter((row) => row.server === server && row.state !== "failed").map((row) => row.episode || row.chapter));
  catalog.innerHTML = matches?.length ? `<ul class="list">${matches.map((chapter) => {
    const cached = chapter.episodes.length > 0 && chapter.episodes.every((episode) => saved.has(episode.id));
    const queued = !cached && chapter.episodes.length > 0 && chapter.episodes.every((episode) => saved.has(episode.id) || pending.has(episode.id));
    const status = cached ? "offlineDownloaded" : queued ? "offlineQueued" : "offlineDownload";
    const action = `data-server="${escape(server)}" data-chapter="${escape(chapter.id)}" ${busy || cached || queued || !chapter.episodes.length ? "disabled" : ""}`;
    return `<li class="row story-catalog-row" ${chapter.id === selected ? 'id="requested-chapter"' : ""}>
      <span class="row__text">
        <strong class="row__title">${escape(name(chapter.title) || chapter.id)}</strong>
        ${chapter.group || chapter.bytes ? `<span class="muted">${escape([name(chapter.group), chapter.bytes ? size(chapter.bytes) : ""].filter(Boolean).join(" · "))}</span>` : ""}
      </span>
      <button class="icon-button icon-button--tonal" type="button" data-action="download" ${action}
        aria-label="${escape(t(status))} · ${escape(name(chapter.title) || chapter.id)}"
        title="${escape(t(status))}">${icon(cached ? "check" : queued ? "history" : "download")}</button>
    </li>`;
  }).join("")}</ul>` : chapters ? `<p class="story-empty muted">${escape(t("offlineNoMatches"))}</p>` : "";
  catalogActions.querySelectorAll("select, button").forEach((element) => { element.disabled = busy; });
}

function paint() {
  paintStorage();
  paintInstalled();
  paintQueue();
  paintCatalog();
}

let revision = 0;
let needsFullPaint = false;
async function refresh(force = true) {
  needsFullPaint ||= force;
  const request = ++revision;
  const next = await call("offlineStories");
  if (request !== revision) return;
  force = needsFullPaint;
  needsFullPaint = false;
  const previous = state;
  state = next;
  if (force || JSON.stringify(previous.installed) !== JSON.stringify(next.installed)) paintInstalled();
  if (force || JSON.stringify(previous.catalogs) !== JSON.stringify(next.catalogs) ||
      JSON.stringify(previous.queue) !== JSON.stringify(next.queue) || previous.installed.length !== next.installed.length) paintCatalog();
  if (force || previous.bytes !== next.bytes || previous.player?.version !== next.player?.version ||
      previous.pendingPlayer?.version !== next.pendingPlayer?.version) paintStorage();
  if (force || previous.queuePaused !== next.queuePaused || JSON.stringify(previous.queue) !== JSON.stringify(next.queue) ||
      JSON.stringify(previous.transfer) !== JSON.stringify(next.transfer)) paintQueue();
}

async function run(method, args, failure) {
  if (busy) return false;
  busy = true;
  paint();
  try {
    await call(method, args);
    return true;
  } catch (error) {
    if (String(error) !== "paused") snackbar(t(failure));
    return false;
  } finally {
    busy = false;
    await refresh().catch(console.error);
  }
}

window.addEventListener("haneoka-offline-stories", () => void refresh(false).catch(console.error));
window.addEventListener("pageshow", (event) => { if (event.persisted) void refresh().catch(console.error); });
let polling = false;
setInterval(async () => {
  const working = !state.queuePaused && state.queue?.some((job) => ["queued", "downloading"].includes(job.state));
  if (polling || document.hidden || !(busy || working || state.transfer)) return;
  polling = true;
  try { await refresh(false); } catch (error) { console.error(error); } finally { polling = false; }
}, 1500);

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
    case "manage":
      managing = !managing;
      selection.clear();
      paintInstalled();
      installed.querySelector('[data-action="manage"]').focus();
      break;
    case "browse":
      openSite(`/${catalogSource === "jp" ? "jp" : "intl"}/{locale}/stories/`);
      break;
    case "batch-update":
    case "batch-delete": {
      const rows = state.installed.filter((row) => selection.has(row.key));
      if (!rows.length) return;
      if (action === "batch-delete") {
        document.getElementById("delete-chapter").innerHTML = rows.map((row) =>
          `<li>${escape(name(row.package.title) || row.package.id)} · ${escape(sourceLabel(row.server))}</li>`).join("");
        dialog.returnValue = "cancel";
        dialog.showModal();
        await new Promise((resolve) => dialog.addEventListener("close", resolve, { once: true }));
        if (dialog.returnValue !== "delete") return;
      }
      const items = rows.map((row) => ({ server: row.server, chapter: row.package.id }));
      if (await run("offlineManage", { action: action === "batch-delete" ? "delete" : "update", items }, "offlineManageFailed")) {
        managing = false;
        selection.clear();
        paintInstalled();
      }
      break;
    }
    case "queue-retry":
    case "queue-remove":
    case "queue-pause":
    case "queue-resume":
      await run("offlineQueue", { action: action.slice(6), items: chapter ? [{ server: region, chapter, episode }] : undefined }, "offlineManageFailed");
      break;
    case "load-catalog":
      await loadCatalog();
      break;
    case "pause":
      await call("offlinePause").catch(console.error);
      break;
    case "update-player":
      await run("offlinePlayerUpdate", {}, "offlineDownloadFailed");
      break;
    case "download": {
      const entry = state.catalogs[catalogKey()]?.packages.find((item) => item.id === chapter);
      if (!entry) return;
      const items = entry.episodes.map((story) => ({
        server: region, chapter, episode: story.id, title: name(story.title) || story.id,
      }));
      await run("offlineEnqueue", { items }, "offlineDownloadFailed");
      break;
    }
    case "open-story":
      await run("offlinePlay", args, "offlinePlayFailed");
      break;
  }
});

await refresh().catch(() => snackbar(t("offlinePlayFailed")));
if (query.has("playerError")) snackbar(t("offlinePlayFailed"));
if (selected) {
  const story = state.installed.find((row) => row.server === initialServer && row.package.id === (openEpisode || selected));
  const groupInstalled = state.installed.some((row) => row.server === initialServer && row.package.groupId === selected);
  if (story && openEpisode) {
    await run("offlinePlay", { server: initialServer, chapter: story.package.id, episode: openEpisode, locale }, "offlinePlayFailed");
  } else if (!story && (openEpisode || !groupInstalled)) {
    browser.open = true;
    await loadCatalog(providerSections[catalogSource] || catalogSource === "community" ? openEpisode || selected : undefined);
    document.getElementById("requested-chapter")?.scrollIntoView({ block: "nearest" });
  }
} else if (state.player && navigator.onLine) {
  void call("offlinePlayerUpdate").then(() => refresh()).catch(() => {});
}
