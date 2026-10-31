/// Card data import as the website reads it (`@haneoka/game-data-exporter`
/// parser and profile projection, `team-builder/box-import/*`,
/// `data/list-import.ts`, `box-review-model.ts`): game saves, exported
/// packages, inventory documents and card lists become one candidate, its
/// values are checked against this release's ranges, and only the entries
/// and values the reader confirms are written to the box.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../save/codec.dart';
import 'box.dart';
import 'engine/master.dart';
import 'engine/num.dart';
import 'engine/power.dart';

import 'package:game_data_exporter/game_data_exporter.dart' as exporter;

class BoxImportError implements Exception {
  const BoxImportError(this.code);
  final String code;
  @override
  String toString() => code;
}

/// `BOX_LIMITS`.
abstract final class BoxLimits {
  static const inputBytes = 32 * 1024 * 1024;
  static const fileBytes = 16 * 1024 * 1024;
  static const expandedBytes = 64 * 1024 * 1024;
  static const entries = 512;
  static const candidates = 16;
  static const rowsPerList = 5000;
  static const textBytes = 16 * 1024 * 1024;
}

final _decimal = RegExp(r'^(0|[1-9]\d{0,18})$');

/// A non-negative integer from a number or a decimal string.
int? boxInteger(Object? value) {
  if (value is int) return value >= 0 ? value : null;
  if (value is double) {
    return value >= 0 && value == value.truncateToDouble() && value < 9e15
        ? value.toInt()
        : null;
  }
  if (value is! String || !_decimal.hasMatch(value)) return null;
  return int.tryParse(value);
}

/// Experience stays a decimal string so 64-bit values survive.
String? boxDecimal(Object? value) {
  final text = value is int
      ? '$value'
      : value is double && value == value.truncateToDouble()
      ? value.toStringAsFixed(0)
      : value;
  if (text is! String || !_decimal.hasMatch(text)) return null;
  final parsed = BigInt.parse(text);
  return parsed <= BigInt.parse('9223372036854775807') ? text : null;
}

class BoxMember {
  BoxMember(
    this.cardId, {
    this.exp,
    this.level,
    this.awakeCount,
    this.rank,
    this.liveSkillLevel,
    this.performanceSkillLevel,
  });
  final int cardId;
  final String? exp;
  final int? level;
  final int? awakeCount;
  final int? rank;
  final int? liveSkillLevel;
  final int? performanceSkillLevel;
}

class BoxSnap {
  BoxSnap(this.cardId, {this.exp, this.level, this.rank});
  final int cardId;
  final String? exp;
  final int? level;
  final int? rank;
}

class BoxCandidate {
  BoxCandidate({required this.id, required this.format, this.declaredServer});
  final String id;
  final String format;
  final List<BoxMember> members = [];
  final List<BoxSnap> snaps = [];

  /// (character id, exp, rank).
  final List<(int, String?, int?)> characters = [];

  /// (band item id, level).
  final List<(int, int?)> bandItems = [];
  int? vipRank;
  final List<BoxImportNotice> notices = [];

  /// Formal-server records are copied into the reviewed target library.
  String? declaredServer;
}

int _nextCandidate = 0;
String _candidateId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${_nextCandidate++}';

Object? _object(Object? value) => value is Map ? value : null;
List<Object?> _list(Object? value) {
  if (value is! List) return const [];
  if (value.length > BoxLimits.rowsPerList) {
    throw const BoxImportError('box_row_budget');
  }
  return value;
}

int? _cardId(Object? value) {
  final id = boxInteger(value);
  return id != null && id > 0 && id <= 0x7fffffff ? id : null;
}

