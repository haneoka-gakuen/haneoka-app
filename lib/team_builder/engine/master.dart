/// Typed, search-ready Master tables compiled from the public team-builder
/// document (`/api/v1/team-builder/{server}`). A port of the website's
/// `team-builder/engine/master.ts` (its DTO front-end).
library;

import 'num.dart';

typedef Stat3 = List<int>;

class TargetRow {
  TargetRow(Doc row)
    : id = intOf(row['id']),
      bandId = intOf(row['bandID'] ?? row['bandId']),
      cardType = intOf(row['cardType']),
      characterId = intOf(row['characterID'] ?? row['characterId']),
      tagId = intOf(row['tagID'] ?? row['tagId']),
      liveSkillCategories = intListOf(row['liveSkillCategories']),
      gekisouSkillCategories = intListOf(row['gekisouSkillCategories']),
      gekisouMissionType = intOf(row['gekisouMissionType']),
      liveMusicType = intOf(row['liveMusicType']),
      judgement = intOf(row['judgement'], -1),
      skillTargetType = intOf(row['skillTargetType']);
  final int id;
  final int bandId;
  final int cardType;
  final int characterId;
  final int tagId;
  final List<int> liveSkillCategories;
  final List<int> gekisouSkillCategories;
  final int gekisouMissionType;
  final int liveMusicType;
  final int judgement;
  final int skillTargetType;
}

class ConditionRow {
  ConditionRow(this.id, this.type, this.targetIds, this.values, this.positive);
  final int id;
  final int type;
  final List<int> targetIds;
  final List<double> values;
  final bool positive;
}

class CumulativeRow {
  CumulativeRow(this.id, this.type, this.targetIds, this.values, this.cap);
  final int id;
  final int type;
  final List<int> targetIds;
  final List<double> values;
  final int cap;
}

class SkillEffectRow {
  SkillEffectRow(Doc row)
    : id = intOf(row['id']),
      level = intOf(row['level']),
      triggerType = intOf(row['skillTriggerType']),
      executeLimit = intOf(row['effectExecuteLimitCount']),
      resetGroup = intOf(row['effectExecuteLimitResetConditionGroup']),
      type = intOf(row['skillEffectType'] ?? row['effectType']),
      value = intOf(row['effectValue']),
      seconds = numOf(row['activationTimeSecond']),
      conditionGroup = intOf(
        row['skillConditionGroup'] ?? row['conditionGroup'],
      ),
      triggerGroup = intOf(
        row['skillTriggerConditionGroup'] ?? row['triggerConditionGroup'],
      ),
      releaseGroup = intOf(
        row['skillReleaseConditionGroup'] ?? row['releaseConditionGroup'],
      ),
      cumulativeId = intOf(
        row['skillCumulativeConditionID'] ?? row['cumulativeConditionId'],
      ),
      targetIds = idsOf(row['skillTargetIDs'] ?? row['targetIds']),
      limitCount = intOf(row['effectLimitCount']),
      maxValue = intOf(row['maxEffectValue']);
  SkillEffectRow._copy(SkillEffectRow o, {int? id, int? level, int? value})
    : id = id ?? o.id,
      level = level ?? o.level,
      triggerType = o.triggerType,
      executeLimit = o.executeLimit,
      resetGroup = o.resetGroup,
      type = o.type,
      value = value ?? o.value,
      seconds = o.seconds,
      conditionGroup = o.conditionGroup,
      triggerGroup = o.triggerGroup,
      releaseGroup = o.releaseGroup,
      cumulativeId = o.cumulativeId,
      targetIds = o.targetIds,
      limitCount = o.limitCount,
      maxValue = o.maxValue;
  SkillEffectRow copyWith({int? id, int? level, int? value}) =>
      SkillEffectRow._copy(this, id: id, level: level, value: value);
  final int id;
  final int level;

  /// Condition skills: 1 one-shot, 2 sustained.
  final int triggerType;
  final int executeLimit;
  final int resetGroup;
  final int type;
  final int value;
  final double seconds;
  final int conditionGroup;
  final int triggerGroup;
  final int releaseGroup;
  final int cumulativeId;
  final List<int> targetIds;
  final int limitCount;
  final int maxValue;
}

