/// Names, images and growth limits the team builder views share
/// (`lit/team-builder/catalog.ts`).
library;

import 'package:flutter/material.dart';

import '../catalog/catalog_screen.dart' show cardRarityName;
import '../catalog/cross_server.dart' show serverMark;
import '../catalog/visuals.dart';
import '../catalog/catalog_query.dart';
import '../catalog/song_presentation.dart';
import '../core/app_state.dart';
import '../core/i18n.dart';
import '../ui/card_artwork.dart';
import 'box.dart';
import 'engine/api.dart';
import 'engine/box.dart';
import 'engine/master.dart';
import 'engine/num.dart';
import 'engine/power.dart';

const difficultyNames = ['easy', 'normal', 'hard', 'expert', 'special'];

class GrowthLimits {
  GrowthLimits({
    required this.level,
    required this.awake,
    required this.rank,
    required this.liveSkillLevel,
    required this.gekisoSkillLevel,
    required this.levelCap,
  });
  final int level;
  final int awake;
  final int rank;
  final int liveSkillLevel;
  final int gekisoSkillLevel;
  final int levelCap;
}

class TeamEventOption {
  TeamEventOption(this.id, this.name, this.event, this.serverMark);
  final int id;
  final String name;
  final GameEvent event;
  final (String, String)? serverMark;
}

class TeamCatalog extends ChangeNotifier {
  TeamCatalog(this.state, this.data, this.master, this.visuals, {this.server});
  final AppState state;
  final String? server;
  final Doc data;
  final EngineMaster master;
  late final fullGrowthInputs = (
    members: [
      for (final card in master.members.values)
        () {
          final growth = maxMemberGrowth(master, card);
          return MemberInput(
            key: 'm${card.id}',
            cardId: card.id,
            level: growth.level,
            awake: growth.awake,
            rank: growth.rank,
            liveSkillLevel: growth.liveSkillLevel,
            gekisoSkillLevel: growth.gekisoSkillLevel,
          );
        }(),
    ],
    snaps: [
      for (final card in master.snaps.values)
        () {
          final growth = maxSnapGrowth(master, card);
          return SnapInput(
            key: 's${card.id}',
            cardId: card.id,
            level: growth.level,
            rank: growth.rank,
          );
        }(),
    ],
  );
  final CatalogVisuals? visuals;
  late final cardQueryEngine = CatalogQueryEngine(
    visuals: visuals,
    game: 'our-notes',
    kind: 'card',
    characters: {
      for (final entry in objectRow(data['characters']).entries)
        if (int.tryParse(entry.key) case final int id)
          id: objectRow(entry.value),
    },
    bands: {
      for (final entry in objectRow(data['bands']).entries)
        if (int.tryParse(entry.key) case final int id)
          id: objectRow(entry.value),
    },
  );
  late final songQueryEngine = CatalogQueryEngine(
    visuals: visuals,
    game: 'our-notes',
    kind: 'song',
    characters: cardQueryEngine.characters,
    bands: cardQueryEngine.bands,
  );
  Map<int, Doc> _songVisuals = const {};
  void updateSongVisuals(Map<int, Doc> value) {
    _songVisuals = value;
    _displaySongs.clear();
    notifyListeners();
  }

  final _displaySongs = <int, Doc>{};

  SiteText get t => state.text;
  String text(Object? value) => t.text(value);
  String asset(Object? path) => path is String && path.isNotEmpty
      ? state.apiFor(server ?? state.server).asset(path).toString()
      : '';

  Doc _row(String collection, int id) =>
      objectRow(objectRow(data[collection])['$id']);
  Doc member(int id) => _row('members', id);
  Doc snap(int id) => _row('snapshots', id);
  Doc card(bool members, int id) => members ? member(id) : snap(id);
  bool has(bool members, int id) => card(members, id).isNotEmpty;

  Doc get _cross => objectRow(data['crossServer']);

  bool available(String collection, int id) =>
      _cross.isEmpty ||
      (objectRow(objectRow(_cross['availability'])[collection])['$id']
                  as List? ??
              const [])
          .contains(server);