/// `projectInventoryDocument`: Haneoka inventory documents and the
/// reference profile; never account envelopes.
BoxCandidate? _projectInventory(Map root) {
  final exporter.InventoryCandidate? thirdParty;
  try {
    thirdParty = exporter.projectThirdPartyInventory(root);
  } on exporter.InventoryImportError catch (error) {
    throw BoxImportError(error.code);
  }
  if (thirdParty != null) {
    final candidate = BoxCandidate(
      id: _candidateId(),
      format: 'inventory-json',
      declaredServer: thirdParty.declaredServer,
    )..vipRank = thirdParty.vipRank;
    candidate.members.addAll([
      for (final row in thirdParty.members)
        BoxMember(
          row.cardId,
          level: row.level,
          rank: row.rank,
          awakeCount: row.awakeCount,
          liveSkillLevel: row.liveSkillLevel,
          performanceSkillLevel: row.performanceSkillLevel,
        ),
    ]);
    candidate.snaps.addAll([
      for (final row in thirdParty.snapshots)
        BoxSnap(row.cardId, level: row.level, rank: row.rank),
    ]);
    candidate.characters.addAll([
      for (final (id, rank) in thirdParty.characters) (id, null, rank),
    ]);
    candidate.bandItems.addAll(thirdParty.bandItems);
    candidate.notices.addAll([
      for (final row in thirdParty.notices) BoxImportNotice(row.code, row.path),
    ]);
    return candidate;
  }
  final legacy = _object(root['profile']) as Map? ?? root;
  final inventory = _object(legacy['inventory']) as Map?;
  final canonical =
      root['schema'] == 'haneoka-team-inventory-v1' ||
      root['schema'] == 'haneoka-team-inventory-v2';
  final reference =
      boxInteger(legacy['schema_version']) == 1 &&
      inventory != null &&
      inventory['members'] is List &&
      inventory['snaps'] is List;
  if (!canonical && !reference) return null;
  List<Object?> rows(Object? value) {
    if (value is! List) throw const BoxImportError('box_invalid_json');
    if (value.length > BoxLimits.rowsPerList) {
      throw const BoxImportError('box_row_budget');
    }
    return value;
  }

  int? supplied(Object? value) {
    if (value == null) return null;
    final n = boxInteger(value);
    if (n == null) throw const BoxImportError('box_invalid_json');
    return n;
  }

  int? countToNative(Object? value) {
    final count = supplied(value);
    return count == null ? null : count + 1;
  }

  String? server;
  if (canonical) {
    final value = root['server'];
    if (value is! String ||
        value.length > 64 ||
        !RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(value)) {
      throw const BoxImportError('box_invalid_json');
    }
    server = value;
  }
  final candidate = BoxCandidate(
    id: _candidateId(),
    format: canonical ? 'inventory-json' : 'reference-profile',
    declaredServer: server,
  );
  for (final raw in rows(canonical ? root['members'] : inventory!['members'])) {
    if (raw is! Map) throw const BoxImportError('box_invalid_json');
    final id = _cardId(canonical ? raw['cardId'] : raw['id']);
    if (id == null) throw const BoxImportError('box_invalid_json');
    candidate.members.add(
      BoxMember(
        id,
        level: supplied(raw['level']),
        awakeCount: canonical
            ? supplied(raw['training'])
            : countToNative(raw['training_count']),
        rank: canonical
            ? supplied(raw['awakening'])
            : countToNative(raw['awakening_count']),
        liveSkillLevel: supplied(
          canonical ? raw['liveSkillLevel'] : raw['live_skill_level'],
        ),
        performanceSkillLevel: supplied(
          canonical ? raw['gekisoSkillLevel'] : raw['gekisou_skill_level'],
        ),
      ),
    );
  }
  for (final raw in rows(canonical ? root['snapshots'] : inventory!['snaps'])) {
    if (raw is! Map) throw const BoxImportError('box_invalid_json');
    final id = _cardId(canonical ? raw['cardId'] : raw['id']);
    if (id == null) throw const BoxImportError('box_invalid_json');
    candidate.snaps.add(
      BoxSnap(
        id,
        level: supplied(raw['level']),
        rank: canonical
            ? supplied(raw['awakening'])
            : countToNative(raw['limit_break_count']),
      ),
    );
  }
  if (canonical) {
    for (final key in const ['bandItems', 'characterRanks']) {
      final map = root[key];
      if (map is! Map || map.length > BoxLimits.rowsPerList) {
        throw const BoxImportError('box_invalid_json');
      }
      for (final MapEntry(key: rawId, :value) in map.entries) {
        final entity = _cardId('$rawId');
        if (entity == null) throw const BoxImportError('box_invalid_json');
        if (key == 'bandItems') {
          candidate.bandItems.add((entity, supplied(value)));
        } else {
          candidate.characters.add((entity, null, supplied(value)));
        }
      }
    }
  } else {
    for (final raw in rows(legacy['facilities'] ?? const [])) {
      final entity = raw is Map ? _cardId(raw['id']) : null;
      if (entity == null) throw const BoxImportError('box_invalid_json');
      candidate.bandItems.add((entity, supplied((raw as Map)['level'])));
    }
    for (final raw in rows(legacy['character_ranks'] ?? const [])) {
      final entity = raw is Map ? _cardId(raw['character_id']) : null;
      if (entity == null) throw const BoxImportError('box_invalid_json');
      candidate.characters.add((entity, null, supplied((raw as Map)['rank'])));
    }
  }
  return candidate;
}

/// `project`: a decrypted save, an exported save, a compact package or an
/// inventory document. Names, account ids and tokens never cross it.
BoxCandidate? projectBox(Object? value, String format) {
  if (value is! Map) return null;
  final compatible = _projectInventory(value);
  if (compatible != null) return compatible;
  final compact =
      boxInteger(value['v']) == 1 && (value['m'] is List || value['s'] is List);
  final player = compact
      ? value
      : _object(value['_player']) as Map? ??
            _object(value['player']) as Map? ??
            value;
  if (!compact &&
      player['_memberCards'] is! List &&
      player['_supportCards'] is! List) {
    return null;
  }
  final candidate = BoxCandidate(
    id: _candidateId(),
    format: compact ? 'onpkg1' : format,
  );
  Map? row(Object? value, List<String> fields) {
    if (compact && value is List) {
      return {
        for (var i = 0; i < fields.length; i++)
          fields[i]: i < value.length ? value[i] : null,
      };
    }
    return value is Map ? value : null;
  }

  for (final value in _list(compact ? player['m'] : player['_memberCards'])) {
    final r = row(value, const [
      '_masterId',
      '_exp',
      '_awakeCount',
      '_rank',
      '_liveSkillLevel',
      '_performanceSkillLevel',
    ]);
    final id = r == null ? null : _cardId(r['_masterId']);
    if (id == null) continue;
    candidate.members.add(
      BoxMember(
        id,
        exp: boxDecimal(r!['_exp']),
        awakeCount: boxInteger(r['_awakeCount']),
        rank: boxInteger(r['_rank']),
        liveSkillLevel: boxInteger(r['_liveSkillLevel']),
        performanceSkillLevel: boxInteger(r['_performanceSkillLevel']),
      ),
    );
  }
  for (final value in _list(compact ? player['s'] : player['_supportCards'])) {
    final r = row(value, const ['_masterId', '_exp', '_rank']);
    final id = r == null ? null : _cardId(r['_masterId']);
    if (id == null) continue;
    candidate.snaps.add(
      BoxSnap(id, exp: boxDecimal(r!['_exp']), rank: boxInteger(r['_rank'])),
    );
  }
  for (final value in _list(compact ? player['c'] : player['_characters'])) {
    final r = row(value, const ['_masterId', '_exp']);
    final id = r == null ? null : _cardId(r['_masterId']);
    if (id != null) {
      candidate.characters.add((id, boxDecimal(r!['_exp']), null));
    }
  }
  for (final value in _list(compact ? player['b'] : player['_bandItems'])) {
    final r = row(value, const ['_masterId', '_level']);
    final id = r == null ? null : _cardId(r['_masterId'] ?? r['_id']);
    if (id != null) candidate.bandItems.add((id, boxInteger(r!['_level'])));
  }
  return candidate;
}

