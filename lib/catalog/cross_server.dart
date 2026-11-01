import '../core/api.dart';

/// The website's cross-server catalogue (`lib/cross-server`): one collection
/// across the Japanese and international releases, joined by each entity's
/// original id. The selected server's row is shown; an entity only one
/// server has carries that server's mark.
const crossCatalogIds = <String, List<String>>{
  'cards': ['cardId', 'id'],
  'support-cards': ['supportCardId', 'id'],
  'songs': ['musicId', 'songId', 'id'],
  'stories': ['storyKey', 'storyId', 'id'],
  'characters': ['characterId', 'id'],
  'comics': ['comicId', 'id'],
  'stamps': ['stampId', 'id'],
  'stickers': ['stickerId', 'id'],
  'backgrounds': ['backgroundId', 'id'],
  'band-items': ['bandItemId', 'itemId', 'id'],
  'items': ['itemId', 'id'],
  'events': ['id'],
  'real-lives': ['id'],
  'gacha': ['id'],
  'login-campaigns': ['id'],
  'shop': ['id'],
  'exchange': ['id'],
  'passes': ['id'],
  'missions': ['id'],
  'tgw-card': ['id'],
  'live2d': ['live2dKey', 'id'],
  'spine': ['id'],
};
const _opaque = {
  'real-lives',
  'passes',
  'missions',
  'stories',
  'live2d',
  'spine',
};
const _nameFields = [
  'prefix',
  'cardName',
  'musicTitle',
  'characterName',
  'bandName',
  'title',
  'name',
];
const _editorialFields = [
  'englishName',
  'nickname',
  'voiceActor',
  'description',
  'catchCopy',
  'height',
  'constellation',
  'school',
  'schoolClass',
  'favoriteFood',
  'hatedFood',
  'hobby',
  'diary',
  'composer',
  'lyricist',
  'arranger',
  'artistName',
];

/// The servers a merged row lives on; set on every row as `_servers`.
const serversKey = '_servers';

/// The server whose row is shown, when it is not the selected one.
const serverKey = '_server';

bool _text(Object? value) => value is String && value.trim().isNotEmpty;

/// The original id that joins the same entity across servers
/// (`entitySignature`), or null when the row cannot be joined.
String? _signature(String resource, Map row, String id) {
  if (_opaque.contains(resource)) {
    if (id.isEmpty ||
        id.length > 256 ||
        RegExp(r'[\\/\x00-\x1f\x7f]').hasMatch(id) ||
        id == '.' ||
        id == '..') {
      return null;
    }
  } else if (!RegExp(r'^[1-9]\d*$').hasMatch(id)) {
    return null;
  }
  if (resource == 'events' && row['kind'] != 'game-event') return null;
  return id;
}

/// Fills the shown row's empty locale slots from the other server: names
/// always, editorial text only when both carry the same Japanese edition.
Map<String, Object?> displayCrossServerRow(Map row, Map? peer) {
  final out = Map<String, Object?>.of(row.cast<String, Object?>());
  if (peer == null) return out;
  void fill(String field) {
    final own = row[field], other = peer[field];
    if (own is! List || other is! List) return;
    final slots = [...own];
    var changed = false;
    for (var slot = 0; slot < other.length && slot < 5; slot++) {
      if (slot < slots.length && _text(slots[slot])) continue;
      if (!_text(other[slot])) continue;
      while (slots.length <= slot) {
        slots.add('');
      }
      slots[slot] = other[slot];
      changed = true;
    }
    if (changed) out[field] = slots;
  }

  for (final field in _nameFields) {
    fill(field);
  }
  for (final field in _editorialFields) {
    final own = row[field], other = peer[field];
    if (own is List &&
        other is List &&
        own.isNotEmpty &&
        other.isNotEmpty &&
        _text(own.first) &&
        own.first == other.first) {
      fill(field);
    }
  }
  return out;
}