  /// An entity only one server has carries that server's mark.
  (String, String)? mark(String collection, int id) {
    final identities = objectRow(_cross['identities']);
    if (!identities.containsKey('jp') || !identities.containsKey('intl')) {
      return null;
    }
    final servers = objectRow(
      objectRow(_cross['availability'])[collection],
    )['$id'];
    return serverMark({'_servers': servers}, t.call);
  }

  String cardName(bool members, int id) {
    final row = card(members, id);
    return row.isEmpty ? '#$id' : text(row['name']);
  }

  List<int> characterIds(bool members, int id) => members
      ? [if (member(id)['characterId'] case final num c) c.toInt()]
      : intListOf(snap(id)['characterIds']);

  Doc _character(int id) => _row('characters', id);
  String characterName(int id) => text(_character(id)['characterName']);
  String characterFace(int id) {
    final visual = visuals?.characters[id];
    return asset(
      visual?['faceImage'] ??
          _character(id)['faceImage'] ??
          _character(id)['thumbnailImage'],
    );
  }

  Color characterColor(int id, Color fallback) {
    final code = '${_character(id)['colorCode'] ?? ''}'.replaceFirst('#', '');
    final value = int.tryParse(code, radix: 16);
    return code.length == 6 && value != null
        ? Color(0xFF000000 | value)
        : fallback;
  }

  int characterBand(int id) => intOf(_character(id)['bandId']);

  String bandName(int id) {
    final row = _row('bands', id);
    return text(row['bandName'] ?? row['name']);
  }

  String bandIcon(int id) {
    final row = _row('bands', id);
    return asset(row['icon'] ?? row['logo']);
  }

  List<int> get bandIds => [
    for (final key in objectRow(data['bands']).keys)
      if (int.tryParse(key) case final id? when bandName(id).isNotEmpty) id,
  ];

  String attributeName(int attribute) {
    const keys = ['', 'red', 'blue', 'green', 'yellow', 'purple'];
    final key = attribute > 0 && attribute < keys.length ? keys[attribute] : '';
    return key.isEmpty ? '' : t('catalog.songs.liveTypes.$key', key);
  }

  /// Skill type names a card carries in one role (`skillName` of
  /// `catalogMetadata.resolvedSkills`), the website's `skillFacetValues`.
  /// Only the canonical (first non-empty) name counts, so the localised
  /// variants of one skill do not turn into separate filter options.
  List<String> skillTypes(bool members, int id, String role) {
    final meta = objectRow(card(members, id)['catalogMetadata']);
    final value = objectRow(
      meta['resolvedSkills'],
    )[role == 'gekiso' ? 'gekisou' : role];
    final rows = value is List
        ? value.map(objectRow)
        : value is Map
        ? [objectRow(value)]
        : const <Doc>[];
    return {
      for (final entry in rows)
        if (entry['skillName'] case final List names)
          if (names
                  .whereType<String>()
                  .where((name) => name.trim().isNotEmpty)
                  .firstOrNull
              case final name?)
            name.trim(),
    }.toList();
  }

  /// Every distinct skill type of the given role across the loaded cards.
  List<String> skillTypeOptions(bool members, String role) {
    final ids = [
      for (final key in objectRow(data[members ? 'members' : 'snapshots']).keys)
        ?int.tryParse(key),
    ];
    final seen = <String>{};
    for (final id in ids) {
      seen.addAll(skillTypes(members, id, role));
    }
    final sorted = seen.toList()..sort();
    return sorted;
  }

  String? attributeIcon(int attribute) => visuals?.cardTypeMark(attribute);
  String? rarityIcon(int rarity) =>
      visuals?.mark('RarityIconCenter_${cardRarityName(rarity)}.png');

  int rarity(bool members, int id) => intOf(card(members, id)['rarity']);
  int attribute(bool members, int id) => intOf(card(members, id)['attribute']);
  String cardImage(bool members, int id) => asset(card(members, id)['image']);