Object? _json(String text) {
  if (text.length > BoxLimits.textBytes) {
    throw const BoxImportError('box_text_budget');
  }
  try {
    return jsonDecode(text);
  } on FormatException {
    throw const BoxImportError('box_invalid_json');
  }
}

String _utf8(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw const BoxImportError('box_invalid_utf8');
  }
}

List<int> _gunzip(List<int> bytes) {
  try {
    final plain = GZipDecoder().decodeBytes(bytes);
    if (plain.length > BoxLimits.textBytes) {
      throw const BoxImportError('box_text_budget');
    }
    return plain;
  } on BoxImportError {
    rethrow;
  } catch (_) {
    throw const BoxImportError('box_invalid_gzip');
  }
}

/// `parseBoxText`: pasted `ONPKG1:` text or JSON.
List<BoxCandidate> parseBoxText(String text) {
  if (text.length > BoxLimits.textBytes) {
    throw const BoxImportError('box_text_budget');
  }
  var decoded = text.trim();
  if (decoded.startsWith('ONPKG1:')) {
    final encoded = decoded.substring(7).replaceAll(RegExp(r'\s'), '');
    if (encoded.length > BoxLimits.inputBytes * 4 / 3 ||
        !RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(encoded)) {
      throw const BoxImportError('box_invalid_onpkg');
    }
    final List<int> raw;
    try {
      raw = base64.decode(encoded);
    } on FormatException {
      throw const BoxImportError('box_invalid_onpkg');
    }
    decoded = _utf8(_gunzip(raw));
  }
  final candidate = projectBox(_json(decoded), 'player-json');
  if (candidate == null) throw const BoxImportError('box_no_player');
  return [candidate];
}

BoxCandidate? _parseBytes(Uint8List data) {
  if (SaveCodec.looksLikeSave(data)) {
    final plain = SaveCodec.decode(data);
    if (plain == null) throw const BoxImportError('box_invalid_encryption');
    return projectBox(plain, 'encrypted-player');
  }
  if (data.length > 1 && data[0] == 0x1f && data[1] == 0x8b) {
    return projectBox(_json(_utf8(_gunzip(data))), 'player-json');
  }
  final prefix = utf8
      .decode(
        data.sublist(0, data.length < 64 ? data.length : 64),
        allowMalformed: true,
      )
      .trimLeft();
  if (prefix.startsWith('ONPKG1:')) return parseBoxText(_utf8(data)).first;
  if (!prefix.startsWith('{')) return null;
  return projectBox(_json(_utf8(data)), 'player-json');
}

/// `parseBoxFiles`: saves, exports and zip archives of them. Other files
/// are ignored, never run.
List<BoxCandidate> parseBoxFiles(List<Uint8List> files) {
  if (files.isEmpty ||
      files.length > BoxLimits.entries ||
      files.fold<int>(0, (n, f) => n + f.length) > BoxLimits.inputBytes) {
    throw const BoxImportError('box_input_budget');
  }
  final candidates = <BoxCandidate>[];
  final seen = <String>{};
  var expanded = 0;
  void accept(Uint8List data) {
    if (!seen.add(sha256.convert(data).toString())) return;
    final candidate = _parseBytes(data);
    if (candidate == null) return;
    if (candidates.length >= BoxLimits.candidates) {
      throw const BoxImportError('box_candidate_budget');
    }
    candidates.add(candidate);
  }

  for (final bytes in files) {
    if (bytes.length > 1 && bytes[0] == 0x50 && bytes[1] == 0x4b) {
      final Archive archive;
      try {
        archive = ZipDecoder().decodeBytes(bytes);
      } catch (_) {
        throw const BoxImportError('box_invalid_zip');
      }
      for (final entry in archive.files) {
        if (!entry.isFile) continue;
        expanded += entry.size;
        if (expanded > BoxLimits.expandedBytes) {
          throw const BoxImportError('box_expanded_budget');
        }
        accept(Uint8List.fromList(entry.content));
      }
    } else {
      if (bytes.length > BoxLimits.fileBytes) {
        throw const BoxImportError('box_file_budget');
      }
      accept(bytes);
    }
  }
  if (candidates.isEmpty) throw const BoxImportError('box_no_player');
  return candidates;
}

/// Box fields in the website's names, and their box keys.
const memberFields = [
  'level',
  'training',
  'awakening',
  'liveSkillLevel',
  'gekisoSkillLevel',
];
const snapFields = ['level', 'awakening'];
const _boxField = {
  'level': 'lvl',
  'training': 'awk',
  'awakening': 'rnk',
  'liveSkillLevel': 'sk',
  'gekisoSkillLevel': 'gsk',
};

int? ownedValue(Object? owned, String field) => switch ((owned, field)) {
  (OwnedMember m, 'level') => m.level,
  (OwnedMember m, 'training') => m.awake,
  (OwnedMember m, 'awakening') => m.rank,
  (OwnedMember m, 'liveSkillLevel') => m.skill,
  (OwnedMember m, 'gekisoSkillLevel') => m.gekisoSkill,
  (OwnedSnap s, 'level') => s.level,
  (OwnedSnap s, 'awakening') => s.rank,
  _ => null,
};

List<int> _sortedKeys(Map<int, Object?>? map) =>
    (map?.keys.toList() ?? <int>[])..sort();

