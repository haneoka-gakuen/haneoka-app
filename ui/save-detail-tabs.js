import { escape, icon, locale, number, t } from "./app.js";

export const saveTabs = [
  ["overview", "saveOverview"], ["characters", "saveCharacters"], ["friendships", "saveFriendships"],
  ["collection", "saveCollection"], ["records", "saveRecords"], ["data", "rawData"],
];

const fields = {
  _memberCards: "ownedMembers", _supportCards: "ownedSnapshots", _characters: "saveCharacters",
  _characterFriendships: "saveFriendships", _characterMissions: "saveCharacterMissions",
  _items: "currencies", _bandItems: "saveBandItems", _liveMusicResults: "songProgress",
  _challengeMusicResults: "saveChallengeResults", _events: "eventsPlayed", _gachaRecords: "recruitmentHistory",
  _decks: "saveDecks", _missionCounters: "saveMissionCounters", _exp: "saveExperience",
};
const collections = [
  "_items", "_bandItems", "_unlockedCostumes", "_currentCostumes", "_stamps", "_stampFavorites",
  "_backgrounds", "_degrees", "_playerProfileCards", "_liveLaneSkins", "_liveNoteSkins",
  "_liveNoteEffectSkins", "_liveNoteSeGroups", "_memory",
];
const records = [
  "_liveMusicResults", "_challengeMusicResults", "_topHighScoreRatings", "_liveMusics", "_challengeMusics",
  "_events", "_challengeLives", "_arenaLeagues", "_decks", "_storyEpisodeRecords", "_gachaRecords",
  "_normalMissions", "_limitedMissions", "_characterMissions", "_missionCounters",
  "_characterFriendshipRankRewards", "_playerSeasonPass", "_monthlyPass", "_receivedLoginBonuses",
  "_liveBoost", "_liveSkip", "_offlineBonus", "_exchange", "_shop", "_spots", "_vip",
];
const object = (value) => value && typeof value === "object" && !Array.isArray(value) ? value : {};
const integer = (value) => /^\d+$/.test(String(value ?? "")) ? BigInt(value) : null;
const key = (value) => {
  const id = integer(value);
  return id !== null && id > 0n ? String(id) : "";
};
const entries = (value) => Array.isArray(value)
  ? value.map((row, index) => [String(index), row])
  : Object.entries(object(value));
const indexed = (value, identity) => new Map(entries(value).flatMap(([fallback, entry]) => {
  const row = object(entry);
  const id = key(identity(row)) || (Array.isArray(value) ? "" : key(fallback));
  return id ? [[id, row]] : [];
}));
const characterId = (row) => row._masterCharacterId ?? row._characterId ?? row.characterId ?? row.character_id ?? row._masterId;
const friendshipId = (row) => row._masterCharacterFriendshipId ?? row._characterFriendshipId ?? row._friendshipId ?? row.friendshipId ?? row.friendship_id ?? row._masterId;
const missionId = (row) => row._masterMissionId ?? row._missionId ?? row.missionId ?? row.mission_id;
const fieldName = (field) => t(fields[field] ?? field);

function growth(row, thresholds) {
  const exp = integer(row?._exp ?? row?.exp ?? row?._experience);
  let level = key(row?._level ?? row?.level ?? row?._rank ?? row?.rank);
  let current = null;
  let next = null;
  if (exp !== null) {
    for (const step of thresholds ?? []) {
      const threshold = integer(step.exp);
      if (threshold === null) continue;
      if (threshold <= exp) current = step;
      else { next = threshold; break; }
    }
    level ||= key(current?.rank);
  }
  const base = current ? integer(current.exp) : null;
  const fraction = exp !== null && base !== null && next !== null && key(current.rank) === level
    ? Number((exp - base) * 1000n / (next - base)) / 10 : null;
  return { exp, level, fraction };
}

const heading = (label, glyph, count) => `<h2 class="section-title">
  <span class="section-badge">${icon(glyph)}</span><span>${escape(label)}</span>
  ${count === undefined ? "" : `<span class="badge">${number(count)}</span>`}
</h2>`;
const empty = () => `<p class="muted">${escape(t("saveNoRecords"))}</p>`;
const portrait = (url) => `<span class="save-detail-portrait">${url
  ? `<img src="${escape(url)}" alt="" loading="lazy" width="40" height="40" />` : icon("person")}</span>`;
const rank = ({ level, exp, fraction }) => `<span class="save-level">${level ? `Lv. ${escape(level)}` : "—"}
  <span>${escape(t("saveExperience"))} ${exp === null ? "—" : exp.toLocaleString(locale)}</span>
  ${fraction === null ? "" : `<span class="save-level-meter" role="progressbar" aria-label="${escape(t("saveExperience"))}"
    aria-valuenow="${fraction}"><i style="width:${fraction}%"></i></span>`}
</span>`;
const rankRow = (name, portraits, progress) => `<span class="save-detail-portraits">${portraits.map(portrait).join("")}</span>
  <span class="row__text"><span class="row__title">${escape(name)}</span>${rank(progress)}</span>`;