  String cardSubtitle(bool members, int id) => [
    for (final character in characterIds(members, id)) characterName(character),
  ].where((name) => name.isNotEmpty).join(' · ');

  GrowthLimits? memberLimits(int id, int? awake) {
    final card = master.members[id];
    if (card == null) return null;
    final max = maxMemberGrowth(master, card);
    return GrowthLimits(
      level: max.level,
      awake: max.awake,
      rank: max.rank,
      liveSkillLevel: max.liveSkillLevel,
      gekisoSkillLevel: max.gekisoSkillLevel,
      levelCap: memberLevelCap(master, card, awake ?? max.awake),
    );
  }

  GrowthLimits? snapLimits(int id, int? rank) {
    final card = master.snaps[id];
    if (card == null) return null;
    final max = maxSnapGrowth(master, card);
    return GrowthLimits(
      level: max.level,
      awake: 0,
      rank: max.rank,
      liveSkillLevel: 0,
      gekisoSkillLevel: 0,
      levelCap: snapLevelCap(master, card, rank ?? max.rank),
    );
  }

  CardGrowthDisplay _growth(
    bool members,
    int id, {
    int? level,
    int? training,
    int? rank,
    int? liveSkill,
    int? gekisoSkill,
    String unknown = '?',
  }) {
    String label(String key, String fallback) =>
        t('tools.teamBuilder.$key', fallback);
    CardSkillMark? skill(String kind, int? value, String name) {
      final source = objectRow(objectRow(data['skills'])[kind]);
      final skillId = member(
        id,
      )[kind == 'live' ? 'liveSkillId' : 'gekisoSkillId'];
      final icon = asset(objectRow(source['$skillId'])['icon']);
      return icon.isEmpty ? null : CardSkillMark(icon, value, name);
    }

    return CardGrowthDisplay(
      level: level,
      rank: rank,
      rankIcon: visuals?.mark(
        members ? 'CardRank${rank ?? 0}.png' : 'snaplimit_${rank ?? 0}.png',
      ),
      rankLabel: label('awakening', 'Awakening'),
      training: training,
      trainingIcon: visuals?.mark('SpecialTraining.png'),
      trainingLabel: label('training', 'Training'),
      liveSkill: members
          ? skill('live', liveSkill, label('liveSkill', 'Live skill'))
          : null,
      gekisoSkill: members
          ? skill('gekiso', gekisoSkill, label('gekisoSkill', 'GEKISO skill'))
          : null,
      unknown: unknown,
    );
  }

  CardGrowthDisplay? ownedGrowth(
    bool members,
    Object? owned,
    UnknownPolicy policy,
  ) {
    final unknown = policy == UnknownPolicy.max ? '★' : '?';
    if (owned is OwnedMember) {
      final cap = memberLimits(owned.cardId, owned.awake)?.levelCap;
      return _growth(
        true,
        owned.cardId,
        level: owned.level == null || cap == null
            ? owned.level
            : owned.level!.clamp(1, cap),
        training: owned.awake,
        rank: owned.rank,
        liveSkill: owned.skill,
        gekisoSkill: owned.gekisoSkill,
        unknown: unknown,
      );
    }
    if (owned is OwnedSnap) {
      final cap = snapLimits(owned.cardId, owned.rank)?.levelCap;
      return _growth(
        false,
        owned.cardId,
        level: owned.level == null || cap == null
            ? owned.level
            : owned.level!.clamp(1, cap),
        rank: owned.rank,
        unknown: unknown,
      );
    }
    return null;
  }

  CardGrowthDisplay? resolvedGrowth(Object input, UnknownPolicy policy) {
    if (input is MemberInput) {
      final card = master.members[input.cardId];
      if (card == null) return null;
      final growth = memberGrowth(master, card, input, policy);
      return _growth(
        true,
        input.cardId,
        level: growth.level,
        training: growth.awake,
        rank: growth.rank,
        liveSkill: growth.liveSkillLevel,
        gekisoSkill: growth.gekisoSkillLevel,
      );
    }
    if (input is SnapInput) {
      final card = master.snaps[input.cardId];
      if (card == null) return null;
      final growth = snapGrowth(master, card, input, policy);
      return _growth(
        false,
        input.cardId,
        level: growth.level,
        rank: growth.rank,
      );
    }
    return null;
  }