/// `practiceRanges`: every value this release allows for a card's fields;
/// a known training or awakening caps the level.
Map<String, List<int>> practiceRanges(
  EngineMaster master,
  bool members,
  int cardId, {
  int? training,
  int? awakening,
}) {
  if (members) {
    final card = master.members[cardId];
    if (card == null) return const {};
    List<int> skill(List<SkillEffectRow>? rows) =>
        ({for (final row in rows ?? const <SkillEffectRow>[]) row.level}
            .toList()
          ..sort());
    var levels = _sortedKeys(master.memberLevels[card.levelGroup]);
    if (training != null) {
      final cap = memberLevelCap(master, card, training);
      levels = [
        for (final l in levels)
          if (l <= cap) l,
      ];
    }
    return {
      'awakening': _sortedKeys(master.memberRanks[card.rankGroup]),
      'level': levels,
      'training': _sortedKeys(master.memberAwake[card.awakeGroup]),
      'liveSkillLevel': card.liveSkillId > 0
          ? skill(master.liveSkills[card.liveSkillId])
          : const [],
      'gekisoSkillLevel': card.gekisoSkillId > 0
          ? skill(master.gekisoSkills[card.gekisoSkillId]?.effects)
          : const [],
    };
  }
  final card = master.snaps[cardId];
  if (card == null) return const {};
  var levels = _sortedKeys(master.snapLevels[card.levelGroup]);
  final cap = awakening == null
      ? null
      : master.snapRanks[card.rankGroup]?[awakening]?.limitLevel;
  if (cap != null && cap > 0) {
    levels = [
      for (final l in levels)
        if (l <= cap) l,
    ];
  }
  return {
    'awakening': _sortedKeys(master.snapRanks[card.rankGroup]),
    'level': levels,
  };
}

/// Levels every band item's level table allows, with 0 for not built.
List<int> bandItemLevels(Doc data, int id) {
  final item = objectRow(objectRow(data['bandItems'])['$id']);
  if (item.isEmpty) return const [];
  return ({
    0,
    for (final entry in dataRows(item['levels']))
      intOf(nativeRow(entry)['level']),
  }.toList()..sort());
}

class BoxCardProposal {
  BoxCardProposal(this.key, this.members, this.cardId, this.owned);
  final String key;
  final bool members;
  final int cardId;

  /// The card already in the box, or null.
  final Object? owned;
  final Map<String, List<int>> values = {};
  int? existing(String field) => ownedValue(owned, field);
  List<String> get fields => members ? memberFields : snapFields;
}

sealed class BoxAccountProposal {
  BoxAccountProposal(this.key, this.exists, this.existing);
  final String key;
  final bool exists;
  final int? existing;
  final List<int> values = [];
  String get boxKey;
}

class BoxMapProposal extends BoxAccountProposal {
  BoxMapProposal(
    super.key,
    this.characters,
    this.id,
    super.exists,
    super.existing,
  );

  /// Character ranks, or band item levels.
  final bool characters;
  final int id;
  @override
  String get boxKey => '${characters ? 'cr' : 'bi'}.$id';
}

class BoxScalarProposal extends BoxAccountProposal {
  BoxScalarProposal(super.key, super.exists, super.existing, this.blocked);
  final bool blocked;
  @override
  String get boxKey => 'p.vip';
}

class BoxImportNotice {
  const BoxImportNotice(this.code, this.path);
  final String code;
  final String path;
}

/// `kind` is `members`, `snapshots`, `bandItems`, `characterRanks` or
/// `input` (a list row); `id` is the card, entity or row number.
class BoxIssue {
  const BoxIssue(this.kind, this.id, this.field, this.code);
  final String kind;
  final int id;
  final String field;
  final String code;
}

class BoxPreview {
  BoxPreview(
    this.server,
    this.original,
    this.cards,
    this.maps,
    this.issues, {
    this.scalars = const [],
    this.notices = const [],
  });
  final String server;

  /// The box this preview was read against; a changed box reopens it.
  final String original;
  final List<BoxCardProposal> cards;
  final List<BoxMapProposal> maps;
  final List<BoxIssue> issues;
  final List<BoxScalarProposal> scalars;
  final List<BoxImportNotice> notices;
  Iterable<BoxAccountProposal> get accounts sync* {
    yield* maps;
    yield* scalars;
  }

  bool blocked(BoxCardProposal card) => issues.any(
    (i) =>
        i.kind == (card.members ? 'members' : 'snapshots') &&
        i.id == card.cardId,
  );
  bool mapBlocked(BoxMapProposal map) => issues.any(
    (i) =>
        i.kind == (map.characters ? 'characterRanks' : 'bandItems') &&
        i.id == map.id,
  );
  bool accountBlocked(BoxAccountProposal account) => switch (account) {
    BoxMapProposal() => mapBlocked(account),
    BoxScalarProposal() => account.blocked,
  };
}

/// What the import may change of the box, as one comparable string.
String boxSignature(BoxView view) => jsonEncode([
  for (final row in view.members.values)
    [row.cardId, row.level, row.awake, row.rank, row.skill, row.gekisoSkill],
  for (final row in view.snaps.values) [row.cardId, row.level, row.rank],
  view.player.characterRanks,
  view.player.bandItems,
  view.player.vipRank,
]);

/// The highest value whose experience threshold the save's experience reaches.
int? _fromExp(List<Doc> rows, String? exp, int? group, String key) {
  if (exp == null) return null;
  final have = BigInt.parse(exp);
  int? best;
  for (final raw in rows) {
    final row = nativeRow(raw);
    final threshold = boxDecimal(row['exp']);
    final value = boxInteger(row[key]);
    if ((group != null && intOf(row['group']) != group) ||
        threshold == null ||
        value == null) {
      continue;
    }
    if (BigInt.parse(threshold) <= have && (best == null || value > best)) {
      best = value;
    }
  }
  return best;
}