/// Reads a collection's rows keyed by id (`crossCatalogRows`).
Map<String, Map> crossCatalogRows(
  String resource,
  Object? document,
  String? rowsPath,
) {
  Object? rows = document;
  if (rowsPath != null) {
    for (final part in rowsPath.split('.')) {
      rows = rows is Map ? rows[part] : null;
    }
  }
  final ids = crossCatalogIds[resource] ?? const ['id'];
  final result = <String, Map>{};
  if (rows is Map) {
    for (final MapEntry(:key, :value) in rows.entries) {
      if (value is Map) result['$key'] = value;
    }
  } else if (rows is List) {
    for (final (index, value) in rows.indexed) {
      if (value is! Map) continue;
      final id = ids
          .map((field) => value[field])
          .firstWhere((v) => v != null, orElse: () => index);
      result['$id'] = value;
    }
  }
  return result;
}

/// One collection merged across [servers] (`mergeCrossServerCatalog`).
/// [selected] is the reading server; rows from the other server keep their
/// own `/assets/<server>/` media and gain `_server`.
Future<List<Map<String, Object?>>> crossServerCollection({
  required String resource,
  required String selected,
  required Map<String, HaneokaApi> apis,
  required String? rowsPath,
  Map<String, Object?>? sourceDocuments,
}) async {
  final servers = const {'jp', 'intl'}.contains(selected)
      ? ['jp', 'intl'].where(apis.containsKey).toList()
      : apis.keys.toList();
  final documents = sourceDocuments == null
      ? await Future.wait([
          for (final server in servers)
            apis[server]!
                .catalog(resource)
                .then<Object?>((v) => v, onError: (_) => null),
        ])
      : [for (final server in servers) sourceDocuments[server]];
  if (documents.isNotEmpty && documents.every((d) => d == null)) {
    throw StateError('catalog_unavailable');
  }
  final loaded = <String, Map<String, Map>>{
    for (final (index, server) in servers.indexed)
      if (documents[index] != null)
        server: crossCatalogRows(resource, documents[index], rowsPath),
  };
  final complete = loaded.length == servers.length && servers.length > 1;
  // Buckets in source order: each server's rows, by signature.
  final buckets = <String, Map<String, List<(String, Map)>>>{};
  for (final server in servers) {
    for (final MapEntry(key: id, value: row)
        in (loaded[server] ?? const {}).entries) {
      final sig = _signature(resource, row, id);
      final key = sig ?? 'independent:$server:$id';
      ((buckets[key] ??= {})[server] ??= []).add((id, row));
    }
  }
  final out = <Map<String, Object?>>[];
  void add(Map<String, (String, Map)> variants, bool joinable) {
    final display = variants[selected] ?? variants.values.first;
    final displayServer = variants.containsKey(selected)
        ? selected
        : variants.keys.first;
    final peer = variants.entries
        .where((e) => e.key != displayServer)
        .map((e) => e.value.$2)
        .firstOrNull;
    final row = displayCrossServerRow(display.$2, peer);
    row[serversKey] = (complete && joinable)
        ? variants.keys.toList()
        : const <String>[];
    if (displayServer != selected) row[serverKey] = displayServer;
    out.add(row);
  }

  for (final MapEntry(:key, value: bucket) in buckets.entries) {
    final joinable = !key.startsWith('independent:');
    if (joinable && bucket.values.every((list) => list.length <= 1)) {
      add({
        for (final MapEntry(key: server, value: list) in bucket.entries)
          server: list.single,
      }, true);
    } else {
      for (final MapEntry(key: server, value: list) in bucket.entries) {
        for (final variant in list) {
          add({server: variant}, false);
        }
      }
    }
  }
  return out;
}

/// The server only this row's entity is on, when the catalogue knows both
/// (`exclusiveCatalogServer`).
String? exclusiveServer(Map row) {
  final servers = row[serversKey];
  if (servers is! List || servers.isEmpty) return null;
  final jp = servers.contains('jp'), intl = servers.contains('intl');
  if (jp && intl) return null;
  return jp ? 'jp' : (intl ? 'intl' : null);
}

/// The tile emblem of an entity only one server has (`catalogServerMark`).
(String, String)? serverMark(
  Map row,
  String Function(String key, String fallback) text,
) => switch (exclusiveServer(row)) {
  'jp' => (
    'assets/settings/bushimo-circle.svg',
    text('catalog.availability.catalogJapanOnly', 'Japan only'),
  ),
  'intl' => (
    'assets/settings/bilibili-circle.svg',
    text('catalog.availability.catalogInternationalOnly', 'Global only'),
  ),
  _ => null,
};