export function saveDetailPanels(text) {
  const state = { band: "", character: "", lead: "", partner: "", limits: new Map() };
  let rosterCache;

  function roster(player, catalog, metadata) {
    if (rosterCache?.player === player && rosterCache.catalog === catalog && rosterCache.metadata === metadata) return rosterCache;
    const saved = indexed(player._characters, characterId);
    const savedPairs = indexed(player._characterFriendships, friendshipId);
    const missionGroups = indexed(player._characterMissions, characterId);
    const pairs = object(metadata?.friendships);
    const ids = new Set([
      ...Object.entries(catalog?.characters ?? {}).filter(([, row]) => row.faceImage).map(([id]) => id),
      ...Object.values(pairs).flatMap((row) => Array.isArray(row.characterIds) ? row.characterIds.map(key).filter(Boolean) : []),
      ...saved.keys(), ...missionGroups.keys(),
    ]);
    const characters = new Map([...ids].map((id) => {
      const entry = catalog?.characters?.[id];
      return [id, { id, name: text(entry?.characterName) || `#${id}`, image: catalog?.asset(entry?.faceImage),
        band: String(entry?.bandId ?? ""), rank: growth(saved.get(id), catalog?.progression?.characterRanks) }];
    }));
    const friendships = [...new Set([...Object.keys(pairs), ...savedPairs.keys()])].map((id) => {
      const row = savedPairs.get(id);
      const ids = pairs[id]?.characterIds ?? row?.characterIds ?? [row?._masterCharacterIdA, row?._masterCharacterIdB];
      return { id, characters: Array.isArray(ids) ? ids.map((id) => characters.get(key(id))).filter(Boolean) : [],
        rank: growth(row, catalog?.progression?.friendshipRanks) };
    });
    const missions = indexed(metadata?.missions, (row) => row.missionId ?? row.id);
    rosterCache = { player, catalog, metadata, characters, friendships, missions, missionGroups };
    return rosterCache;
  }

  function renderMissions(character, model) {
    const group = model.missionGroups.get(character?.id);
    const ids = group?._receivedMissionIds ?? group?._missionIds ?? group?.missionIds ?? group?.mission_ids;
    const claimed = new Set(Array.isArray(ids) ? ids.map(key).filter(Boolean) : []);
    const progress = indexed(group?._missions ?? group?.missions ?? group?._missionProgress, missionId);
    const rows = [...new Set([...claimed, ...progress.keys()])].map((id) => {
      const row = progress.get(id), master = model.missions.get(id);
      const received = claimed.has(id) || row?._isReceived === true || row?.isReceived === true;
      const exp = integer(row?._progress ?? row?.progress ?? row?._count);
      const goal = integer(master?.achievementCount ?? row?._achievementCount);
      const completed = received || row?._isCompleted === true || row?.isCompleted === true || exp !== null && goal > 0n && exp >= goal;
      const values = { CharacterId: character.name, AchievementCount: String(goal ?? ""), Value: String(master?.value ?? "") };
      const numeric = Object.values(values);
      const description = text(master?.description).replace(/\{(\w+)\}/g, (token, name) => values[name] ?? numeric[Number(name)] ?? token);
      return { id, received, completed, exp, goal, description, title: text(master?.title) || `#${id}` };
    });
    return `<section class="surface stack">
      ${character ? `<div class="save-detail-row">${rankRow(character.name, [character.image], character.rank)}</div>` : ""}
      ${heading(t("saveCharacterMissions"), "checklist", rows.length)}
      ${rows.length ? `<div class="stats">
        <div class="stat"><div><span>${escape(t("saveCompleted"))}</span><strong>${number(rows.filter((row) => row.completed).length)}</strong></div></div>
        <div class="stat"><div><span>${escape(t("saveReceived"))}</span><strong>${number(rows.filter((row) => row.received).length)}</strong></div></div>
      </div>` : empty()}
      ${rows.map((row) => `<article class="save-mission"><div><strong>${escape(row.title)}</strong>
        ${row.completed ? `<span class="badge">${escape(t(row.received ? "saveReceived" : "saveCompleted"))}</span>` : ""}</div>
        ${row.description && row.description !== row.title ? `<span class="muted">${escape(row.description)}</span>` : ""}
        ${row.exp === null ? "" : `<span>${row.exp.toLocaleString(locale)}${row.goal === null ? "" : ` / ${row.goal.toLocaleString(locale)}`}</span>`}</article>`).join("")}
    </section>`;
  }

  function characters(model, catalog, metadata) {
    const list = [...model.characters.values()];
    const bands = [...new Set(list.map((row) => row.band))];
    const currentBand = bands.includes(state.band) ? state.band : bands[0];
    const members = list.filter((row) => row.band === currentBand);
    const selected = members.find((row) => row.id === state.character) ?? members[0];
    return `<div class="save-detail-columns">
      <section class="surface stack">${heading(t("saveCharacters"), "person", list.length)}
        ${bands.length > 1 ? `<div class="cluster">${bands.map((band) => {
          const entry = metadata?.bands?.[band], label = text(entry?.name ?? entry?.bandName) || `#${band}`;
          return `<button class="chip" type="button" data-band="${escape(band)}" aria-pressed="${band === currentBand}">
            ${catalog?.asset(entry?.icon ?? entry?.logo) ? `<img src="${escape(catalog.asset(entry.icon ?? entry.logo))}" alt="" width="20" height="20" />` : ""}
            ${escape(label)}</button>`;
        }).join("")}</div>` : ""}
        ${members.length ? members.map((row) => `<button class="row save-detail-row" type="button" data-character="${escape(row.id)}"
          aria-pressed="${row.id === selected.id}">${rankRow(row.name, [row.image], row.rank)}</button>`).join("") : empty()}
      </section>
      ${renderMissions(selected, model)}
    </div>`;
  }

  function friendships(model) {
    const picker = (side, current, list) => `<details class="fold">
      <summary><span class="grow">${escape(t(side === "lead" ? "saveFirstCharacter" : "saveSecondCharacter"))}</span>
        <span class="badge">${escape(model.characters.get(current)?.name ?? t("saveAll"))}</span>${icon("expand_more")}</summary>
      <div class="fold__body save-character-picker">
        <button type="button" class="chip" data-pair="${side}" data-value="" aria-pressed="${!current}">${escape(t("saveAll"))}</button>
        ${list.map((character) => `<button type="button" class="row save-detail-row"
          data-pair="${side}" data-value="${escape(character.id)}" aria-pressed="${current === character.id}">
          ${portrait(character.image)}<span class="row__title">${escape(character.name)}</span></button>`).join("")}
      </div>
    </details>`;
    const candidates = [...model.characters.values()];
    const involving = (pair, id) => !id || pair.characters.some((row) => row.id === id);
    const partners = new Set(model.friendships.filter((row) => involving(row, state.lead)).flatMap((row) => row.characters.map((character) => character.id)));
    const pairs = model.friendships.filter((row) => involving(row, state.lead) && involving(row, state.partner));
    return `<section class="surface stack">${heading(t("saveFriendships"), "groups", pairs.length)}
      <div class="save-pair-filters">
        ${picker("lead", state.lead, candidates)}
        ${picker("partner", state.partner, candidates.filter((row) => row.id !== state.lead && partners.has(row.id)))}
      </div>
      ${pairs.length ? `<div class="save-detail-pairs">${pairs.map((pair) => `<div class="save-detail-row">
        ${rankRow(pair.characters.length === 2 ? pair.characters.map((row) => row.name).join(" × ") : `#${pair.id}`,
          pair.characters.length ? pair.characters.map((row) => row.image) : [null], pair.rank)}</div>`).join("")}</div>` : empty()}
    </section>`;
  }

  function field(label, value, path) {
    if (value === null || typeof value !== "object") return `<div class="save-value"><span>${escape(label)}</span><code>${escape(JSON.stringify(value) ?? "")}</code></div>`;
    const count = Array.isArray(value) ? value.length : Object.keys(value).length;
    return `<details class="fold" data-save-field="${escape(path)}">
      <summary>${escape(label)}<span class="badge">${number(count)}</span>${icon("expand_more")}</summary>
      <div class="fold__body" data-save-field-body></div>
    </details>`;
  }

  function fieldsPanel(keys, player) {
    const present = keys.filter((key) => Object.hasOwn(player, key));
    return present.length ? present.map((key) => field(fieldName(key), player[key], `player/${key}`)).join("") : empty();
  }

  function render(tab, detail, catalog, metadata) {
    const player = detail.player ?? {};
    if (tab === "characters" || tab === "friendships") {
      const model = roster(player, catalog, metadata);
      return tab === "characters" ? characters(model, catalog, metadata) : friendships(model);
    }
    if (tab === "data") return [
      ["player", "savePlayerData"], ["settings", "settings"], ["persist", "latestLive"], ["permanent", "savePermanent"],
    ].filter(([key]) => detail[key] !== undefined && detail[key] !== null).map(([key, title]) => field(t(title), detail[key], key)).join("");
    return fieldsPanel(tab === "collection" ? collections : records, player);
  }

  function openField(element, detail) {
    const path = element.dataset.saveField;
    const value = path.split("/").reduce((row, key) => row?.[decodeURIComponent(key)], detail);
    const limit = state.limits.get(path) ?? 24;
    const rows = entries(Array.isArray(value) ? value.slice(0, limit) : value);
    const count = Array.isArray(value) ? value.length : rows.length;
    const body = element.querySelector(":scope > .fold__body");
    body.innerHTML = rows.length ? rows.slice(0, limit).map(([key, item]) =>
      field(Array.isArray(value) ? `#${Number(key) + 1}` : fieldName(key), item, `${path}/${encodeURIComponent(key)}`)).join("") : empty();
    if (count > limit) {
      const button = document.createElement("button");
      button.className = "button button--text";
      button.type = "button";
      button.textContent = `${t("viewAll")} (${limit} / ${count})`;
      button.addEventListener("click", () => { state.limits.set(path, limit + 24); openField(element, detail); });
      body.append(button);
    }
  }

  return { state, render, openField };
}