/// `previewBoxImport`.
BoxPreview previewBoxImport(
  BoxCandidate candidate,
  BoxView view,
  EngineMaster master,
  Doc data,
  String server,
) {
  final copying =
      candidate.declaredServer != null && candidate.declaredServer != server;
  if (copying &&
      ![
        candidate.declaredServer,
        server,
      ].every((source) => source == 'jp' || source == 'intl')) {
    throw const BoxImportError('box_incompatible_server');
  }
  final cross = objectRow(data['crossServer']);
  bool inTarget(String collection, int id) =>
      cross.isEmpty ||
      (objectRow(objectRow(cross['availability'])[collection])['$id']
                  as List? ??
              const [])
          .contains(server);
  final progression = objectRow(data['progression']);
  final issues = <BoxIssue>[];
  final cards = <String, BoxCardProposal>{};
  final maps = <String, BoxMapProposal>{};
  void card(
    bool members,
    int cardId,
    Map<String, int?> Function(int levelGroup) raw,
  ) {
    final kind = members ? 'members' : 'snapshots';
    final levelGroup = members
        ? master.members[cardId]?.levelGroup
        : master.snaps[cardId]?.levelGroup;
    if (copying && (levelGroup == null || !inTarget(kind, cardId))) {
      issues.add(BoxIssue(kind, cardId, 'cardId', 'unavailable_target_card'));
      return;
    }
    if (levelGroup == null) {
      issues.add(BoxIssue(kind, cardId, 'cardId', 'unknown_current_card'));
      return;
    }
    final values = raw(levelGroup);
    final allowed = practiceRanges(
      master,
      members,
      cardId,
      training: values['training'],
      awakening: values['awakening'],
    );
    final key = '$server:$kind:$cardId';
    final proposal = cards[key] ??= BoxCardProposal(
      key,
      members,
      cardId,
      members ? view.members[cardId] : view.snaps[cardId],
    );
    for (final MapEntry(key: field, :value) in values.entries) {
      if (value == null) continue;
      final range = allowed[field] ?? const [];
      if (!range.contains(value)) {
        issues.add(
          BoxIssue(
            kind,
            cardId,
            field,
            range.isNotEmpty
                ? 'out_of_current_range'
                : 'current_domain_unavailable',
          ),
        );
        continue;
      }
      final list = proposal.values[field] ??= [];
      if (!list.contains(value)) {
        list
          ..add(value)
          ..sort();
      }
    }
  }

  for (final source in candidate.members) {
    card(
      true,
      source.cardId,
      (group) => {
        'awakening': source.rank,
        'level':
            source.level ??
            _fromExp(
              dataRows(progression['memberCardLevels']),
              source.exp,
              group,
              'level',
            ),
        'training': source.awakeCount,
        'liveSkillLevel': source.liveSkillLevel,
        'gekisoSkillLevel': source.performanceSkillLevel,
      },
    );
  }
  for (final source in candidate.snaps) {
    card(
      false,
      source.cardId,
      (group) => {
        'awakening': source.rank,
        'level':
            source.level ??
            _fromExp(
              dataRows(progression['supportCardLevels']),
              source.exp,
              group,
              'level',
            ),
      },
    );
  }
  final ranks = [
    for (final row in dataRows(progression['characterRanks']))
      intOf(nativeRow(row)['rank']),
  ];
  void map(bool characters, int id, int? value) {
    final kind = characters ? 'characterRanks' : 'bandItems';
    final known = characters
        ? master.characters.containsKey(id)
        : objectRow(objectRow(data['bandItems'])['$id']).isNotEmpty;
    if (copying &&
        (!known || !inTarget(characters ? 'characters' : 'bandItems', id))) {
      issues.add(BoxIssue(kind, id, 'id', 'unavailable_target_entity'));
      return;
    }
    if (!known) {
      issues.add(BoxIssue(kind, id, 'id', 'unknown_current_entity'));
      return;
    }
    if (value == null) return;
    final allowed = characters ? ranks : bandItemLevels(data, id);
    if (!allowed.contains(value)) {
      issues.add(BoxIssue(kind, id, 'level', 'out_of_current_range'));
      return;
    }
    final current = characters
        ? view.player.characterRanks
        : view.player.bandItems;
    final proposal = maps['$kind:$id'] ??= BoxMapProposal(
      '$kind:$id',
      characters,
      id,
      current.containsKey('$id'),
      current['$id'],
    );
    if (!proposal.values.contains(value)) proposal.values.add(value);
  }

  for (final (id, level) in candidate.bandItems) {
    map(false, id, level);
  }
  for (final (id, exp, rank) in candidate.characters) {
    map(
      true,
      id,
      rank ??
          _fromExp(dataRows(progression['characterRanks']), exp, null, 'rank'),
    );
  }
  final runtime = objectRow(data['runtimeRules']);
  final vipTable = objectRow(objectRow(runtime['tables'])['vipRanks']);
  final vipRanks = runtime['status'] == 'ready' && vipTable['status'] == 'ready'
      ? {
          for (final row in dataRows(vipTable['rows']))
            ?boxInteger(nativeRow(row)['vipRank']),
        }
      : const <int>{};
  return BoxPreview(
    server,
    boxSignature(view),
    cards.values.toList(),
    maps.values.toList(),
    issues,
    scalars: candidate.vipRank == null
        ? const []
        : [
            BoxScalarProposal(
              'vipRank',
              true,
              view.player.vipRank,
              !vipRanks.contains(candidate.vipRank),
            )..values.add(candidate.vipRank!),
          ],
    notices: candidate.notices,
  );
}

const _listHeaders = {
  'kind': 'kind',
  'id': 'id',
  'cardid': 'id',
  'name': 'name',
  'level': 'level',
  'training': 'training',
  'awake': 'training',
  'awakecount': 'training',
  'awakening': 'awakening',
  'rank': 'awakening',
  'liveskilllevel': 'liveSkillLevel',
  'skilllevel': 'liveSkillLevel',
  'gekisoskilllevel': 'gekisoSkillLevel',
  'gekisouskilllevel': 'gekisoSkillLevel',
};
const _listKinds = {
  'member': true,
  'members': true,
  'support': false,
  'snapshot': false,
  'snapshots': false,
};