class MemberCard {
  MemberCard({
    this.levelLimits,
    required this.id,
    required this.characterId,
    required this.bandId,
    required this.rarity,
    required this.cardType,
    required this.bestTags,
    required this.statMax,
    required this.levelGroup,
    required this.awakeGroup,
    required this.rankGroup,
    required this.liveSkillId,
    required this.gekisoSkillId,
    required this.leaderSkillId,
  });
  final Map<String, int>? levelLimits;
  final int id;
  final int characterId;
  final int bandId;
  final int rarity;
  final int cardType;
  final List<int> bestTags;
  final Stat3 statMax;
  final int levelGroup;
  final int awakeGroup;
  final int rankGroup;
  final int liveSkillId;
  final int gekisoSkillId;
  final int leaderSkillId;
}

class SnapCard {
  SnapCard({
    required this.id,
    required this.characterIds,
    required this.bandIds,
    required this.rarity,
    required this.cardType,
    required this.statMax,
    required this.levelGroup,
    required this.rankGroup,
    required this.supportSkillIds,
    required this.gekisoSupportSkillIds,
  });
  final int id;
  final List<int> characterIds;
  final List<int> bandIds;
  final int rarity;
  final int cardType;
  final Stat3 statMax;
  final int levelGroup;
  final int rankGroup;
  final List<int> supportSkillIds;
  final List<int> gekisoSupportSkillIds;
}

class MemberRankRow {
  MemberRankRow(
    this.rates,
    this.leaderSkillLevel,
    this.musicTypeRate,
    this.musicTagRate,
  );
  final Stat3 rates;
  final int leaderSkillLevel;
  final int musicTypeRate;
  final int musicTagRate;
}

class SnapRankRow {
  SnapRankRow(
    this.typeLinkRate,
    this.limitLevel,
    this.skillLevels,
    this.gekisoSkillLevels,
  );
  final int typeLinkRate;
  final int limitLevel;
  final List<int> skillLevels;
  final List<int> gekisoSkillLevels;
}

class SongDifficulty {
  SongDifficulty(
    this.difficulty,
    this.scoreId,
    this.playLevel,
    this.displayLevel,
    this.noteCount,
    this.file,
  );
  final int difficulty;
  final int scoreId;
  final double playLevel;
  final double displayLevel;
  final int noteCount;
  final String file;
}

class Song {
  Song(
    this.id,
    this.musicType,
    this.bestTags,
    this.bandIds,
    this.rankGroup,
    this.difficulties,
    this.gekisoMissions,
  );
  final int id;
  final int musicType;
  final List<int> bestTags;
  final List<int> bandIds;
  final int rankGroup;
  final List<SongDifficulty> difficulties;
  final List<int> gekisoMissions;
}

class ChallengeMusic {
  ChallengeMusic(this.id, this.eventId, this.liveMusicId, this.musicType);
  final int id;
  final int eventId;
  final int liveMusicId;
  final int musicType;
}

class ScoreRankRow {
  ScoreRankRow(this.rank, this.required, this.battleRequired);
  final int rank;
  final int required;
  final int battleRequired;
}

class EventEffectRow {
  EventEffectRow(Doc row)
    : resourceType = intOf(row['resourceTypeConstraint']),
      characterId = intOf(row['characterId']),
      bandId = intOf(row['bandId']),
      cardType = intOf(row['cardType']),
      tagId = intOf(row['tagId']),
      memberCardId = intOf(row['memberCardId']),
      supportCardId = intOf(row['supportCardId']),
      bonusType = intOf(row['eventBonusType']),
      perRank = row['perRank'] is List
          ? [
              for (final rank in [1, 2, 3, 4, 5])
                intOf(
                  dataRows(row['perRank'])
                      .where((item) => intOf(item['rank']) == rank)
                      .firstOrNull?['value'],
                ),
            ]
          : [
              for (final rank in [1, 2, 3, 4, 5])
                intOf(row['rank${rank}EffectValue']),
            ];
  final int resourceType;
  final int characterId;
  final int bandId;
  final int cardType;
  final int tagId;
  final int memberCardId;
  final int supportCardId;
  final int bonusType;
  final List<int> perRank;
}

class RewardRow {
  RewardRow(Doc row)
    : scoreRank = intOf(row['scoreRank']),
      group = intOf(row['group']),
      resourceType = intOf(row['resourceType']),
      resourceId = intOf(row['resourceId']),
      count = intOf(row['resourceCount']),
      probability = numOf(row['probability'], 10000);
  final int scoreRank;
  final int group;
  final int resourceType;
  final int resourceId;
  final int count;
  final double probability;
}

class GameEvent {
  GameEvent({
    required this.id,
    required this.startAt,
    required this.endAt,
    required this.itemId,
    required this.musicId,
    required this.effects,
    required this.livePoints,
    required this.challengePoints,
    required this.liveRewards,
    required this.challengeRewards,
  });
  final int id;
  final int? startAt;
  final int? endAt;
  final int itemId;
  final int musicId;
  final List<EventEffectRow> effects;