  SongPresentation get songPresentation =>
      SongPresentation(t, state.apiFor(server ?? state.server), visuals);
  Doc song(int id) {
    final row = objectRow(data['songs'])['$id'];
    return row is Doc ? row : objectRow(row);
  }

  /// Full display identity never replaces the engine's slim calculation row.
  Doc displaySong(int id) =>
      _displaySongs.putIfAbsent(id, () => {...song(id), ...?_songVisuals[id]});
  String songTitle(int id) => state.songTitle(song(id)['musicTitle']);
  String songJacket(int id) =>
      asset(song(id)['jacketUrl'] ?? song(id)['jacketThumbUrl']);
  List<int> songBands(int id) {
    final row = song(id);
    final bands = row['bandIds'] is List
        ? row['bandIds'] as List
        : [if (row['bandId'] != null) row['bandId']];
    return [
      for (final band in bands)
        if (numOf(band) > 0) numOf(band).toInt(),
    ];
  }

  List<Doc> difficultyRows(int id) => dataRows(song(id)['difficulty']);
  Doc? difficultyRow(int songId, int difficulty) =>
      difficultyRows(songId)
          .where((row) => intOf(row['difficulty']) == difficulty)
          .firstOrNull;

  String difficultyLabel(int songId, int difficulty) {
    final row = difficultyRow(songId, difficulty);
    if (row == null) return '';
    final name = difficulty >= 0 && difficulty < difficultyNames.length
        ? difficultyNames[difficulty].toUpperCase()
        : '$difficulty';
    final level = row['displayLevel'] ?? row['playLevel'] ?? '';
    return '$name ${level is num && level == level.roundToDouble() ? level.toInt() : level}';
  }

  /// The chart file of a song difficulty, pinned to its release.
  String? chartUrl(SongRef ref) {
    final file = difficultyRow(ref.songId, ref.difficulty)?['file'];
    if (file is! String || file.isEmpty) return null;
    final uri = Uri.parse(file);
    if (uri.queryParameters.containsKey('release')) return asset(file);
    final owner =
        '${objectRow(objectRow(_cross['owners'])['songs'])['${ref.songId}'] ?? ''}';
    final pinned = objectRow(objectRow(_cross['identities'])[owner]);
    final identity = pinned.isNotEmpty ? pinned : objectRow(data['identity']);
    return asset(
      uri
          .replace(
            queryParameters: {
              ...uri.queryParameters,
              'release': '${identity['releaseId']}',
            },
          )
          .toString(),
    );
  }

  /// Events with a live point table (searchable event goals), newest first.
  List<TeamEventOption> events() {
    final rows = [
      for (final event in master.events.values)
        if (event.livePoints.isNotEmpty ||
            event.challengePoints.isNotEmpty ||
            event.effects.isNotEmpty)
          event,
    ]..sort((a, b) => (b.startAt ?? 0) - (a.startAt ?? 0));
    return [
      for (final event in rows)
        TeamEventOption(
          event.id,
          () {
            final row = _row('events', event.id);
            final name = text(row['name'] ?? row['title']);
            return name.isEmpty ? '#${event.id}' : name;
          }(),
          event,
          mark('events', event.id),
        ),
    ];
  }

  List<ChallengeMusic> challengeSongs(int? eventId) => [
    for (final row in master.challengeMusics)
      if (eventId == null || row.eventId == eventId) row,
  ];

  List<int> normalEventSongIds(int? eventId) {
    final eventSong = master.events[eventId]?.musicId;
    return [
      for (final key in objectRow(data['songs']).keys)
        if (int.tryParse(key) case final id? when id != eventSong) id,
    ];
  }
}