/// `parseInventoryList`: CSV or TSV; quoted names may hold separators and
/// newlines.
List<List<String>> parseInventoryList(String text) {
  if (utf8.encode(text).length > 1024 * 1024) {
    throw RangeError('inventory-list-byte-limit');
  }
  text = text.replaceFirst(RegExp('^﻿'), '').replaceAll(RegExp('\r\n?'), '\n');
  var delimiter = ',';
  var inQuote = false;
  for (final char in text.split('')) {
    if (char == '"') inQuote = !inQuote;
    if (!inQuote && char == '\t') {
      delimiter = '\t';
      break;
    }
    if (!inQuote && char == '\n') break;
  }
  final rows = <List<String>>[];
  var row = <String>[];
  var cell = StringBuffer();
  var quoted = false, closed = false;
  void pushCell() {
    row.add(cell.toString().trim());
    cell = StringBuffer();
    closed = false;
  }

  void pushRow() {
    pushCell();
    if (row.any((value) => value.isNotEmpty)) rows.add(row);
    row = [];
    if (rows.length > 5001) throw RangeError('inventory-list-row-limit');
  }

  for (var index = 0; index < text.length; index++) {
    final char = text[index];
    if (quoted) {
      if (char != '"') {
        cell.write(char);
      } else if (index + 1 < text.length && text[index + 1] == '"') {
        cell.write('"');
        index++;
      } else {
        quoted = false;
        closed = true;
      }
    } else if (char == delimiter) {
      pushCell();
    } else if (char == '\n') {
      pushRow();
    } else if (char == '"') {
      if (cell.toString().trim().isNotEmpty || closed) {
        throw const FormatException('inventory-list-invalid-quote');
      }
      cell = StringBuffer();
      quoted = true;
    } else if (closed && char.trim().isNotEmpty) {
      throw const FormatException('inventory-list-after-quote');
    } else {
      cell.write(char);
    }
  }
  if (quoted) throw const FormatException('inventory-list-unclosed-quote');
  pushRow();
  return rows;
}

/// `isInventoryListInput`: anything but JSON and `ONPKG1:` text.
bool isInventoryListText(String text) {
  final trimmed = text.trim();
  return trimmed.isNotEmpty &&
      !trimmed.startsWith('ONPKG1:') &&
      !RegExp(r'^[{\[]').hasMatch(trimmed);
}

bool isInventoryListFile(String name) =>
    RegExp(r'\.(csv|tsv)$', caseSensitive: false).hasMatch(name);

/// `previewInventoryList`: card ids or names with optional fields, in
/// native rank and awakeCount values.
BoxPreview previewInventoryList(
  String text,
  BoxView view,
  EngineMaster master,
  Doc data,
  String server,
  bool defaultMembers,
) {
  final List<List<String>> parsed;
  try {
    parsed = parseInventoryList(text);
  } catch (_) {
    throw const BoxImportError('box_invalid_list');
  }
  if (parsed.isEmpty) throw const BoxImportError('box_invalid_list');
  final first = [for (final v in parsed.first) _listHeaders[v.toLowerCase()]];
  final hasHeader = first.contains('id') || first.contains('name');
  if (hasHeader &&
      (first.any((v) => v == null) || first.toSet().length != first.length)) {
    throw const BoxImportError('box_invalid_list');
  }
  final lines = hasHeader ? parsed.sublist(1) : parsed;
  if (lines.isEmpty || lines.length > 5000) {
    throw const BoxImportError('box_invalid_list');
  }
  final cards = <String, BoxCardProposal>{};
  final issues = <BoxIssue>[];
  final names = <bool, Map<String, List<int>>>{};
  for (final members in const [true, false]) {
    final index = <String, List<int>>{};
    for (final card in objectRow(
      data[members ? 'members' : 'snapshots'],
    ).values) {
      final id = intOf(objectRow(card)['id']);
      final raw = objectRow(card)['name'];
      for (final name in {
        if (raw is List) ...raw.whereType<String>() else if (raw is String) raw,
      }) {
        final key = name.trim();
        if (key.isEmpty) continue;
        final list = index[key] ??= [];
        if (!list.contains(id)) list.add(id);
      }
    }
    names[members] = index;
  }
  final positive = RegExp(r'^[1-9]\d*$');
  final prefixedId = RegExp(r'^(member|support)-(?:card-)?([1-9]\d*)$');
  for (final (offset, cells) in lines.indexed) {
    final line = offset + (hasHeader ? 2 : 1);
    bool? members;
    int? cardId;
    try {
      if (cells.length > (hasHeader ? first.length : 1)) {
        throw const FormatException('inventory-list-extra-columns');
      }
      final input = hasHeader
          ? {
              for (final (i, field) in first.indexed)
                field!: i < cells.length ? cells[i] : '',
            }
          : {'id': cells.first};
      final kind = input['kind'] ?? '';
      members = kind.isNotEmpty
          ? _listKinds[kind.toLowerCase()]
          : defaultMembers;
      if (members == null) throw const FormatException('inventory-list-kind');
      final value = (input['id'] ?? '').isNotEmpty
          ? input['id']!
          : input['name'] ?? '';
      final prefixed = prefixedId.firstMatch(value);
      if (prefixed != null) {
        final prefixMembers = _listKinds[prefixed[1]!]!;
        if (kind.isNotEmpty && prefixMembers != members) {
          throw const FormatException('inventory-list-kind-id-mismatch');
        }
        members = prefixMembers;
        cardId = int.parse(prefixed[2]!);
      } else if (positive.hasMatch(value)) {
        cardId = int.parse(value);
      } else {
        final matches = names[members]![value] ?? const [];
        if (matches.length != 1) {
          throw FormatException(
            matches.isNotEmpty
                ? 'inventory-list-name-ambiguous'
                : 'inventory-list-card-unknown',
          );
        }
        cardId = matches.first;
      }
      if (objectRow(
        objectRow(data[members ? 'members' : 'snapshots'])['$cardId'],
      ).isEmpty) {
        throw const FormatException('inventory-list-card-unknown');
      }
      final owned = members ? view.members[cardId] : view.snaps[cardId];
      final supplied = <String, int>{};
      for (final field in memberFields) {
        final raw = input[field] ?? '';
        if (raw.isEmpty) continue;
        if (!members && !snapFields.contains(field)) {
          throw const FormatException('inventory-list-snapshot-field');
        }
        if (!positive.hasMatch(raw) || raw.length > 15) {
          throw const FormatException('inventory-list-practice-value');
        }
        supplied[field] = int.parse(raw);
      }
      final ranges = practiceRanges(
        master,
        members,
        cardId,
        training: supplied['training'] ?? ownedValue(owned, 'training'),
        awakening: supplied['awakening'] ?? ownedValue(owned, 'awakening'),
      );
      for (final MapEntry(key: field, :value) in supplied.entries) {
        if (!(ranges[field]?.contains(value) ?? false)) {
          throw const FormatException('inventory-list-practice-range');
        }
      }
      final key = '$server:${members ? 'members' : 'snapshots'}:$cardId';
      final proposal = cards[key] ??= BoxCardProposal(
        key,
        members,
        cardId,
        owned,
      );
      for (final MapEntry(key: field, :value) in supplied.entries) {
        final list = proposal.values[field] ??= [];
        if (!list.contains(value)) {
          list
            ..add(value)
            ..sort();
        }
      }
    } catch (error) {
      final code = error is FormatException
          ? error.message
          : 'inventory-list-invalid-row';
      issues.add(
        BoxIssue(
          cardId == null ? 'input' : (members! ? 'members' : 'snapshots'),
          cardId ?? line,
          'row',
          code,
        ),
      );
    }
  }
  if (cards.isEmpty) throw const BoxImportError('box_no_player');
  return BoxPreview(
    server,
    boxSignature(view),
    cards.values.toList(),
    const [],
    issues,
  );
}