  /// score rank → points per play at rate 1.
  final Map<int, int> livePoints;
  final Map<int, int> challengePoints;
  final List<RewardRow> liveRewards;
  final List<RewardRow> challengeRewards;
}

class BoostRow {
  BoostRow(this.consumed, this.eventPointRate, this.rewardRate);
  final int consumed;
  final double eventPointRate;
  final double rewardRate;
}

class GekisouTables {
  GekisouTables({
    required this.luckBasePoints,
    required this.luckBonusLots,
    required this.rankingBonuses,
    required this.gaugeMax,
    required this.gaugeMaxRush,
    required this.rushPercent,
  });
  final List<({int category, int judgement, int weight, int point})>
  luckBasePoints;
  final List<({int lotType, int result, int weight})> luckBonusLots;
  final List<({int pattern, int count, int rank, int percent})> rankingBonuses;
  final int gaugeMax;
  final int gaugeMaxRush;
  final int rushPercent;
}

class LiveTables {
  LiveTables({
    required this.adjustment,
    required this.lifeOnus,
    required this.lifeBase,
    required this.notePercent,
    required this.judgePercent,
    required this.combo,
    required this.assistPercent,
    required this.damage,
    required this.settings,
    required this.justTypes,
    required this.timingTypes,
    required this.perfectAfterMs,
    required this.afterMs,
    required this.phases,
    required this.gekiso,
  });
  final GekisouTables gekiso;
  final double adjustment;
  final double lifeOnus;
  final double lifeBase;
  final Map<int, double> notePercent;

  /// Score type (1 Just … 6 Miss) → percent.
  final Map<int, double> judgePercent;

  /// combo bonus type → ascending [required combo, cumulative float32 factor].
  final Map<int, List<(int, double)>> combo;
  final double assistPercent;

  /// Life damage indexed by simulate judgement (1 Miss … 6 Just).
  final List<double> damage;
  final Map<String, String> settings;
  final Set<int> justTypes;
  final Set<int> timingTypes;
  final Map<int, num> perfectAfterMs;
  final double afterMs;
  final Map<int, int> phases;
}

class EngineParams {
  EngineParams(
    this.musicTypeBase,
    this.musicTagBase,
    this.typeLinkBase,
    this.skipRank,
  );
  final int musicTypeBase;
  final int musicTagBase;
  final int typeLinkBase;
  final int skipRank;
}

class BandItem {
  BandItem(this.bandId, this.levels);
  final int bandId;
  final Map<int, List<SkillEffectRow>> levels;
}

class GekisoSkill {
  GekisoSkill(this.missionType, this.effects);
  final int missionType;
  final List<SkillEffectRow> effects;
}

class EngineMaster {
  EngineMaster({
    required this.server,
    required this.releaseId,
    required this.params,
    required this.live,
    required this.characters,
    required this.members,
    required this.snaps,
    required this.memberLevels,
    required this.memberAwake,
    required this.memberRanks,
    required this.memberLevelLimits,
    required this.snapLevels,
    required this.snapRanks,
    required this.characterRankBonus,
    required this.totalRankBonus,
    required this.maxCharacterRank,
    required this.vipBonus,
    required this.bandItems,
    required this.targets,
    required this.conditions,
    required this.conditionSets,
    required this.cumulative,
    required this.leaderSkills,
    required this.liveSkills,
    required this.supportSkills,
    required this.gekisoSkills,
    required this.gekisoSupportSkills,
    required this.liveSkillCategories,
    required this.gekisoSkillCategories,
    required this.songs,
    required this.scoreRanks,
    required this.challengeMusics,
    required this.events,
    required this.liveChallengePoints,
    required this.boosts,
    required this.challengeBoosts,
  });
  final String server;
  final String releaseId;
  final EngineParams params;
  final LiveTables live;

  /// character → band.
  final Map<int, int> characters;
  final Map<int, MemberCard> members;
  final Map<int, SnapCard> snaps;
  final Map<int, Map<int, Stat3>> memberLevels;
  final Map<int, Map<int, Stat3>> memberAwake;
  final Map<int, Map<int, MemberRankRow>> memberRanks;

  /// `rarity:awake` → level cap.
  final Map<String, int> memberLevelLimits;
  final Map<int, Map<int, Stat3>> snapLevels;
  final Map<int, Map<int, SnapRankRow>> snapRanks;
  final List<(int, int)> characterRankBonus;
  final List<(int, int)> totalRankBonus;
  final int maxCharacterRank;
  final Map<int, int> vipBonus;
  final Map<int, BandItem> bandItems;
  final Map<int, TargetRow> targets;
  final Map<int, ConditionRow> conditions;
  final Map<int, List<List<int>>> conditionSets;
  final Map<int, CumulativeRow> cumulative;
  final Map<int, List<SkillEffectRow>> leaderSkills;
  final Map<int, List<SkillEffectRow>> liveSkills;
  final Map<int, List<SkillEffectRow>> supportSkills;
  final Map<int, GekisoSkill> gekisoSkills;
  final Map<int, GekisoSkill> gekisoSupportSkills;
  final Map<int, List<int>> liveSkillCategories;
  final Map<int, List<int>> gekisoSkillCategories;
  final Map<int, Song> songs;
  final Map<int, List<ScoreRankRow>> scoreRanks;
  final List<ChallengeMusic> challengeMusics;
  final Map<int, GameEvent> events;
  final Map<int, int> liveChallengePoints;
  final List<BoostRow> boosts;
  final List<BoostRow> challengeBoosts;

  /// The same release with other member Gekisou skills.
  EngineMaster withGekisoSkills(Map<int, GekisoSkill> skills) =>
      _with(gekisoSkills: skills);
  EngineMaster withSongs(Map<int, Song> songs) => _with(songs: songs);
  EngineMaster _with({
    Map<int, GekisoSkill>? gekisoSkills,
    Map<int, Song>? songs,
  }) => EngineMaster(
    server: server,
    releaseId: releaseId,
    params: params,
    live: live,
    characters: characters,
    members: members,
    snaps: snaps,
    memberLevels: memberLevels,
    memberAwake: memberAwake,
    memberRanks: memberRanks,
    memberLevelLimits: memberLevelLimits,
    snapLevels: snapLevels,
    snapRanks: snapRanks,
    characterRankBonus: characterRankBonus,
    totalRankBonus: totalRankBonus,
    maxCharacterRank: maxCharacterRank,
    vipBonus: vipBonus,
    bandItems: bandItems,
    targets: targets,
    conditions: conditions,
    conditionSets: conditionSets,
    cumulative: cumulative,
    leaderSkills: leaderSkills,
    liveSkills: liveSkills,
    supportSkills: supportSkills,
    gekisoSkills: gekisoSkills ?? this.gekisoSkills,
    gekisoSupportSkills: gekisoSupportSkills,
    liveSkillCategories: liveSkillCategories,
    gekisoSkillCategories: gekisoSkillCategories,
    songs: songs ?? this.songs,
    scoreRanks: scoreRanks,
    challengeMusics: challengeMusics,
    events: events,
    liveChallengePoints: liveChallengePoints,
    boosts: boosts,
    challengeBoosts: challengeBoosts,
  );
}

final _wallClock = RegExp(
  r'^(\d{4})[/-](\d{1,2})[/-](\d{1,2})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?$',
);

/// Master dates are server wall clock; callers compare them with the same offset.
int? _time(Object? value) {
  if (value is List) {
    return _time(value.firstWhere((slot) => slot != null, orElse: () => null));
  }
  if (value is num && value.isFinite) return value.toInt();
  if (value is! String || value.trim().isEmpty || value == 'null') return null;
  final match = _wallClock.firstMatch(value.trim());
  if (match == null) return DateTime.tryParse(value)?.millisecondsSinceEpoch;
  int part(int i) => int.parse(match.group(i) ?? '0');
  return DateTime.utc(
    part(1),
    part(2),
    part(3),
    part(4),
    part(5),
    part(6),
  ).millisecondsSinceEpoch;
}

const _ranks = {
  'None': 0,
  'E': 1,
  'D': 2,
  'C': 3,
  'B': 4,
  'A': 5,
  'S': 6,
  'SS': 7,
};

Map<int, Map<int, V>> _nested<V>(
  List<Doc> rows,
  String outer,
  String inner,
  V Function(Doc row) value,
) {
  final out = <int, Map<int, V>>{};
  for (final row in rows) {
    (out[intOf(row[outer])] ??= {})[intOf(row[inner])] = value(row);
  }
  return out;
}

Stat3 _stat(Doc row, String p, String t, String v) => [
  intOf(row[p]),
  intOf(row[t]),
  intOf(row[v]),
];

List<BoostRow> _boostRows(List<Doc> rows, String consumed) => [
  for (final row in rows)
    BoostRow(
      intOf(row[consumed]),
      numOf(row['eventPointRate']),
      numOf(row['liveMusicRewardRate']),
    ),
]..sort((a, b) => a.consumed - b.consumed);