enum ExistingPolicy { keep, updates, overwrite }

/// A field choice: a supplied value, `keep` the saved one, or the default.
sealed class FieldChoice {
  const FieldChoice();
}

class KeepChoice extends FieldChoice {
  const KeepChoice();
}

class ValueChoice extends FieldChoice {
  const ValueChoice(this.value);
  final int value;
}

class CardChoice {
  CardChoice({this.include = false, Map<String, FieldChoice>? fields})
    : fields = fields ?? {};
  bool include;
  final Map<String, FieldChoice> fields;
}

class MapChoice {
  MapChoice({this.include = false, this.value});
  bool include;
  FieldChoice? value;
}

class BoxConfirmation {
  BoxConfirmation(this.policy, this.cards, this.maps);

  /// Everything new is preselected: the review is about values.
  factory BoxConfirmation.all(BoxPreview preview, {bool maps = true}) =>
      BoxConfirmation(
        ExistingPolicy.keep,
        {for (final card in preview.cards) card.key: CardChoice(include: true)},
        {
          if (maps)
            for (final account in preview.accounts)
              account.key: MapChoice(include: !preview.accountBlocked(account)),
        },
      );
  ExistingPolicy policy;
  bool replaceOwnership = false;
  final Map<String, CardChoice> cards;
  final Map<String, MapChoice> maps;

  CardChoice card(String key) => cards[key] ??= CardChoice();
  MapChoice map(String key) => maps[key] ??= MapChoice();

  /// Existing-card defaults leave individual account-bonus choices intact.
  void setPolicy(BoxPreview preview, ExistingPolicy value) {
    policy = value;
    for (final card in preview.cards) {
      if (card.owned != null) cards[card.key]?.fields.clear();
    }
  }

  /// `selectAvailableBoxItems`.
  void selectAvailable(BoxPreview preview, bool include) {
    for (final card in preview.cards) {
      this.card(card.key).include = include && !preview.blocked(card);
    }
    for (final account in preview.accounts) {
      map(account.key).include = include && !preview.accountBlocked(account);
    }
  }
}

enum ValueSource { box, saved, conflict, unknown }

class ReviewField {
  ReviewField({
    required this.field,
    required this.values,
    required this.value,
    required this.source,
    required this.defaultValue,
    required this.defaultSource,
    required this.requiresChoice,
  });
  final String field;
  final List<int> values;
  final int? value;
  final ValueSource source;
  final int? defaultValue;
  final ValueSource defaultSource;
  final bool requiresChoice;
}

class ReviewMap {
  ReviewMap({
    required this.value,
    required this.defaultValue,
    required this.requiresChoice,
    required this.keep,
  });
  final int? value;
  final int? defaultValue;
  final bool requiresChoice;
  final bool keep;
}

/// `buildBoxImportReview` for one card.
List<ReviewField> reviewCard(
  BoxCardProposal proposal,
  CardChoice choice,
  ExistingPolicy policy,
) {
  final existing = proposal.owned != null;
  final keep = existing && policy == ExistingPolicy.keep;
  return [
    for (final field in proposal.fields)
      () {
        final values = proposal.values[field] ?? const <int>[];
        final selected = choice.fields[field];
        final before = proposal.existing(field);
        final saved =
            keep ||
            (existing && values.isEmpty) ||
            (policy == ExistingPolicy.updates &&
                values.length == 1 &&
                before != null &&
                values.first <= before);
        final defaultValue = saved
            ? before
            : values.length == 1
            ? values.first
            : null;
        final defaultSource = saved
            ? ValueSource.saved
            : values.length > 1
            ? ValueSource.conflict
            : values.length == 1
            ? ValueSource.box
            : ValueSource.unknown;
        return ReviewField(
          field: field,
          values: values,
          defaultValue: defaultValue,
          defaultSource: defaultSource,
          value: switch (selected) {
            KeepChoice() => before,
            ValueChoice(:final value) => value,
            null => defaultValue,
          },
          source: switch (selected) {
            KeepChoice() => ValueSource.saved,
            ValueChoice() => ValueSource.box,
            null => defaultSource,
          },
          requiresChoice: switch (selected) {
            KeepChoice() => !existing,
            ValueChoice(:final value) => !values.contains(value),
            null => defaultSource == ValueSource.conflict,
          },
        );
      }(),
  ];
}