List<Doc> _rowsOf(Object? value) => [
  for (final row in dataRows(value)) nativeRow(row),
];

Map<int, List<SkillEffectRow>> _skillMap(Object? record) => {
  for (final entry in objectRow(record).entries)
    int.parse(entry.key): [
      for (final row in _rowsOf(objectRow(entry.value)['effects']))
        SkillEffectRow(row),
    ],
};

Map<int, GekisoSkill> _gekisoMap(Object? record) => {
  for (final entry in objectRow(record).entries)
    int.parse(entry.key): GekisoSkill(
      intOf(objectRow(entry.value)['gekisouMissionType']),
      [
        for (final row in _rowsOf(objectRow(entry.value)['effects']))
          SkillEffectRow(row),
      ],
    ),
};

Map<int, List<int>> _categories(Object? record) => {
  for (final entry in objectRow(record).entries)
    int.parse(entry.key): intListOf(objectRow(entry.value)['categories']),
};

List<int> _distinct(Iterable<int> values) => values.toSet().toList();

/// `compileFromTeamData`.
EngineMaster compileTeamData(Doc data) {
  final identity = objectRow(data['identity']);
  final runtime = objectRow(objectRow(data['runtimeRules'])['tables']);
  final liveTools = objectRow(data['liveTools']);
  final progression = objectRow(data['progression']);
  final reference = objectRow(data['skillReference']);
  final skills = objectRow(data['skills']);
  final characterRows = objectRow(data['characters']);
  List<Doc> progress(String key) => _rowsOf(progression[key]);

  final parameters = dataRows(objectRow(runtime['parameters'])['rows']);
  Object? parameter(String key) =>
      parameters.where((row) => row['id'] == key).firstOrNull?['value'];
  final liveSettings = _rowsOf(liveTools['liveSettings']);
  double setting(String key, double fallback) => numOf(
    liveSettings.where((row) => row['key'] == key).firstOrNull?['value'],
    fallback,
  );

  final judge = <int, double>{};
  final damage = List<double>.filled(7, 0);
  // NoteSimulateJudgement 1 Miss … 6 Just → score type 6 Miss … 1 Just.
  for (final row in _rowsOf(liveTools['judgementParameters'])) {
    final simulate = intOf(row['noteSimulateJudgement'], -1);
    if (simulate >= 1 && simulate <= 6) {
      judge[7 - simulate] = numOf(row['scorePercent']);
      damage[simulate] = numOf(row['damage']);
    }
  }
  final combo = <int, List<(int, double)>>{};
  for (final entry in groupBy(
    _rowsOf(liveTools['comboScoreBonuses']),
    (row) => intOf(row['comboBonusType']),
  ).entries) {
    final items = [...entry.value]
      ..sort(
        (a, b) =>
            intOf(a['requiredComboCount']) - intOf(b['requiredComboCount']),
      );
    var sum = 0.0;
    combo[entry.key] = [
      for (final row in items)
        (
          intOf(row['requiredComboCount']),
          sum = f(sum + f(numOf(row['bonusFactor']))),
        ),
    ];
  }
  final timings = _rowsOf(liveTools['judgementTiming']);

  final nonPlayable = {
    for (final row in dataRows(
      objectRow(data['masterCharacterRoster'])['rows'],
    ).map(nativeRow))
      if (row['isNonPlayable'] == true) intOf(row['characterId'] ?? row['id']),
  };
  final characters = <int, int>{
    for (final row in characterRows.values.map(objectRow))
      if (row['isNonPlayable'] != true &&
          !nonPlayable.contains(intOf(row['characterId'] ?? row['id'])))
        intOf(row['characterId'] ?? row['id']): intOf(
          row['bandId'] ?? row['bandID'],
        ),
  };

  final members = <int, MemberCard>{};
  for (final value in objectRow(data['members']).values) {
    final card = objectRow(value);
    final stat = objectRow(card['statMax']);
    final limits = card['levelLimits'];
    final member = MemberCard(
      levelLimits: limits is Map
          ? {
              for (final entry in limits.entries)
                '${entry.key}': intOf(entry.value),
            }
          : null,
      id: intOf(card['id']),
      characterId: intOf(card['characterId']),
      bandId: intOf(card['bandId']),
      rarity: intOf(card['rarity']),
      cardType: intOf(card['attribute']),
      bestTags: intListOf(card['bestMusicTagIds']),
      statMax: [
        intOf(stat['performance']),
        intOf(stat['technique']),
        intOf(stat['visual']),
      ],
      levelGroup: intOf(card['levelGroup']),
      awakeGroup: intOf(card['trainingGroup']),
      rankGroup: intOf(card['awakeningGroup']),
      liveSkillId: intOf(card['liveSkillId']),
      gekisoSkillId: intOf(card['gekisoSkillId']),
      leaderSkillId: intOf(card['leaderSkillId']),
    );
    members[member.id] = member;
  }
  final snaps = <int, SnapCard>{};
  for (final value in objectRow(data['snapshots']).values) {
    final card = objectRow(value);
    final stat = objectRow(card['statMax']);
    final characterIds = intListOf(card['characterIds']);
    final support = intListOf(card['supportSkillIds']);
    final gekiso = intListOf(card['gekisoSupportSkillIds']);
    final snap = SnapCard(
      id: intOf(card['id']),
      characterIds: characterIds,
      bandIds: _distinct(
        characterIds
            .map((id) => intOf(objectRow(characterRows['$id'])['bandId']))
            .where((band) => band != 0),
      ),
      rarity: intOf(card['rarity']),
      cardType: intOf(card['attribute']),
      statMax: [
        intOf(stat['performance']),
        intOf(stat['technique']),
        intOf(stat['visual']),
      ],
      levelGroup: intOf(card['levelGroup']),
      rankGroup: intOf(card['awakeningGroup']),
      supportSkillIds: [
        support.elementAtOrNull(0) ?? 0,
        support.elementAtOrNull(1) ?? 0,
      ],
      gekisoSupportSkillIds: [
        gekiso.elementAtOrNull(0) ?? 0,
        gekiso.elementAtOrNull(1) ?? 0,
      ],
    );
    snaps[snap.id] = snap;
  }

  final conditionSets = <int, List<List<int>>>{};
  for (final row in _rowsOf(reference['conditionSets'])) {
    (conditionSets[intOf(row['group'])] ??= []).add(idsOf(row['conditionIds']));
  }
  final scoreRanks = <int, List<ScoreRankRow>>{
    for (final entry in groupBy(
      _rowsOf(liveTools['scoreRanks']),
      (row) => intOf(row['group']),
    ).entries)
      entry.key: [
        for (final row in entry.value)
          ScoreRankRow(
            intOf(row['liveScoreRank']),
            intOf(row['requiredScore']),
            intOf(row['battleLiveRequiredScore']),
          ),
      ]..sort((a, b) => a.required - b.required),
  };
  final levelLimits = <String, int>{
    for (final row in progress('memberCardLevelLimits'))
      '${intOf(row['rarity'])}:${intOf(row['awakeCount'])}': intOf(
        row['limitLevel'],
      ),
  };
  final characterRanks = progress('characterRanks');

  final songs = <int, Song>{};
  for (final value in objectRow(data['songs']).values) {
    final row = objectRow(value);
    final song = Song(
      intOf(row['musicId']),
      intOf(row['musicType']),
      idsOf(row['bestMusicTagIds']),
      idsOf(row['bandIds'] ?? (row['bandId'] != null ? [row['bandId']] : [])),
      intOf(row['liveScoreRankGroup']),
      [
        for (final level in dataRows(row['difficulty']))
          SongDifficulty(
            intOf(level['difficulty']),
            intOf(level['scoreId']),
            numOf(level['playLevel']),
            numOf(level['displayLevel'] ?? level['playLevel']),
            intOf(level['noteCount']),
            '${level['file'] ?? ''}',
          ),
      ],
      intListOf(objectRow(row['gekisou'])['missionTypes']),
    );
    songs[song.id] = song;
  }

  final sharedRules = objectRow(data['eventRules']);
  final events = <int, GameEvent>{};
  for (final value in objectRow(data['events']).values) {
    final event = objectRow(value);
    final id = intOf(event['id']);
    final tables = objectRow(event['tables']);
    List<Doc> table(String name) => tables.containsKey(name)
        ? _rowsOf(tables[name])
        : [
            for (final row in _rowsOf(sharedRules[name]))
              if (row['eventId'] == null ||
                  row['eventId'] == 0 ||
                  intOf(row['eventId']) == id)
                row,
          ];
    final groups = objectRow(event['groups']);
    Map<int, int> points(String name, String groupKey) {
      final groupId = intOf(groups[groupKey] ?? event[groupKey]);
      return {
        for (final row in table(name))
          if (groupId == 0 ||
              row['group'] == null ||
              row['group'] == 0 ||
              intOf(row['group']) == groupId)
            intOf(row['scoreRank']): intOf(row['value']),
      };
    }

    final item = objectRow(event['eventItem']);
    events[id] = GameEvent(
      id: id,
      startAt: _time(event['startAt']),
      endAt: _time(event['endAt']),
      itemId: intOf(item['resourceId'] ?? item['id'] ?? event['eventItemId']),
      musicId: intOf(event['musicId']),
      effects: [
        for (final row
            in event['effects'] is List
                ? _rowsOf(event['effects'])
                : table('MasterEventEffect'))
          EventEffectRow(row),
      ],
      livePoints: points('MasterLiveEventPoint', 'liveEventPointGroup'),
      challengePoints: points(
        'MasterChallengeLiveEventPoint',
        'challengeLiveEventPointGroup',
      ),
      liveRewards: [
        for (final row in table('MasterLiveEventReward')) RewardRow(row),
      ],
      challengeRewards: [
        for (final row in table('MasterChallengeLiveEventReward'))
          RewardRow(row),
      ],
    );
  }

  final crossServer = objectRow(data['crossServer']);
  final challengeMusicRows = crossServer['challengeMusics'] != null
      ? dataRows(crossServer['challengeMusics'])
      : dataRows(objectRow(data['challengeMusicTable'])['rows']);

  return EngineMaster(
    server: '${identity['server'] ?? ''}',
    releaseId: '${identity['releaseId'] ?? ''}',
    params: EngineParams(
      intOf(parameter('music_type_base_bonus_rate'), 500),
      intOf(parameter('music_tag_base_bonus_rate'), 500),
      intOf(parameter('type_link_base_bonus_rate'), 500),
      _ranks['${parameter('live_skip_result_score_rank') ?? 'C'}'.trim()] ?? 3,
    ),
    live: LiveTables(
      adjustment: f(setting('note_score_adjustment_factor', 3)),
      lifeOnus: f(setting('note_score_life_onus_factor', 0.3)),
      lifeBase: setting('life_base', 1000),
      notePercent: {
        for (final row in _rowsOf(liveTools['noteParameters']))
          intOf(row['noteOperateType']): numOf(row['scorePercent']),
      },
      judgePercent: judge,
      combo: combo,
      assistPercent: setting('assist_score_percent', 90),
      damage: damage,
      settings: {
        for (final row in liveSettings) '${row['key']}': '${row['value']}',
      },
      justTypes: {
        for (final row in timings)
          if (intOf(row['noteSimulateJudgement']) == 6)
            intOf(row['noteJudgementType']),
      },
      timingTypes: {for (final row in timings) intOf(row['noteJudgementType'])},
      perfectAfterMs: {
        for (final row in timings)
          if (intOf(row['assistLevel']) == 0 &&
              intOf(row['noteSimulateJudgement']) == 5)
            intOf(row['noteJudgementType']): numOf(
              row['afterMs'] ?? row['after'],
            ),
      },
      afterMs: maxOf(
        timings.map((row) => numOf(row['afterMs'] ?? row['after'])),
        0,
      ),
      phases: {
        for (final row in _rowsOf(reference['effectSettings']))
          intOf(row['skillEffectType']): intOf(row['phase'], 1),
      },
      gekiso: GekisouTables(
        luckBasePoints: [
          for (final row in _rowsOf(liveTools['gekisouLuckBasePoints']))
            (
              category: intOf(row['noteCategory']),
              judgement: intOf(row['noteSimulateJudgement']),
              weight: intOf(row['weight']),
              point: intOf(row['basePoint']),
            ),
        ],
        luckBonusLots: [
          for (final row in _rowsOf(liveTools['gekisouLuckBonusLots']))
            (
              lotType: intOf(row['chanceLotType']),
              result: intOf(row['lotResult']),
              weight: intOf(row['weight']),
            ),
        ],
        rankingBonuses: [
          for (final row in _rowsOf(liveTools['gekisouRankingScoreBonuses']))
            (
              pattern: intOf(row['missionPattern']),
              count: intOf(row['count']),
              rank: intOf(row['rank']),
              percent: intOf(row['scoreBonusPercent']),
            ),
        ],
        gaugeMax: setting('gekisou_luck_gauge_max', 100).toInt(),
        gaugeMaxRush: setting('gekisou_luck_gauge_max_rush', 50).toInt(),
        rushPercent: setting(
          'gekisou_luck_rush_score_bonus_percent',
          0,
        ).toInt(),
      ),
    ),
    characters: characters,
    members: members,
    snaps: snaps,
    memberLevels: _nested(
      progress('memberCardLevels'),
      'group',
      'level',
      (row) => _stat(row, 'performanceRate', 'technicRate', 'visualRate'),
    ),
    memberAwake: _nested(
      progress('memberCardAwake'),
      'group',
      'awakeCount',
      (row) => _stat(row, 'performanceRate', 'technicRate', 'visualRate'),
    ),
    memberRanks: _nested(
      progress('memberCardRanks'),
      'group',
      'rank',
      (row) => MemberRankRow(
        _stat(row, 'performanceRate', 'technicRate', 'visualRate'),
        intOf(row['leaderSkillLevel'], 1),
        intOf(row['musicTypeBonusRate']),
        intOf(row['musicTagBonusRate']),
      ),
    ),
    memberLevelLimits: levelLimits,
    snapLevels: _nested(
      progress('supportCardLevels'),
      'group',
      'level',
      (row) => _stat(row, 'performanceRate', 'technicRate', 'visualRate'),
    ),
    snapRanks: _nested(
      progress('supportCardRanks'),
      'group',
      'rank',
      (row) => SnapRankRow(
        intOf(row['cardTypeLinkBonusRate']),
        intOf(row['limitLevel']),
        [intOf(row['supportSkill01Level']), intOf(row['supportSkill02Level'])],
        [
          intOf(row['gekisouSupportSkill01Level']),
          intOf(row['gekisouSupportSkill02Level']),
        ],
      ),
    ),
    characterRankBonus: [
      for (final row in characterRanks)
        (intOf(row['rank']), intOf(row['bonus'])),
    ]..sort((a, b) => a.$1 - b.$1),
    totalRankBonus: [
      for (final row in progress('characterTotalRanks'))
        (intOf(row['totalRank']), intOf(row['bonus'])),
    ]..sort((a, b) => a.$1 - b.$1),
    maxCharacterRank: maxOf(
      characterRanks.map((row) => intOf(row['rank'])),
      1,
    ).toInt(),
    vipBonus: {
      for (final row in dataRows(objectRow(runtime['vipRankBonuses'])['rows']))
        if (intOf(row['vipBonusType']) == 7)
          intOf(row['vipRank']): intOf(row['value']),
    },
    bandItems: {
      for (final value in objectRow(data['bandItems']).values)
        intOf(objectRow(value)['bandItemId']): BandItem(
          intOf(objectRow(value)['bandId']),
          groupBy([
            for (final row in _rowsOf(objectRow(value)['effects']))
              SkillEffectRow(row),
          ], (row) => row.level),
        ),
    },
    targets: {
      for (final row in _rowsOf(reference['targets']))
        intOf(row['id']): TargetRow(row),
    },
    conditions: {
      for (final row in _rowsOf(reference['conditions']))
        intOf(row['id']): ConditionRow(
          intOf(row['id']),
          intOf(row['conditionType']),
          idsOf(row['conditionTargetIDs']),
          listOf(row['conditionValues']),
          row['isPositive'] != false,
        ),
    },
    conditionSets: conditionSets,
    cumulative: {
      for (final row in _rowsOf(reference['cumulativeConditions']))
        intOf(row['id']): CumulativeRow(
          intOf(row['id']),
          intOf(row['skillCumulativeConditionType'] ?? row['conditionType']),
          idsOf(row['conditionTargetIDs']),
          listOf(row['conditionValues']),
          intOf(row['maxCumulativeCount']),
        ),
    },
    leaderSkills: _skillMap(skills['leader']),
    liveSkills: _skillMap(skills['live']),
    supportSkills: _skillMap(skills['support']),
    gekisoSkills: _gekisoMap(skills['gekiso']),
    gekisoSupportSkills: _gekisoMap(skills['gekisoSupport']),
    liveSkillCategories: _categories(skills['live']),
    gekisoSkillCategories: _categories(skills['gekiso']),
    songs: songs,
    scoreRanks: scoreRanks,
    challengeMusics: [
      for (final row in challengeMusicRows)
        ChallengeMusic(
          intOf(row['id']),
          intOf(row['eventId']),
          intOf(row['liveMusicId']),
          intOf(row['musicType']),
        ),
    ],
    events: events,
    liveChallengePoints: {
      for (final row in dataRows(
        objectRow(data['challengePointTable'])['rows'],
      ))
        intOf(row['scoreRank']): intOf(row['value']),
    },
    boosts: _boostRows(
      _rowsOf(liveTools['liveBoostBonuses']),
      'consumedLiveBoostCount',
    ),
    challengeBoosts: _boostRows(
      _rowsOf(liveTools['challengeBoostBonuses']),
      'consumedChallengePointCount',
    ),
  );
}