ReviewMap reviewMap(BoxAccountProposal proposal, MapChoice choice) {
  final defaultValue = proposal.values.length == 1
      ? proposal.values.first
      : null;
  final value = switch (choice.value) {
    KeepChoice() => proposal.existing,
    ValueChoice(:final value) => value,
    null => defaultValue,
  };
  final requiresChoice = switch (choice.value) {
    KeepChoice() => !proposal.exists,
    _ => value == null || !proposal.values.contains(value),
  };
  return ReviewMap(
    value: value,
    defaultValue: defaultValue,
    requiresChoice: requiresChoice,
    keep: choice.value is KeepChoice,
  );
}

/// Whether the confirmation includes something and leaves nothing open.
bool canConfirmReview(BoxPreview preview, BoxConfirmation confirmation) {
  var included = 0;
  for (final card in preview.cards) {
    final choice = confirmation.card(card.key);
    if (!choice.include) continue;
    included++;
    if (preview.blocked(card) ||
        reviewCard(
          card,
          choice,
          confirmation.policy,
        ).any((row) => row.requiresChoice)) {
      return false;
    }
  }
  for (final map in preview.accounts) {
    final choice = confirmation.map(map.key);
    if (!choice.include) continue;
    included++;
    if (preview.accountBlocked(map) || reviewMap(map, choice).requiresChoice) {
      return false;
    }
  }
  return included > 0;
}

/// `applyConfirmedBoxImport` as one set of box writes.
List<(String, Object?)> applyBoxImport(
  BoxView view,
  BoxPreview preview,
  BoxConfirmation confirmation,
  EngineMaster master,
) {
  if (boxSignature(view) != preview.original) {
    throw const BoxImportError('box_review_changed');
  }
  final out = <(String, Object?)>[];
  if (confirmation.replaceOwnership) {
    final selected = preview.cards.where(
      (card) => confirmation.card(card.key).include,
    );
    if (selected.isEmpty) throw const BoxImportError('box_unresolved_values');
    final members = selected
        .where((card) => card.members)
        .map((card) => card.cardId)
        .toSet();
    final snaps = selected
        .where((card) => !card.members)
        .map((card) => card.cardId)
        .toSet();
    out.addAll([
      for (final id in view.members.keys)
        if (!members.contains(id)) ('m.$id.own', false),
      for (final id in view.snaps.keys)
        if (!snaps.contains(id)) ('s.$id.own', false),
    ]);
  }
  final policy = confirmation.policy;
  for (final card in preview.cards) {
    final choice = confirmation.card(card.key);
    if (!choice.include) continue;
    if (preview.blocked(card)) {
      throw const BoxImportError('box_unresolved_values');
    }
    final p = card.members ? 'm' : 's';
    final owned = card.owned != null;
    if (!owned) {
      out
        ..add(('$p.${card.cardId}.own', true))
        ..add(('$p.${card.cardId}.use', true));
    }
    final fields = <String, int>{};
    for (final MapEntry(key: field, :value) in card.values.entries) {
      final values = value;
      switch (choice.fields[field]) {
        case KeepChoice():
          if (!owned) throw const BoxImportError('box_unconfirmed_value');
        case ValueChoice(:final value):
          if (!values.contains(value)) {
            throw const BoxImportError('box_unconfirmed_value');
          }
          fields[field] = value;
        case null:
          if (!owned ||
              policy == ExistingPolicy.overwrite ||
              policy == ExistingPolicy.updates) {
            if (values.length > 1) {
              throw const BoxImportError('box_conflict_required');
            }
            final before = card.existing(field);
            if (values.length == 1 &&
                (policy != ExistingPolicy.updates ||
                    !owned ||
                    before == null ||
                    values.first > before)) {
              fields[field] = values.first;
            }
          }
      }
    }
    // The confirmed level must fit the confirmed training or awakening.
    final level = fields['level'] ?? card.existing('level');
    final cap = card.members
        ? () {
            final training = fields['training'] ?? card.existing('training');
            final member = master.members[card.cardId];
            return training == null || member == null
                ? null
                : memberLevelCap(master, member, training);
          }()
        : () {
            final rank = fields['awakening'] ?? card.existing('awakening');
            final snap = master.snaps[card.cardId];
            return rank == null || snap == null
                ? null
                : snapLevelCap(master, snap, rank);
          }();
    if (level != null && cap != null && level > cap) {
      throw const BoxImportError('box_invalid_confirmed_inventory');
    }
    for (final MapEntry(key: field, :value) in fields.entries) {
      out.add(('$p.${card.cardId}.${_boxField[field]}', value));
    }
  }
  for (final map in preview.accounts) {
    final choice = confirmation.map(map.key);
    if (!choice.include) continue;
    if (preview.accountBlocked(map)) {
      throw const BoxImportError('box_unresolved_values');
    }
    switch (choice.value) {
      case KeepChoice():
        if (!map.exists) throw const BoxImportError('box_unconfirmed_value');
        continue;
      default:
    }
    final selected = switch (choice.value) {
      ValueChoice(:final value) => value,
      _ => map.values.length == 1 ? map.values.first : null,
    };
    if (selected == null || !map.values.contains(selected)) {
      throw const BoxImportError('box_conflict_required');
    }
    out.add((map.boxKey, selected));
  }
  return out;
}
