/// Serializable engine requests and their evaluation
/// (`team-builder/engine/api.ts`). Charts come from an injected loader.
library;

import 'dart:math' as math;
import 'dart:convert';
import 'dart:typed_data';

import '../../chart/runtime_chart.dart' show RuntimeChart;
import 'box.dart';
import 'execution.dart';
import 'chart.dart';
import 'full/play.dart' show Accuracy;
import 'full/play.dart' show performer;
import 'gekiso.dart';
import 'gekiso_objective.dart';
import 'gekiso_rewards.dart' hide RewardCutoff;
import 'live.dart';
import 'master.dart';
import 'num.dart';
import 'objectives.dart';
import 'power.dart';
import 'pt_eligibility.dart';
import 'search.dart';
import 'skills.dart';

class SongRef {
  const SongRef(this.songId, this.difficulty);
  factory SongRef.fromJson(Map<String, Object?> json) => SongRef(
    (json['songId'] as num).toInt(),
    (json['difficulty'] as num).toInt(),
  );
  final int songId;
  final int difficulty;
  String get key => '$songId:$difficulty';
  Map<String, Object?> toJson() => {'songId': songId, 'difficulty': difficulty};
  @override
  bool operator ==(Object other) =>
      other is SongRef &&
      other.songId == songId &&
      other.difficulty == difficulty;
  @override
  int get hashCode => Object.hash(songId, difficulty);
}

Map<String, int?> _nullableInts(Object? value) => {
  for (final entry in objectRow(value).entries)
    entry.key: (entry.value as num?)?.toInt(),
};

class PlayerInput {
  const PlayerInput({
    this.characterRanks = const {},
    this.characterTotalRank,
    this.bandItems = const {},
    this.vipRank,
    this.characterMemory = const {},
    this.musicMemory = const {},
  });
  factory PlayerInput.fromJson(Map<String, Object?> json) => PlayerInput(
    characterRanks: _nullableInts(json['characterRanks']),
    characterTotalRank: (json['characterTotalRank'] as num?)?.toInt(),
    bandItems: _nullableInts(json['bandItems']),
    vipRank: (json['vipRank'] as num?)?.toInt(),
    characterMemory: _nullableInts(json['characterMemory']),
    musicMemory: _nullableInts(json['musicMemory']),
  );
  final Map<String, int?> characterRanks;
  final int? characterTotalRank;
  final Map<String, int?> bandItems;
  final int? vipRank;
  final Map<String, int?> characterMemory;
  final Map<String, int?> musicMemory;
  Map<String, Object?> toJson() => {
    'characterRanks': characterRanks,
    'characterTotalRank': characterTotalRank,
    'bandItems': bandItems,
    'vipRank': vipRank,
    'characterMemory': characterMemory,
    'musicMemory': musicMemory,
  };
}

class ConstraintInput {
  const ConstraintInput({
    this.requiredMembers = const [],
    this.excludedMembers = const [],
    this.requiredSnaps = const [],
    this.excludedSnaps = const [],
    this.leader,
    this.bindings = const [],
    this.noSnaps = false,
    this.minBonusPercent,
  });
  factory ConstraintInput.fromJson(Map<String, Object?> json) {
    List<String> strings(Object? value) => [
      for (final item in value as List? ?? const []) '$item',
    ];
    return ConstraintInput(
      requiredMembers: strings(json['requiredMembers']),
      excludedMembers: strings(json['excludedMembers']),
      requiredSnaps: strings(json['requiredSnaps']),
      excludedSnaps: strings(json['excludedSnaps']),
      leader: json['leader'] as String?,
      bindings: [
        for (final pair in json['bindings'] as List? ?? const [])
          ('${(pair as List)[0]}', pair[1] as String?),
      ],
      noSnaps: json['noSnaps'] == true,
      minBonusPercent: (json['minBonusPercent'] as num?)?.toDouble(),
    );
  }
  final List<String> requiredMembers;
  final List<String> excludedMembers;
  final List<String> requiredSnaps;
  final List<String> excludedSnaps;
  final String? leader;
  final List<(String, String?)> bindings;
  final bool noSnaps;
  Map<String, Object?> toJson() => {
    'requiredMembers': requiredMembers,
    'excludedMembers': excludedMembers,
    'requiredSnaps': requiredSnaps,
    'excludedSnaps': excludedSnaps,
    'leader': leader,
    'bindings': [
      for (final (member, snap) in bindings) [member, snap],
    ],
    'noSnaps': noSnaps,
    'minBonusPercent': minBonusPercent,
  };

  /// Event bonus floor in percent.
  final double? minBonusPercent;
}

sealed class Goal {
  const Goal();
  factory Goal.fromJson(Map<String, Object?> json) {
    List<SongRef> songs(Object? value) => [
      for (final song in value as List? ?? const [])
        SongRef.fromJson(objectRow(song)),
    ];
    PlayModel play() => PlayModel.fromJson(objectRow(json['play']));
    Criterion criterion() =>
        Criterion.values.byName('${json['criterion'] ?? 'mean'}');
    return switch (json['kind']) {
      'power' => PowerGoal(
        json['song'] == null ? null : SongRef.fromJson(objectRow(json['song'])),
        (json['challengeEventId'] as num?)?.toInt(),
      ),
      'score' => ScoreGoal(
        songs(json['songs']),
        criterion(),
        play(),
        (json['challengeEventId'] as num?)?.toInt(),
      ),
      'event' => EventGoal(
        measure: '${json['measure']}',
        route: RouteKind.values.byName('${json['route']}'),
        eventId: (json['eventId'] as num).toInt(),
        songs: songs(json['songs']),
        consumption: (json['consumption'] as num).toInt(),
        play: play(),
        ptOnly: json['ranking'] == 'pt-only',
        ranking: json['ranking'] as String?,
        cpExchange: json['cpExchange'] is Map
            ? CpExchange(
                intOf(objectRow(json['cpExchange'])['numerator']),
                intOf(objectRow(json['cpExchange'])['denominator'], 1),
              )
            : null,
        gekiso: json['gekiso'] is Map
            ? (
                just: numOf(objectRow(json['gekiso'])['just']),
                luckSamples: intOf(objectRow(json['gekiso'])['luckSamples'], 1),
              )
            : null,
      ),
      'gekiso' => GekisoGoal(
        songs: songs(json['songs']),
        criterion: criterion(),
        accuracy: Accuracy(
          great: numOf(objectRow(json['accuracy'])['great']),
          just: numOf(objectRow(json['accuracy'])['just'], 1),
          missEvery: intOf(objectRow(json['accuracy'])['missEvery']),
        ),
        rank: intOf(json['rank'], 1),
        seeds: intOf(json['seeds']),
      ),
      'potential' => PotentialGoal(numOf(json['windowSeconds'], 100)),
      'plan' => PlanGoal(
        eventId: (json['eventId'] as num).toInt(),
        normalSongs: songs(json['normalSongs']),
        challengeSongs: songs(json['challengeSongs']),
        boostsPerLive: (json['boostsPerLive'] as num).toInt(),
        boostBudget: (json['boostBudget'] as num).toInt(),
        startingChallengePoints: (json['startingChallengePoints'] as num)
            .toInt(),
        challengePointsPerLive: (json['challengePointsPerLive'] as num).toInt(),
        challengePointsPerPlay: (json['challengePointsPerPlay'] as num?)
            ?.toDouble(),
        play: play(),
      ),
      final kind => throw UnsupportedError('goal:$kind'),
    };
  }
}

class PowerGoal extends Goal {
  const PowerGoal(this.song, this.challengeEventId);
  final SongRef? song;
  final int? challengeEventId;
}

class ScoreGoal extends Goal {
  const ScoreGoal(this.songs, this.criterion, this.play, this.challengeEventId);
  final List<SongRef> songs;
  final Criterion criterion;
  final PlayModel play;
  final int? challengeEventId;
}

class EventGoal extends Goal {
  const EventGoal({
    required this.measure,
    required this.route,
    required this.eventId,
    required this.songs,
    required this.consumption,
    required this.play,
    this.ptOnly = false,
    this.ranking,
    this.cpExchange,
    this.gekiso,
  });

  /// Strict reward recommendation: exact inputs, AP solo/challenge lives,
  /// reward-only ordering (`ranking: "pt-only"`).
  final bool ptOnly;
  final String? ranking;
  bool get primaryOnly => ptOnly || ranking != null;

  /// Best challenge payout per CP for this objective (solo trial only).
  final CpExchange? cpExchange;

  /// Non-challenge Gekisou rewards, using per-outcome settlement.
  final ({double just, int luckSamples})? gekiso;

  EventGoal copyWith({
    String? measure,
    RouteKind? route,
    List<SongRef>? songs,
    int? consumption,
    CpExchange? cpExchange,
    bool dropGekiso = false,
  }) => EventGoal(
    measure: measure ?? this.measure,
    route: route ?? this.route,
    eventId: eventId,
    songs: songs ?? this.songs,
    consumption: consumption ?? this.consumption,
    play: play,
    ptOnly: ptOnly,
    ranking: ranking,
    cpExchange: cpExchange ?? this.cpExchange,
    gekiso: dropGekiso ? null : gekiso,
  );

  Map<String, Object?> toJson() => {
    'kind': 'event',
    'measure': measure,
    'route': route.name,
    'eventId': eventId,
    'songs': [for (final song in songs) song.toJson()],
    'consumption': consumption,
    'play': play.toJson(),
    if (primaryOnly) 'ranking': ptOnly ? 'pt-only' : ranking,
    if (cpExchange case final cp?)
      'cpExchange': {'numerator': cp.numerator, 'denominator': cp.denominator},
    if (gekiso case final g?)
      'gekiso': {'just': g.just, 'luckSamples': g.luckSamples, 'rank': 1},
  };

  /// `points`, `items` or `challenge-points`.
  final String measure;
  final RouteKind route;
  final int eventId;
  final List<SongRef> songs;

  /// Boosts per normal live (0–10) or challenge points per challenge live.
  final int consumption;
  final PlayModel play;
}

class GekisoGoal extends Goal {
  const GekisoGoal({
    required this.songs,
    required this.criterion,
    required this.accuracy,
    this.rank = 1,
    this.seeds = 0,
  });
  final List<SongRef> songs;
  final Criterion criterion;

  /// Share of notes hit Great, and of the Just-eligible rest hit Just.
  final Accuracy accuracy;

  /// Assumed placement in every range (1 for solo Mission lives).
  final int rank;

  /// Luck ranges: 0 takes the exact nominal lottery expectation; n > 0
  /// averages n native lottery seeds instead.
  final int seeds;
}

class PotentialGoal extends Goal {
  const PotentialGoal(this.windowSeconds);
  final double windowSeconds;
}

class PlanGoal extends Goal {
  const PlanGoal({
    required this.eventId,
    required this.normalSongs,
    required this.challengeSongs,
    required this.boostsPerLive,
    required this.boostBudget,
    required this.startingChallengePoints,
    required this.challengePointsPerLive,
    this.challengePointsPerPlay,
    required this.play,
  });
  final int eventId;
  final List<SongRef> normalSongs;
  final List<SongRef> challengeSongs;
  final int boostsPerLive;
  final int boostBudget;
  final int startingChallengePoints;
  final int challengePointsPerLive;
  final double? challengePointsPerPlay;
  final PlayModel play;
}

Map<String, Object?> goalJson(Goal goal) => switch (goal) {
  EventGoal() => goal.toJson(),
  PowerGoal(:final song, :final challengeEventId) => {
    'kind': 'power',
    'song': song?.toJson(),
    'challengeEventId': challengeEventId,
  },
  ScoreGoal(
    :final songs,
    :final criterion,
    :final play,
    :final challengeEventId,
  ) =>
    {
      'kind': 'score',
      'songs': [for (final song in songs) song.toJson()],
      'criterion': criterion.name,
      'play': play.toJson(),
      'challengeEventId': challengeEventId,
    },
  GekisoGoal(
    :final songs,
    :final criterion,
    :final accuracy,
    :final rank,
    :final seeds,
  ) =>
    {
      'kind': 'gekiso',
      'songs': [for (final song in songs) song.toJson()],
      'criterion': criterion.name,
      'accuracy': {
        'great': accuracy.great,
        'just': accuracy.just,
        'missEvery': accuracy.missEvery,
      },
      'rank': rank,
      'seeds': seeds,
    },
  PotentialGoal(:final windowSeconds) => {
    'kind': 'potential',
    'windowSeconds': windowSeconds,
  },
  PlanGoal(
    :final eventId,
    :final normalSongs,
    :final challengeSongs,
    :final boostsPerLive,
    :final boostBudget,
    :final startingChallengePoints,
    :final challengePointsPerLive,
    :final challengePointsPerPlay,
    :final play,
  ) =>
    {
      'kind': 'plan',
      'eventId': eventId,
      'normalSongs': [for (final song in normalSongs) song.toJson()],
      'challengeSongs': [for (final song in challengeSongs) song.toJson()],
      'boostsPerLive': boostsPerLive,
      'boostBudget': boostBudget,
      'startingChallengePoints': startingChallengePoints,
      'challengePointsPerLive': challengePointsPerLive,
      'challengePointsPerPlay': ?challengePointsPerPlay,
      'play': play.toJson(),
    },
};

class EngineRequest {
  EngineRequest({
    required this.members,
    required this.snaps,
    this.player = const PlayerInput(),
    this.unknownPolicy = UnknownPolicy.max,
    required this.goal,
    this.constraints = const ConstraintInput(),
    this.k = 1,
    this.timeLimitMs,
    this.rewardCutoff,
    this.shard,
    this.floors,
    this.noFloor = false,
    this.deadline,
    this.requestId,
    this.contextKey,
    this.seeds = const [],
    this.completed = const [],
    this.cutoff,
    this.seedOnly = false,
    this.seeded = false,
    this.rewardPhase,
  });
  factory EngineRequest.fromJson(Map<String, Object?> json) => EngineRequest(
    members: [
      for (final row in json['members'] as List)
        MemberInput.fromJson(objectRow(row)),
    ],
    snaps: [
      for (final row in json['snaps'] as List)
        SnapInput.fromJson(objectRow(row)),
    ],
    player: PlayerInput.fromJson(objectRow(json['player'])),
    unknownPolicy: UnknownPolicy.values.byName(
      '${json['unknownPolicy'] ?? 'max'}',
    ),
    goal: Goal.fromJson(objectRow(json['goal'])),
    constraints: ConstraintInput.fromJson(objectRow(json['constraints'])),
    k: (json['k'] as num?)?.toInt() ?? 1,
    timeLimitMs: (json['timeLimitMs'] as num?)?.toDouble(),
    rewardCutoff: (json['rewardCutoff'] as num?)?.toDouble(),
    shard: json['shard'] is Map
        ? (
            index: intOf(objectRow(json['shard'])['index']),
            count: intOf(objectRow(json['shard'])['count']),
          )
        : null,
    floors: json['floors'] is Map
        ? {
            for (final MapEntry(:key, :value) in objectRow(
              json['floors'],
            ).entries)
              key: (value as num).toDouble(),
          }
        : null,
    noFloor: json['noFloor'] == true,
    deadline: (json['deadline'] as num?)?.toDouble(),
    requestId: json['requestId'] as String?,
    contextKey: json['contextKey'] as String?,
    seeds: [
      for (final hit in json['seeds'] as List? ?? const [])
        EngineHit.fromJson(objectRow(hit)),
    ],
    completed: [
      for (final result in json['completed'] as List? ?? const [])
        SongResult.fromJson(objectRow(result)),
    ],
    cutoff: json['cutoff'] is Map
        ? RewardCutoff.fromJson(objectRow(json['cutoff']))
        : null,
    seedOnly: json['seedOnly'] == true,
    seeded: json['seeded'] == true,
    rewardPhase: json['rewardPhase'] is Map
        ? objectRow(json['rewardPhase'])
        : null,
  );

  /// Other songs' Top-K key. Only a pt-only k=1 request may prove this song
  /// strictly below the cutoff.
  final double? rewardCutoff;
  final List<MemberInput> members;
  final List<SnapInput> snaps;
  final PlayerInput player;
  final UnknownPolicy unknownPolicy;
  final Goal goal;
  final ConstraintInput constraints;
  final int k;
  final double? timeLimitMs;

  /// One leader shard of a search split over several isolates: each team
  /// has one leader, so the union of the shards' top k is the exact top k.
  final ({int index, int count})? shard;

  /// Known lower bounds of each song's k-th key (`songId:difficulty`), from
  /// teams other shards already found.
  final Map<String, double>? floors;

  /// Searches without the aspiration floor (after one admitted too few).
  final bool noFloor;
  final double? deadline;
  final String? requestId;
  final String? contextKey;
  final List<EngineHit> seeds;
  final List<SongResult> completed;
  final RewardCutoff? cutoff;
  final bool seedOnly;
  final bool seeded;
  final Doc? rewardPhase;

  /// The same request for one shard, a time limit, other floors or songs.
  EngineRequest copyWith({
    Goal? goal,
    double? timeLimitMs,
    bool keepTimeLimit = true,
    ({int index, int count})? shard,
    Map<String, double>? floors,
    bool? noFloor,
    double? deadline,
    String? requestId,
    String? contextKey,
    List<EngineHit>? seeds,
    List<SongResult>? completed,
    RewardCutoff? cutoff,
    bool? seedOnly,
    bool? seeded,
    Doc? rewardPhase,
  }) => EngineRequest(
    members: members,
    snaps: snaps,
    player: player,
    unknownPolicy: unknownPolicy,
    goal: goal ?? this.goal,
    constraints: constraints,
    k: k,
    timeLimitMs: timeLimitMs ?? (keepTimeLimit ? this.timeLimitMs : null),
    rewardCutoff: rewardCutoff,
    shard: shard ?? this.shard,
    floors: floors ?? this.floors,
    noFloor: noFloor ?? this.noFloor,
    deadline: deadline ?? this.deadline,
    requestId: requestId ?? this.requestId,
    contextKey: contextKey ?? this.contextKey,
    seeds: seeds ?? this.seeds,
    completed: completed ?? this.completed,
    cutoff: cutoff ?? this.cutoff,
    seedOnly: seedOnly ?? this.seedOnly,
    seeded: seeded ?? this.seeded,
    rewardPhase: rewardPhase ?? this.rewardPhase,
  );

  EngineRequest withGoal(
    Goal goal,
    double? timeLimitMs, {
    double? rewardCutoff,
  }) => EngineRequest(
    members: members,
    snaps: snaps,
    player: player,
    unknownPolicy: unknownPolicy,
    goal: goal,
    constraints: constraints,
    k: k,
    timeLimitMs: timeLimitMs,
    rewardCutoff: rewardCutoff,
  );

  /// Event requests only (the reward recommendation keeps them).
  Map<String, Object?> toJson() => {
    'members': [for (final row in members) row.toJson()],
    'snaps': [for (final row in snaps) row.toJson()],
    'player': player.toJson(),
    'unknownPolicy': unknownPolicy.name,
    'goal': goalJson(goal),
    'constraints': constraints.toJson(),
    'k': k,
    'timeLimitMs': timeLimitMs?.isFinite == true ? timeLimitMs : null,
    if (deadline?.isFinite == true) 'deadline': deadline,
    if (requestId != null) 'requestId': requestId,
    if (contextKey != null) 'contextKey': contextKey,
    'seeds': [for (final hit in seeds) hit.toJson()],
    'completed': [for (final result in completed) result.toJson()],
    if (cutoff != null) 'cutoff': cutoff!.toJson(),
    'seedOnly': seedOnly,
    'seeded': seeded,
    if (rewardPhase != null) 'rewardPhase': rewardPhase,
    'noFloor': noFloor,
    if (rewardCutoff != null) 'rewardCutoff': rewardCutoff,
    'shard': shard == null
        ? null
        : {'index': shard!.index, 'count': shard!.count},
    'floors': floors,
  };
}

class HitScore {
  HitScore({
    required this.mean,
    required this.min,
    required this.max,
    required this.median,
    required this.worstOrder,
    required this.bestOrder,
    required this.orders,
    required this.ranks,
    this.rangeScores,
  });
  factory HitScore.fromJson(Map<String, Object?> json) => HitScore(
    mean: numOf(json['mean']),
    min: numOf(json['min']),
    max: numOf(json['max']),
    median: numOf(json['median']),
    worstOrder: [
      for (final key in json['worstOrder'] as List? ?? const []) '$key',
    ],
    bestOrder: [
      for (final key in json['bestOrder'] as List? ?? const []) '$key',
    ],
    orders: intListOf(json['orders']),
    rangeScores: (json['rangeScores'] as List?)?.map(numOf).toList(),
    ranks: {
      for (final entry in objectRow(json['ranks']).entries)
        int.parse(entry.key): intOf(entry.value),
    },
  );
  final double mean;
  final double min;
  final double max;
  final double median;

  /// Member keys at each chart skill event, for the worst and best orders.
  final List<String> worstOrder;
  final List<String> bestOrder;

  /// Score of every skill order, indexed like [orders].
  final List<int> orders;
  final Map<int, int> ranks;
  final List<double>? rangeScores;
  Map<String, Object?> toJson() => {
    'mean': mean,
    'min': min,
    'max': max,
    'median': median,
    'worstOrder': worstOrder,
    'bestOrder': bestOrder,
    'orders': orders,
    'rangeScores': ?rangeScores,
    'ranks': {for (final e in ranks.entries) '${e.key}': e.value},
  };
}

class HitEvent {
  HitEvent({
    required this.mean,
    required this.bonusPercent,
    required this.challengePoints,
    required this.perPlayMin,
    required this.perPlayMax,
    this.rewardSum,
    this.comparisonSum,
    this.orders,
    this.directMean,
    this.convertedMean,
    this.otherMean,
  });
  factory HitEvent.fromJson(Map<String, Object?> json) => HitEvent(
    mean: numOf(json['mean']),
    bonusPercent: numOf(json['bonusPercent']),
    challengePoints: numOf(json['challengePoints']),
    perPlayMin: numOf(json['perPlayMin']),
    perPlayMax: numOf(json['perPlayMax']),
    rewardSum: (json['rewardSum'] as num?)?.toDouble(),
    comparisonSum: (json['comparisonSum'] as num?)?.toDouble(),
    orders: (json['orders'] as num?)?.toInt(),
    directMean: (json['directMean'] as num?)?.toDouble(),
    convertedMean: (json['convertedMean'] as num?)?.toDouble(),
    otherMean: (json['otherMean'] as num?)?.toDouble(),
  );

  /// Exact order sums of the strict trial; mean includes CP conversion.
  final double? rewardSum;
  final double? comparisonSum;
  final int? orders;
  final double? directMean;
  final double? convertedMean;
  final double? otherMean;
  final double mean;
  final double bonusPercent;
  final double challengePoints;
  final double perPlayMin;
  final double perPlayMax;
  Map<String, Object?> toJson() => {
    'mean': mean,
    'bonusPercent': bonusPercent,
    'challengePoints': challengePoints,
    'perPlayMin': perPlayMin,
    'perPlayMax': perPlayMax,
    'rewardSum': ?rewardSum,
    'comparisonSum': ?comparisonSum,
    'orders': ?orders,
    'directMean': ?directMean,
    'convertedMean': ?convertedMean,
    'otherMean': ?otherMean,
  };
}

class EngineHit {
  EngineHit({
    required this.song,
    required this.members,
    required this.snaps,
    required this.power,
    required this.slotPowers,
    required this.key,
  });
  factory EngineHit.fromJson(Map<String, Object?> json) =>
      EngineHit(
          song: json['song'] is Map
              ? SongRef.fromJson(objectRow(json['song']))
              : null,
          members: [for (final key in json['members'] as List) '$key'],
          snaps: [for (final key in json['snaps'] as List) key as String?],
          power: intOf(json['power']),
          slotPowers: intListOf(json['slotPowers']),
          key: numOf(json['key']),
        )
        ..score = json['score'] is Map
            ? HitScore.fromJson(objectRow(json['score']))
            : null
        ..skipScore = (json['skipScore'] as num?)?.toInt()
        ..comboBonus = (json['comboBonus'] as num?)?.toInt()
        ..event = json['event'] is Map
            ? HitEvent.fromJson(objectRow(json['event']))
            : null
        ..potential = json['potential'] is Map
            ? PotentialDetail(
                numOf(objectRow(json['potential'])['value']),
                numOf(objectRow(json['potential'])['area']),
              )
            : null
        ..gekiso = json['gekiso'] is Map ? objectRow(json['gekiso']) : null;
  final SongRef? song;

  /// Leader first.
  final List<String> members;
  final List<String?> snaps;
  final int power;
  final List<int> slotPowers;
  final double key;
  HitScore? score;
  int? skipScore;
  int? comboBonus;
  HitEvent? event;
  PotentialDetail? potential;
  Map<String, Object?>? gekiso;

  Map<String, Object?> toJson() => {
    'song': song?.toJson(),
    'members': members,
    'snaps': snaps,
    'power': power,
    'slotPowers': slotPowers,
    'key': key,
    'comboBonus': ?comboBonus,
    'score': score?.toJson(),
    'skipScore': skipScore,
    'event': event?.toJson(),
    if (gekiso != null) 'gekiso': gekiso,
    'potential': potential == null
        ? null
        : {'value': potential!.potential, 'area': potential!.area},
  };
}

class SongResult {
  SongResult({
    required this.song,
    required this.hits,
    required this.proven,
    required this.bound,
    required this.stats,
    this.excludedBelow,
    this.floor,
    this.exclusion,
    this.rewardPhase,
  });
  factory SongResult.fromJson(Map<String, Object?> json) => SongResult(
    song: json['song'] is Map
        ? SongRef.fromJson(objectRow(json['song']))
        : null,
    hits: [
      for (final hit in json['hits'] as List? ?? const [])
        EngineHit.fromJson(objectRow(hit)),
    ],
    proven: json['proven'] == true,
    rewardPhase: json['rewardPhase'] as String?,
    bound: (json['bound'] as num?)?.toDouble(),
    stats: SearchStats.fromJson(objectRow(json['stats'])),
    floor: (json['floor'] as num?)?.toDouble(),
    excludedBelow: (json['excludedBelow'] as num?)?.toDouble(),
    exclusion: json['exclusion'] is Map
        ? RewardCutoff.fromJson(objectRow(json['exclusion']))
        : null,
  );
  final SongRef? song;
  List<EngineHit> hits;
  bool proven;
  final String? rewardPhase;
  double? bound;
  final SearchStats stats;

  /// Exhaustive proof that no team in this scope reaches this key.
  double? excludedBelow;
  RewardCutoff? exclusion;

  /// The aspiration floor a shard searched under: fewer than k teams at or
  /// above it means the merged search must run again without one.
  double? floor;
  Map<String, Object?> toJson() => {
    'song': song?.toJson(),
    'proven': proven,
    if (rewardPhase != null) 'rewardPhase': rewardPhase,
    'bound': bound?.isFinite == true ? bound : null,
    'exclusion': exclusion?.toJson(),
    'excludedBelow': ?excludedBelow,
    'floor': ?floor,
    'stats': stats.toJson(),
    'hits': [for (final hit in hits) hit.toJson()],
  };
}

class PlanSummary {
  PlanSummary({
    required this.normal,
    required this.challenge,
    required this.normalLives,
    required this.challengeLives,
    required this.challengePointsEarned,
    required this.leftoverChallengePoints,
    required this.eventPoints,
    required this.perBoost,
  });
  factory PlanSummary.fromJson(Map<String, Object?> json) => PlanSummary(
    normal: json['normal'] is Map
        ? EngineHit.fromJson(objectRow(json['normal']))
        : null,
    challenge: json['challenge'] is Map
        ? EngineHit.fromJson(objectRow(json['challenge']))
        : null,
    normalLives: intOf(json['normalLives']),
    challengeLives: intOf(json['challengeLives']),
    challengePointsEarned: intOf(json['challengePointsEarned']),
    leftoverChallengePoints: intOf(json['leftoverChallengePoints']),
    eventPoints: numOf(json['eventPoints']),
    perBoost: numOf(json['perBoost']),
  );
  final EngineHit? normal;
  final EngineHit? challenge;
  final int normalLives;
  final int challengeLives;
  final int challengePointsEarned;
  final int leftoverChallengePoints;
  final double eventPoints;

  /// Event points per boost spent, over the whole cycle.
  final double perBoost;
  Map<String, Object?> toJson() => {
    'normal': normal?.toJson(),
    'challenge': challenge?.toJson(),
    'normalLives': normalLives,
    'challengeLives': challengeLives,
    'challengePointsEarned': challengePointsEarned,
    'leftoverChallengePoints': leftoverChallengePoints,
    'eventPoints': eventPoints,
    'perBoost': perBoost,
  };
}

class EngineResponse {
  EngineResponse({
    required this.results,
    required this.overall,
    required this.unknownCards,
    required this.elapsedMs,
    this.plan,
    this.stopReason,
    this.error,
    this.timing,
  });
  factory EngineResponse.fromJson(Map<String, Object?> json) => EngineResponse(
    results: [
      for (final result in json['results'] as List? ?? const [])
        SongResult.fromJson(objectRow(result)),
    ],
    overall: [
      for (final hit in json['overall'] as List? ?? const [])
        EngineHit.fromJson(objectRow(hit)),
    ],
    unknownCards: [
      for (final key in json['unknownCards'] as List? ?? const []) '$key',
    ],
    elapsedMs: numOf(json['elapsedMs']),
    plan: json['plan'] is Map
        ? PlanSummary.fromJson(objectRow(json['plan']))
        : null,
    stopReason: json['stopReason'] as String?,
    error: json['error'] as String?,
    timing: json['timing'] is Map
        ? EngineTiming.fromJson(objectRow(json['timing']))
        : null,
  );
  final PlanSummary? plan;
  String? stopReason;
  String? error;
  EngineTiming? timing;
  final List<SongResult> results;

  /// Best (song, team) pairs over every song, distinct by song + member set.
  final List<EngineHit> overall;
  final List<String> unknownCards;
  final double elapsedMs;
  Map<String, Object?> toJson() => {
    'results': [for (final result in results) result.toJson()],
    'overall': [for (final hit in overall) hit.toJson()],
    'unknownCards': unknownCards,
    'elapsedMs': elapsedMs,
    if (plan != null) 'plan': plan!.toJson(),
    'stopReason': stopReason,
    'error': error,
    'timing': timing?.toJson(),
  };
}

typedef ChartLoader = Future<RuntimeChart> Function(SongRef song);

/// Compiled and prepared charts, keeping only a few recent ones.
class ChartCache {
  ChartCache(this.master, this.load);
  final EngineMaster master;
  final ChartLoader load;
  final _charts = <SongRef, Future<CompiledChart>>{};
  final _prepared = Expando<PreparedLive>();
  final _gekiso = <String, Future<GekisoChart>>{};

  void _retryFailed<K, V>(Map<K, Future<V>> cache, K key, Future<V> pending) {
    pending.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        if (identical(cache[key], pending)) cache.remove(key);
      },
    );
  }

  /// The Gekisou chart of a song at a stated accuracy and assumed range rank.
  Future<GekisoChart> gekiso(SongRef ref, Accuracy accuracy, int rank) {
    final key =
        '${ref.key}:${accuracy.great}:${accuracy.just}:${accuracy.missEvery}:$rank';
    var value = _gekiso.remove(key);
    if (value == null) {
      final song = master.songs[ref.songId];
      final difficulty = song?.difficulties
          .where((item) => item.difficulty == ref.difficulty)
          .firstOrNull;
      if (song == null || difficulty == null) {
        return Future.error(RangeError('unknown-chart:${ref.key}'));
      }
      value = source(ref).then(
        (source) => gekisoChart(
          master,
          source,
          difficulty.playLevel,
          song.gekisoMissions,
          accuracy,
          rank,
        ),
      );
    }
    _gekiso[key] = value;
    _retryFailed(_gekiso, key, value);
    if (_gekiso.length > 4) _gekiso.remove(_gekiso.keys.first);
    return value;
  }

  final _sources = <SongRef, Future<RuntimeChart>>{};

  /// The converted chart file, kept for the few most recent songs.
  Future<RuntimeChart> source(SongRef ref) {
    final value = _sources.remove(ref) ?? load(ref);
    _sources[ref] = value;
    _retryFailed(_sources, ref, value);
    if (_sources.length > 4) _sources.remove(_sources.keys.first);
    return value;
  }

  Future<CompiledChart> chart(SongRef ref) {
    var value = _charts.remove(ref);
    if (value == null) {
      final song = master.songs[ref.songId];
      final difficulty = song?.difficulties
          .where((item) => item.difficulty == ref.difficulty)
          .firstOrNull;
      if (song == null || difficulty == null) {
        return Future.error(RangeError('unknown-chart:${ref.key}'));
      }
      value = source(ref)
          .then((source) => compileChart(master, song, difficulty, source));
      final pending = value;
      pending.catchError((Object _) {
        if (identical(_charts[ref], pending)) _charts.remove(ref);
        return pending;
      });
    }
    _charts[ref] = value;
    _retryFailed(_charts, ref, value);
    if (_charts.length > 4) _charts.remove(_charts.keys.first);
    return value;
  }

  PreparedLive live(CompiledChart chart) =>
      _prepared[chart] ??= prepareLive(master, chart);
}

PlayerState playerState(EngineMaster master, PlayerInput input) {
  final ranks = <int, int>{
    for (final entry in input.characterRanks.entries)
      if ((entry.value ?? 0) != 0) int.parse(entry.key): entry.value!,
  };
  final total =
      input.characterTotalRank ??
      master.characters.keys.fold<int>(0, (sum, id) => sum + (ranks[id] ?? 1));
  Map<int, int> nonZero(Map<String, int?> record) => {
    for (final entry in record.entries)
      if ((entry.value ?? 0) != 0) int.parse(entry.key): entry.value!,
  };
  return PlayerState(
    characterRanks: ranks,
    totalRank: total,
    bandItems: nonZero(input.bandItems),
    vipRank: input.vipRank ?? 1,
    characterMemory: nonZero(input.characterMemory),
    musicMemory: nonZero(input.musicMemory),
  );
}

/// Song view of a chart; a challenge song uses its own nonzero music type.
MusicView musicView(EngineMaster master, int songId, int? challengeEventId) {
  final song = master.songs[songId]!;
  var musicType = song.musicType;
  if (challengeEventId != null) {
    final challenge = master.challengeMusics
        .where(
          (row) => row.eventId == challengeEventId && row.liveMusicId == songId,
        )
        .firstOrNull;
    if ((challenge?.musicType ?? 0) != 0) musicType = challenge!.musicType;
  }
  return MusicView(musicType, song.bestTags, songId);
}

const liveBoostCosts = [0, 1, 2, 3, 4, 5, 10];

EventRoute eventRoute(
  EngineMaster master,
  int eventId,
  RouteKind route,
  int consumption,
) {
  final event = master.events[eventId];
  if (event == null) throw RangeError('unknown-event:$eventId');
  final challenge =
      route == RouteKind.challenge ||
      (route == RouteKind.skip && consumption > 10);
  if (!challenge && !liveBoostCosts.contains(consumption)) {
    throw StateError('unsupported-live-boost-cost');
  }
  final table = challenge ? master.challengeBoosts : master.boosts;
  final row = table.where((item) => item.consumed == consumption).firstOrNull;
  final rate = challenge
      ? row?.eventPointRate ?? 1
      : consumption < 1
      ? 1.0
      : row?.eventPointRate ?? 1;
  final rewardRate = challenge
      ? row?.rewardRate ?? 1
      : consumption < 1
      ? 1.0
      : row?.rewardRate ?? 1;
  return EventRoute(
    kind: route,
    rate: rate,
    rewardRate: rewardRate,
    points: challenge ? event.challengePoints : event.livePoints,
    rewards: challenge ? event.challengeRewards : event.liveRewards,
    itemId: event.itemId,
    challengePoints: master.liveChallengePoints,
    effects: event.effects,
  );
}

Constraints constraintsOf(
  ConstraintInput input,
  List<MemberState> members,
  List<SnapState> snaps,
) {
  final memberIndex = {
    for (final (index, member) in members.indexed) member.key: index,
  };
  final snapIndex = {
    for (final (index, snap) in snaps.indexed) snap.key: index,
  };
  List<int> ids(List<String> keys, Map<String, int> index) => [
    for (final key in keys) ?index[key],
  ];
  final bindings = <int, int>{};
  for (final (member, snap) in input.bindings) {
    final i = memberIndex[member];
    if (i == null) continue;
    if (snap == null) {
      bindings[i] = -1;
    } else if (snapIndex[snap] case final j?) {
      bindings[i] = j;
    }
  }
  return Constraints(
    requiredMembers: ids(input.requiredMembers, memberIndex),
    excludedMembers: ids(input.excludedMembers, memberIndex),
    requiredSnaps: ids(input.requiredSnaps, snapIndex),
    excludedSnaps: ids(input.excludedSnaps, snapIndex),
    leader: input.leader != null ? (memberIndex[input.leader] ?? -1) : null,
    bindings: bindings,
    noSnaps: input.noSnaps,
    minBonus: input.minBonusPercent == null
        ? null
        : jsRound(input.minBonusPercent! * 100).toDouble(),
  );
}

double _median(Float64List values) {
  final sorted = Float64List.fromList(values)..sort();
  return (sorted[59] + sorted[60]) / 2;
}

HitScore scoreSummary(
  OrderScores scores,
  CompiledChart chart,
  Team team,
  List<MemberState> members, [
  bool battle = false,
]) {
  List<String> keysOf(List<int> order) => [
    for (final slot in order) members[team.members[slot]].key,
  ];
  final ranks = <int, int>{};
  for (final value in scores.scores) {
    final rank = battle ? battleRank(chart, value) : scoreRank(chart, value);
    ranks[rank] = (ranks[rank] ?? 0) + 1;
  }
  return HitScore(
    mean: scores.mean,
    min: scores.min,
    max: scores.max,
    median: _median(scores.scores),
    worstOrder: keysOf(orders[scores.minOrder]),
    bestOrder: keysOf(orders[scores.maxOrder]),
    orders: [for (final score in scores.scores) jsRound(score)],
    ranks: ranks,
  );
}

/// Keep the best mean for each member set when a tie pass reaches its budget.
List<SearchHit<D>> _scoreTiedHits<D>(
  List<SearchHit<D>> original,
  List<SearchHit<D>> reranked,
  double target,
  int k,
  double Function(D detail) mean,
) => _mergeRewardCandidates(
  [
    for (final hit in original)
      if (hit.key == target) hit,
  ],
  reranked,
  target,
  k,
  mean,
);

List<SearchHit<D>> _mergeRewardCandidates<D>(
  List<SearchHit<D>> original,
  List<SearchHit<D>> reranked,
  double target,
  int k,
  double Function(D detail) mean,
) {
  final hits = [
    ...original,
    for (final hit in reranked)
      if (hit.key >= 0)
        SearchHit(
          hit.team,
          hit.power,
          hit.slotPowers,
          hit.totals,
          target,
          hit.detail,
        ),
  ];
  hits.sort((a, b) {
    final reward = b.key.compareTo(a.key);
    if (reward != 0) return reward;
    final score = mean(b.detail).compareTo(mean(a.detail));
    return score != 0
        ? score
        : jsonEncode([a.team.members, a.team.snaps])
              .compareTo(jsonEncode([b.team.members, b.team.snaps]));
  });
  final seen = <String>{};
  return [
    for (final hit in hits)
      if (seen.add(([...hit.team.members]..sort()).join(',')))
        SearchHit(
          hit.team,
          hit.power,
          hit.slotPowers,
          hit.totals,
          hit.key,
          hit.detail,
        ),
  ].take(k).toList();
}

double _rewardMean(Object? detail) => switch (detail) {
  EventDetail() => detail.live?.scores.mean ?? 0,
  GekisoRewardDetail() => detail.scores.mean,
  _ => 0,
};

/// Higher key first, then the other reward, then mean score.
int compareHits(EngineHit a, EngineHit b) {
  var d = b.key.compareTo(a.key);
  if (d != 0) return d;
  d = (b.event?.otherMean ?? 0).compareTo(a.event?.otherMean ?? 0);
  if (d != 0) return d;
  d = (b.score?.mean ?? 0).compareTo(a.score?.mean ?? 0);
  if (d != 0) return d;
  d = (a.song?.songId ?? 0).compareTo(b.song?.songId ?? 0);
  if (d != 0) return d;
  d = (a.song?.difficulty ?? 0).compareTo(b.song?.difficulty ?? 0);
  if (d != 0) return d;
  return jsonEncode([a.members, a.snaps])
      .compareTo(jsonEncode([b.members, b.snaps]));
}

List<EngineHit> _overall(List<SongResult> results, int k) => stableSorted([
  for (final result in results) ...result.hits,
], compareHits).take(k).toList();

typedef Progress = void Function(int done, int total);

final _eventPrep = <String, ({List<Team> seeds, double? aspiration})>{};
final _scoreCaps = <String, double>{};

/// Runs a request. [cancelled] stops every search early (results stay exact
/// but unproven).
Future<EngineResponse> runEngine(
  EngineMaster master,
  ChartCache charts,
  EngineRequest request, {
  Progress? onProgress,
  void Function(EngineSnapshot)? onSnapshot,
  bool Function()? cancelled,
  String? fingerprint,
}) async {
  final clock = Stopwatch()..start();
  double now() => clock.elapsedMicroseconds / 1000;
  final deadline = deadlineOf(request);
  request = request.copyWith(deadline: deadline);
  final goal = request.goal;
  final cutoff = request.cutoff;
  if (cutoff != null &&
      (goal is! EventGoal ||
          !goal.primaryOnly ||
          request.k != 1 ||
          cutoff.contextKey != request.contextKey ||
          !cutoff.key.isFinite)) {
    throw StateError('invalid-reward-cutoff');
  }
  final ptTrial = goal is EventGoal && goal.ptOnly;
  final rewardCutoff = request.rewardCutoff;
  if (rewardCutoff != null &&
      (!ptTrial || request.k != 1 || !rewardCutoff.isFinite)) {
    throw StateError('invalid-reward-cutoff');
  }
  if (ptTrial) {
    final issues = validatePtRequest(master, request);
    if (issues.isNotEmpty) {
      throw StateError('pt-input:${[for (final i in issues) i.key].join(',')}');
    }
  }
  if (goal is PlanGoal) {
    return _runPlan(
      master,
      charts,
      request,
      goal,
      clock,
      onProgress,
      cancelled,
      onSnapshot,
    );
  }
  final box = resolveBox(
    master,
    request.members,
    request.snaps,
    request.unknownPolicy,
  );
  final members = box.members, snaps = box.snaps;
  final player = playerState(master, request.player);
  final constraints = constraintsOf(request.constraints, members, snaps);
  final shared = Shared(master, members, snaps);
  final results = <SongResult>[];
  EngineHit toHit(SongRef? song, SearchHit<Object?> hit, [double? key]) =>
      EngineHit(
        song: song,
        members: [for (final i in hit.team.members) members[i].key],
        snaps: [for (final j in hit.team.snaps) j < 0 ? null : snaps[j].key],
        power: hit.power,
        slotPowers: hit.slotPowers,
        key: key ?? hit.key,
      );
  Map<String, Object?> gekisoMeta(GekisoRewardDetail detail) => {
    'just': {
      'eligible': detail.just.eligible,
      'baselineHits': detail.just.baselineHits,
      'baselineRate': detail.just.baselineRate,
      'effectiveRate': detail.just.effectiveRate,
      'effectiveHits': detail.just.effectiveHits,
      'convertedHits': detail.just.convertedHits,
    },
    'luckSamples': detail.luckSamples,
    'sampled': detail.sampled,
    'rank': 1,
  };
  final songs = switch (goal) {
    PowerGoal(:final song) => <SongRef?>[song],
    PotentialGoal() => <SongRef?>[null],
    EventGoal(route: RouteKind.skip, songs: final s) when s.isEmpty =>
      <SongRef?>[null],
    EventGoal(:final songs) => <SongRef?>[...songs],
    ScoreGoal(:final songs) => <SongRef?>[...songs],
    GekisoGoal(:final songs) => <SongRef?>[...songs],
    PlanGoal() => <SongRef?>[],
  };
  var songsLeft = songs.length;
  double songBudget() => remaining(deadline) / math.max(1, songsLeft);
  final targets = <Object>{};
  SongRef? currentSong;
  CompiledChart? currentChart;
  var lastSnapshot = -inf;
  EngineHit snapshotHit(SearchHit<Object?> hit) {
    final base = toHit(currentSong, hit);
    final detail = hit.detail;
    OrderScores? scores;
    if (detail is LiveDetail) scores = detail.scores;
    if (detail is GekisoDetail) scores = detail.scores;
    if (detail is GekisoRewardDetail) scores = detail.scores;
    if (detail is EventDetail) scores = detail.live?.scores;
    if (scores != null && currentChart != null) {
      base.score = scoreSummary(
        scores,
        currentChart,
        hit.team,
        members,
        goal is GekisoGoal || (goal is EventGoal && goal.gekiso != null),
      );
    }
    if (detail is PotentialDetail) base.potential = detail;
    if (detail is EventDetail) {
      base.event = HitEvent(
        mean: detail.mean / ((goal as EventGoal).cpExchange?.denominator ?? 1),
        bonusPercent: detail.bonus / 100,
        challengePoints: detail.challengePoints,
        perPlayMin: detail.directMin ?? detail.mean,
        perPlayMax: detail.directMax ?? detail.mean,
        rewardSum: detail.rewardSum,
        comparisonSum: detail.comparisonSum,
        orders: orders.length,
        directMean: detail.rewardSum == null
            ? null
            : detail.rewardSum! / orders.length,
      );
    }
    if (detail is GekisoRewardDetail) {
      base.gekiso = gekisoMeta(detail);
      final d = detail.settlement;
      base.event = HitEvent(
        mean: d.mean / ((goal as EventGoal).cpExchange?.denominator ?? 1),
        bonusPercent: detail.bonus / 100,
        challengePoints: d.cpSum / d.observations,
        perPlayMin: d.directMin,
        perPlayMax: d.directMax,
        rewardSum: d.rewardSum,
        comparisonSum: d.comparisonSum,
        orders: d.observations,
        directMean: d.rewardSum / d.observations,
      );
    }
    return base;
  }

  void publish(List<SearchHit<Object?>> hits) {
    if (onSnapshot == null || now() - lastSnapshot < 100 || hits.isEmpty) {
      return;
    }
    lastSnapshot = now();
    final all = [
      for (final song in requestSongs(request))
        results.where((r) => r.song == song).firstOrNull ?? pendingSong(song),
    ];
    all[results.length] = pendingSong(currentSong)
      ..hits = hits.map(snapshotHit).toList();
    onSnapshot(
      EngineSnapshot(
        requestId: request.requestId ?? '',
        contextKey: request.contextKey ?? '',
        response: EngineResponse(
          results: all,
          overall: _overall(all, request.k),
          unknownCards: box.unknown,
          elapsedMs: now(),
        ),
        completed: results.where((r) => r.proven || r.exclusion != null).length,
        total: all.length,
      ),
    );
  }

  final savedSeeds = [
    for (final hit in request.seeds)
      Team(
        [
          for (final key in hit.members)
            members.indexWhere((m) => m.key == key),
        ],
        [
          for (final key in hit.snaps)
            key == null ? -1 : snaps.indexWhere((s) => s.key == key),
        ],
      ),
  ];
  SearchOutput<D> run<D>(
    ObjectiveAdapter<D> objective,
    MusicView? music,
    List<EventEffectRow> powerEffects, {
    int? k,
    List<Team>? seeds,
    double? limitMs,
    double? floor,
    double? rewardKey,
    List<SearchHit<D>>? rewardBaseline,
    bool unsharded = false,
  }) => searchTeams(
    // Gekisou rewards also read support-skill effects the dominance
    // values do not carry.
    disableSnapDominance: ptTrial && goal.gekiso != null,
    master: master,
    player: player,
    members: members,
    snaps: snaps,
    music: music,
    objective: objective,
    constraints: constraints,
    k: k ?? request.k,
    seeds: [...savedSeeds, ...?seeds],
    onCandidate: rewardKey != null
        ? (hits) => publish(
            _mergeRewardCandidates(
              rewardBaseline ?? [],
              hits,
              rewardKey,
              request.k,
              _rewardMean,
            ),
          )
        : targets.contains(objective)
        ? publish
        : null,
    floor: floor,
    floorExclusive:
        targets.contains(objective) &&
        cutoff?.comparison == 'gt' &&
        floor == cutoff?.key,
    shard: unsharded ? null : request.shard,
    timeLimitMs: math.min(
      limitMs ?? inf,
      math.min(songBudget(), remaining(deadline)),
    ),
    cancelled: cancelled,
    memberPowerPercent: powerEffects.isNotEmpty
        ? (member) => memberEventPercent(powerEffects, member)
        : null,
    snapPowerPercent: powerEffects.isNotEmpty
        ? (snap) => snapEventPercent(powerEffects, snap)
        : null,
  );
  // A sharded search first probes the whole box briefly: its teams (exact,
  // from any leader) seed every shard's threshold.
  SearchOutput<D> seeded<D>(
    ObjectiveAdapter<D> objective,
    MusicView? music,
    List<EventEffectRow> powerEffects, {
    List<Team>? seeds,
  }) {
    targets.add(objective);
    final shard = request.shard;
    if (shard == null || shard.count < 2) {
      return run(objective, music, powerEffects, seeds: seeds);
    }
    final probe = run(
      objective,
      music,
      powerEffects,
      seeds: seeds,
      limitMs: 300,
      unsharded: true,
    );
    return run(
      objective,
      music,
      powerEffects,
      seeds: [...?seeds, for (final hit in probe.hits) hit.team],
    );
  }

  final sharded = (request.shard?.count ?? 1) > 1;
  for (final (index, song) in songs.indexed) {
    final completed = request.completed
        .where((r) => r.proven && r.song == song)
        .firstOrNull;
    if (completed != null) {
      results.add(completed);
      continue;
    }
    if (remaining(deadline) == 0 || cancelled?.call() == true) {
      results.addAll([
        for (final pending in songs.skip(index))
          request.completed
                  .where((r) => r.proven && r.song == pending)
                  .firstOrNull ??
              pendingSong(pending),
      ]);
      break;
    }
    currentSong = song;
    final known = song == null ? null : request.floors?[song.key];
    if (ptTrial && song != null) {
      final source = await charts.source(song);
      validatePtChart(master, song, source);
      if (goal.gekiso != null &&
          (source.enumeration.isEmpty || source.feverMs.length != 3)) {
        throw StateError('gekiso-chart-unsupported:${song.key}');
      }
    }
    songsLeft = songs.length - index;
    onProgress?.call(index, songs.length);
    final challengeId = switch (goal) {
      PowerGoal(:final challengeEventId) => challengeEventId,
      ScoreGoal(:final challengeEventId) => challengeEventId,
      EventGoal(route: RouteKind.challenge, :final eventId) => eventId,
      _ => null,
    };
    final music = song != null
        ? musicView(master, song.songId, challengeId)
        : null;
    final powerEffects = challengeId != null
        ? master.events[challengeId]?.effects ?? const <EventEffectRow>[]
        : const <EventEffectRow>[];
    final chart = song != null && goal is! PowerGoal
        ? await charts.chart(song)
        : null;
    currentChart = chart;
    final live = chart != null ? charts.live(chart) : null;
    if (remaining(deadline) == 0) {
      results.addAll(songs.skip(index).map(pendingSong));
      break;
    }
    switch (goal) {
      case PowerGoal():
        final objective = powerObjective();
        targets.add(objective);
        final out = run(objective, music, powerEffects);
        final compiled = song != null ? await charts.chart(song) : null;
        results.add(
          SongResult(
            song: song,
            proven: out.proven,
            bound: out.bound,
            stats: out.stats,
            hits: [
              for (final hit in out.hits)
                toHit(song, hit)
                  ..skipScore = compiled == null
                      ? null
                      : skipScore(master, compiled, hit.power),
            ],
          ),
        );
      case ScoreGoal():
        final context = LiveContext(master, members, snaps, live!, goal.play);
        final objective = liveScoreObjective(context, goal.criterion);
        // Loose-bound plays start from the best all-Perfect teams.
        final seeds = objective.hard
            ? [
                for (final hit in run(
                  liveScoreObjective(
                    LiveContext(master, members, snaps, live, ap),
                    goal.criterion,
                  ),
                  music,
                  powerEffects,
                  k: math.max(20, request.k * 3),
                  limitMs: math.min(150, songBudget() / 4),
                  unsharded: true,
                ).hits)
                  hit.team,
              ]
            : null;
        final out = seeded(objective, music, powerEffects, seeds: seeds);
        results.add(
          SongResult(
            song: song,
            proven: out.proven,
            bound: out.bound,
            stats: out.stats,
            hits: [
              for (final hit in out.hits)
                toHit(song, hit)
                  ..score = scoreSummary(
                    hit.detail.scores,
                    chart!,
                    hit.team,
                    members,
                  ),
            ],
          ),
        );
      case EventGoal(:final gekiso?):
        if (!ptTrial ||
            goal.route != RouteKind.live ||
            song == null ||
            chart == null) {
          throw StateError('gekiso-reward-mode');
        }
        final route = eventRoute(
          master,
          goal.eventId,
          RouteKind.live,
          goal.consumption,
        );
        final points = goal.measure != 'items';
        final exchange = goal.cpExchange;
        final gekisoChart = await charts.gekiso(
          song,
          Accuracy(just: gekiso.just),
          1,
        );
        final adapter = gekisoRewardObjective(
          master: master,
          members: members,
          snaps: snaps,
          chart: chart,
          gekiso: gekisoChart,
          route: route,
          points: points,
          luckSamples: gekiso.luckSamples,
          exchange: exchange,
        );
        targets.add(adapter);
        // Bonus-oriented seeds only improve traversal order.
        final seeds = [
          for (final hit in run(
            eventBonusSurrogate(shared, route.effects, points),
            music,
            const [],
            limitMs: 100,
            unsharded: true,
          ).hits)
            hit.team,
        ];
        final rewardFloor =
            cutoff?.key ?? math.max(known ?? -inf, rewardCutoff ?? -inf);
        final out = run(
          adapter,
          music,
          const [],
          seeds: seeds,
          floor: rewardFloor.isFinite ? rewardFloor : null,
        );
        var hits = out.hits;
        var proven = out.proven;
        var bound = out.bound;
        if (hits.isNotEmpty) {
          final target = hits.first.key;
          final tie = run(
            gekisoRewardObjective(
              master: master,
              members: members,
              snaps: snaps,
              chart: chart,
              gekiso: gekisoChart,
              route: route,
              points: points,
              luckSamples: gekiso.luckSamples,
              exchange: exchange,
              rewardTarget: target,
            ),
            music,
            const [],
            seeds: [for (final hit in hits) hit.team],
            floor: 0,
            rewardKey: target,
            rewardBaseline: hits,
          );
          out.stats.add(tie.stats);
          if (!tie.proven) {
            proven = false;
            bound = math.max(bound ?? -inf, target);
          }
          hits = _scoreTiedHits(
            hits,
            tie.hits,
            target,
            request.k,
            (detail) => detail.scores.mean,
          );
        }
        results.add(
          SongResult(
            song: song,
            proven: proven,
            bound: bound,
            stats: out.stats,
            hits: [
              for (final hit in hits)
                () {
                  final d = hit.detail.settlement;
                  return toHit(song, hit)
                    ..gekiso = gekisoMeta(hit.detail)
                    ..score = scoreSummary(
                      hit.detail.scores,
                      chart,
                      hit.team,
                      members,
                      true,
                    )
                    ..event = HitEvent(
                      mean: d.mean / (exchange?.denominator ?? 1),
                      bonusPercent: hit.detail.bonus / 100,
                      challengePoints: d.cpSum / d.observations,
                      perPlayMin: d.directMin,
                      perPlayMax: d.directMax,
                      rewardSum: d.rewardSum,
                      comparisonSum: d.comparisonSum,
                      orders: d.observations,
                      directMean: d.rewardSum / d.observations,
                      convertedMean: exchange != null
                          ? d.cpSum /
                                d.observations *
                                exchange.numerator /
                                exchange.denominator
                          : 0,
                    );
                }(),
            ],
          ),
        );
      case EventGoal():
        final route = eventRoute(
          master,
          goal.eventId,
          goal.route,
          goal.consumption,
        );
        final points = goal.measure != 'items';
        final played = chart != null && goal.route != RouteKind.skip;
        final context = played
            ? LiveContext(master, members, snaps, live!, goal.play)
            : null;
        final measured = played && goal.measure != 'challenge-points';
        // Under another song's cutoff, the uncapped bounds alone usually
        // prove this song cannot reach it.
        if (rewardCutoff != null && measured) {
          final quick = eventObjective(
            shared,
            context,
            chart,
            route,
            points,
            master.params.skipRank,
            ptOnly: goal.ptOnly,
            primaryOnly: true,
            exchange: goal.cpExchange,
          );
          final probe = run(
            quick,
            music,
            powerEffects,
            limitMs: 150,
            floor: rewardCutoff,
            unsharded: true,
          );
          if (probe.proven &&
              !probe.hits.any((hit) => hit.key >= rewardCutoff)) {
            final excludedBelow = math.max(rewardCutoff, known ?? -inf);
            results.add(
              SongResult(
                song: song,
                proven: false,
                bound: excludedBelow,
                excludedBelow: excludedBelow,
                stats: probe.stats,
                hits: [],
              ),
            );
            continue;
          }
        }
        final early = eventObjective(
          shared,
          played ? context : null,
          played ? chart : null,
          route,
          points,
          master.params.skipRank,
          ptOnly: goal.ptOnly,
          primaryOnly: true,
          exchange: goal.cpExchange,
        );
        final earlySeeds = <Team>[];
        if (goal.measure != 'challenge-points') {
          targets.add(early);
          earlySeeds.addAll(
            run(
              early,
              music,
              powerEffects,
              limitMs: math.min(40, songBudget() / 8),
              unsharded: true,
            ).hits.map((hit) => hit.team),
          );
        }
        var scoreCap = inf;
        if (played) {
          final capKey =
              'cap|${fingerprint ?? jsonEncode([request.members.map((m) => m.toJson()).toList(), request.snaps.map((s) => s.toJson()).toList(), request.player.toJson(), goalJson(request.goal), request.constraints.toJson(), request.unknownPolicy.name, request.k])}|${song!.key}';
          final cached = _scoreCaps[capKey];
          if (cached != null) {
            scoreCap = cached;
          } else {
            final best = run(
              scoreCapObjective(context!),
              music,
              powerEffects,
              k: 1,
              limitMs: songBudget() / 4,
              unsharded: true,
            );
            final top = best.hits.firstOrNull?.key ?? inf;
            scoreCap = best.proven ? top : math.max(top, best.bound ?? inf);
            if (_scoreCaps.length > 64) _scoreCaps.clear();
            _scoreCaps[capKey] = scoreCap;
          }
        }
        final objective = eventObjective(
          shared,
          played ? context : null,
          played ? chart : null,
          route,
          points,
          master.params.skipRank,
          scoreCap: scoreCap,
          ptOnly: goal.ptOnly,
          primaryOnly: true,
          exchange: goal.cpExchange,
        );
        var adapter = objective;
        if (goal.measure == 'challenge-points' && chart != null) {
          adapter = challengePointObjective(
            liveScoreObjective(
              LiveContext(master, members, snaps, live!, goal.play),
              Criterion.mean,
            ),
            chart,
            route,
          );
        }
        targets.add(adapter);
        SearchOutput<EventDetail> out;
        double? floor;
        if (played && goal.measure != 'challenge-points') {
          // Seeds along the bonus/power front, and a floor at the k-th best seed's key.
          final prepKey =
              '${fingerprint ?? jsonEncode([request.members.map((m) => m.toJson()).toList(), request.snaps.map((s) => s.toJson()).toList(), request.player.toJson(), goalJson(request.goal), request.constraints.toJson(), request.unknownPolicy.name, request.k])}|${song!.key}';
          var prep = _eventPrep[prepKey];
          if (prep == null) {
            final seeds = <Team>[...earlySeeds];
            for (final weight in const [
              16777216.0,
              64.0,
              32.0,
              16.0,
              8.0,
              4.0,
              2.0,
            ]) {
              seeds.addAll([
                for (final hit in run(
                  eventBonusSurrogate(shared, route.effects, points, weight),
                  music,
                  powerEffects,
                  limitMs: 100,
                  unsharded: true,
                ).hits)
                  hit.team,
              ]);
            }
            final probe = run(
              adapter,
              music,
              powerEffects,
              seeds: seeds,
              limitMs: 1,
              unsharded: true,
            );
            prep = (
              seeds: seeds,
              aspiration: probe.hits.length >= request.k
                  ? probe.hits[request.k - 1].key
                  : null,
            );
            if (_eventPrep.length > 64) _eventPrep.clear();
            _eventPrep[prepKey] = prep;
          }
          floor = request.noFloor ? null : prep.aspiration;
          final searchFloor =
              cutoff?.key ??
              math.max(
                math.max(floor ?? -inf, known ?? -inf),
                rewardCutoff ?? -inf,
              );
          out = run(
            adapter,
            music,
            powerEffects,
            seeds: [...earlySeeds, ...prep.seeds],
            floor: searchFloor.isFinite ? searchFloor : null,
          );
          final enough =
              out.hits
                  .where((hit) => floor == null || hit.key >= floor)
                  .length >=
              request.k;
          if (!enough && cutoff == null && rewardCutoff == null && !sharded) {
            out = run(adapter, music, powerEffects, seeds: prep.seeds);
            floor = null;
          }
        } else {
          out = seeded(adapter, music, powerEffects, seeds: earlySeeds);
        }
        // Teams tied at one reward are ordered by mean score.
        var hits = out.hits;
        var proven = out.proven;
        var bound = out.bound;
        if (hits.isNotEmpty && measured) {
          final ordered = <SearchHit<EventDetail>>[];
          final keys = {for (final hit in hits) hit.key}.toList()
            ..sort((a, b) => b.compareTo(a));
          for (final key in keys) {
            if (ordered.length >= request.k) break;
            final group = [
              for (final hit in hits)
                if (hit.key == key) hit.team,
            ];
            final tie = run(
              eventScoreTieObjective(context!, objective, key, [
                for (final hit in ordered) hit.team,
              ]),
              music,
              powerEffects,
              k: request.k - ordered.length,
              seeds: group,
              floor: 0,
              rewardKey: key,
              rewardBaseline: [...hits, ...ordered],
            );
            if (!tie.proven) {
              proven = false;
              bound = math.max(bound ?? -inf, key);
            }
            out.stats.add(tie.stats);
            ordered.addAll(
              _scoreTiedHits(
                hits,
                tie.hits,
                key,
                request.k - ordered.length,
                (detail) => detail.live?.scores.mean ?? 0,
              ),
            );
          }
          hits = ordered.take(request.k).toList();
        }
        results.add(
          SongResult(
            song: song,
            proven: proven,
            bound: bound,
            stats: out.stats,
            floor: floor != null && sharded ? floor : null,
            hits: [
              for (final hit in hits)
                () {
                  final detail = hit.detail;
                  final base = toHit(song, hit);
                  if (detail.live != null && chart != null) {
                    base.score = scoreSummary(
                      detail.live!.scores,
                      chart,
                      hit.team,
                      members,
                    );
                  }
                  final perOrder = detail.perOrder;
                  final exchange = goal.cpExchange;
                  return base
                    ..event = HitEvent(
                      rewardSum: ptTrial ? detail.rewardSum : null,
                      comparisonSum: ptTrial ? detail.comparisonSum : null,
                      orders: ptTrial ? orders.length : null,
                      directMean: ptTrial && detail.rewardSum != null
                          ? detail.rewardSum! / orders.length
                          : null,
                      convertedMean: !ptTrial
                          ? null
                          : exchange != null
                          ? detail.challengePoints *
                                exchange.numerator /
                                exchange.denominator
                          : 0,
                      mean: detail.mean / (exchange?.denominator ?? 1),
                      bonusPercent: detail.bonus / 100,
                      challengePoints: detail.challengePoints,
                      perPlayMin:
                          detail.directMin ??
                          (perOrder != null
                              ? perOrder.reduce(math.min)
                              : detail.mean),
                      perPlayMax:
                          detail.directMax ??
                          (perOrder != null
                              ? perOrder.reduce(math.max)
                              : detail.mean),
                    );
                }(),
            ],
          ),
        );
      case GekisoGoal():
        final gekiso = await charts.gekiso(song!, goal.accuracy, goal.rank);
        final exactRanking =
            !gekiso.luck && goal.seeds <= 1 && !request.seedOnly;
        double margin(double key) => math.max(1, key.abs()) * 3e-5;
        var extra = exactRanking ? 4 : 0;
        SearchOutput<GekisoDetail> search() => gekisoSearch(
          master: master,
          player: player,
          members: members,
          snaps: snaps,
          music: music,
          chart: gekiso,
          seeds: [for (var i = 0; i < goal.seeds; i++) i],
          criterion: goal.criterion,
          constraints: constraints,
          initialTeams: savedSeeds,
          onCandidate: publish,
          seedOnly: request.seedOnly,
          seeded: request.seeded,
          k: request.k + extra,
          timeLimitMs: songBudget(),
          shard: request.shard,
          floor: known == null
              ? null
              : exactRanking
              ? known - 2 * margin(known)
              : known,
          cancelled: cancelled,
        );
        var out = search();
        if (exactRanking) {
          while (out.proven &&
              out.hits.length == request.k + extra &&
              out.hits.length >= request.k &&
              out.hits.last.key >=
                  out.hits[request.k - 1].key -
                      2 * margin(out.hits[request.k - 1].key)) {
            extra *= 2;
            out = search();
          }
          final kth = out.hits.isEmpty
              ? -inf
              : out.hits[math.min(request.k, out.hits.length) - 1].key;
          final finalists = <SearchHit<GekisoDetail>>[];
          for (final hit in out.hits.where(
            (hit) => hit.key >= kth - 2 * margin(kth),
          )) {
            final deck = [
              for (final (slot, member) in hit.team.members.indexed)
                performer(
                  master,
                  members[member],
                  hit.team.snaps[slot] >= 0
                      ? snaps[hit.team.snaps[slot]]
                      : null,
                ),
            ];
            final scores = fullOrdersGekiso(
              master,
              gekiso,
              deck,
              hit.power,
              music?.musicType ?? 0,
            );
            final key = switch (goal.criterion) {
              Criterion.min => scores.min,
              Criterion.max => scores.max,
              Criterion.mean => scores.mean,
            };
            finalists.add(
              SearchHit(
                hit.team,
                hit.power,
                hit.slotPowers,
                hit.totals,
                key,
                GekisoDetail(scores, hit.detail.skills, hit.detail.seeds),
              ),
            );
          }
          finalists.sort((a, b) => b.key.compareTo(a.key));
          out = SearchOutput(
            finalists.take(request.k).toList(),
            out.proven,
            out.bound,
            out.stats,
          );
        }
        results.add(
          SongResult(
            song: song,
            proven: out.proven,
            bound: out.bound,
            stats: out.stats,
            hits: [
              for (final hit in out.hits)
                toHit(song, hit)
                  ..score = scoreSummary(
                    hit.detail.scores,
                    chart!,
                    hit.team,
                    members,
                    true,
                  ),
            ],
          ),
        );
      case PotentialGoal():
        final objective = potentialObjective(shared, goal.windowSeconds);
        targets.add(objective);
        final out = run(objective, null, const []);
        results.add(
          SongResult(
            song: null,
            proven: out.proven,
            bound: out.bound,
            stats: out.stats,
            hits: [
              for (final hit in out.hits)
                toHit(null, hit)..potential = hit.detail,
            ],
          ),
        );
      case PlanGoal():
        break;
    }
    if (cutoff != null && results.isNotEmpty) {
      final result = results.last;
      result.hits = result.hits
          .where((hit) => cutoff.accepts(hit.key))
          .toList();
      if (result.hits.isEmpty &&
          (result.proven ||
              (result.bound != null && cutoff.excludes(result.bound!)))) {
        result.exclusion = cutoff;
        result.proven = false;
        result.floor = null;
      }
    }
    if (rewardCutoff != null && results.isNotEmpty) {
      final result = results.last;
      result.hits = [
        for (final hit in result.hits)
          if (hit.key >= rewardCutoff) hit,
      ];
      if (result.proven && result.hits.isEmpty) {
        final known = result.song == null
            ? null
            : request.floors?[result.song!.key];
        result.excludedBelow = math.max(
          math.max(rewardCutoff, known ?? -inf),
          result.floor ?? -inf,
        );
        result.proven = false;
        result.bound = result.excludedBelow;
        result.floor = null;
      }
    }
  }
  return EngineResponse(
    results: results,
    overall: _overall(results, request.k),
    unknownCards: box.unknown,
    elapsedMs: now(),
    stopReason:
        results.every(
          (r) => r.proven || r.exclusion != null || r.excludedBelow != null,
        )
        ? 'complete'
        : cancelled?.call() == true
        ? 'cancelled'
        : 'budget',
  );
}

Future<EngineResponse> _runPlan(
  EngineMaster master,
  ChartCache charts,
  EngineRequest request,
  PlanGoal goal,
  Stopwatch clock,
  Progress? onProgress,
  bool Function()? cancelled,
  void Function(EngineSnapshot)? onSnapshot,
) async {
  double now() => clock.elapsedMicroseconds / 1000;
  final total = goal.challengeSongs.length + goal.normalSongs.length;
  var done = 0;
  void step(int inner, int _) => onProgress?.call(done + inner, total);
  final budgetEnd = deadlineOf(request);
  // Challenge stage first: its best points per challenge point prices what normal lives earn.
  final challenge = goal.challengePointsPerPlay != null
      ? EngineResponse(results: [], overall: [], unknownCards: [], elapsedMs: 0)
      : await runEngine(
          master,
          charts,
          request.copyWith(
            goal: EventGoal(
              measure: 'points',
              route: RouteKind.challenge,
              eventId: goal.eventId,
              songs: goal.challengeSongs,
              consumption: goal.challengePointsPerLive,
              play: goal.play,
            ),
          ),
          onSnapshot: (snapshot) => onSnapshot?.call(
            EngineSnapshot(
              requestId: snapshot.requestId,
              contextKey: snapshot.contextKey,
              response: EngineResponse(
                results: [
                  ...snapshot.response.results,
                  ...goal.normalSongs.map(pendingSong),
                ],
                overall: snapshot.response.overall,
                unknownCards: snapshot.response.unknownCards,
                elapsedMs: now(),
              ),
              completed: snapshot.completed,
              total: total,
            ),
          ),
          onProgress: step,
          cancelled: cancelled,
        );
  if (!challenge.results.every((r) => r.proven)) {
    return EngineResponse(
      results: [...challenge.results, ...goal.normalSongs.map(pendingSong)],
      overall: challenge.overall,
      unknownCards: challenge.unknownCards,
      elapsedMs: now(),
      stopReason: 'budget',
    );
  }
  done += goal.challengeSongs.length;
  final bestChallenge = challenge.overall.firstOrNull;
  final pointsPerChallenge =
      goal.challengePointsPerPlay ?? bestChallenge?.event?.mean ?? 0;
  final weight = goal.challengePointsPerLive > 0
      ? pointsPerChallenge / goal.challengePointsPerLive
      : 0.0;
  final box = resolveBox(
    master,
    request.members,
    request.snaps,
    request.unknownPolicy,
  );
  final player = playerState(master, request.player);
  final constraints = constraintsOf(
    request.constraints,
    box.members,
    box.snaps,
  );
  final shared = Shared(master, box.members, box.snaps);
  final route = eventRoute(
    master,
    goal.eventId,
    RouteKind.live,
    goal.boostsPerLive,
  );
  final normalResults = <SongResult>[];
  var lastSnapshot = -inf;
  for (final (index, song) in goal.normalSongs.indexed) {
    if (remaining(budgetEnd) == 0) {
      normalResults.addAll(goal.normalSongs.skip(index).map(pendingSong));
      break;
    }
    step(index, total);
    final chart = await charts.chart(song);
    final live = charts.live(chart);
    final music = musicView(master, song.songId, null);
    final songBudget =
        remaining(budgetEnd) / math.max(1, goal.normalSongs.length - index);
    final context = LiveContext(
      master,
      box.members,
      box.snaps,
      live,
      goal.play,
    );
    final best = searchTeams(
      master: master,
      player: player,
      members: box.members,
      snaps: box.snaps,
      music: music,
      objective: scoreCapObjective(context),
      constraints: constraints,
      k: 1,
      timeLimitMs: songBudget / 4,
      cancelled: cancelled,
    );
    final top = best.hits.firstOrNull?.key ?? inf;
    final scoreCap = best.proven ? top : math.max(top, best.bound ?? inf);
    final objective = eventObjective(
      shared,
      context,
      chart,
      route,
      true,
      master.params.skipRank,
      challengePointWeight: weight,
      scoreCap: scoreCap,
      primaryOnly: true,
    );
    EngineHit planHit(SearchHit<EventDetail> hit) {
      final detail = hit.detail;
      final perOrder = detail.perOrder;
      final pointsOnly = perOrder != null
          ? perOrder.fold(0.0, (a, b) => a + b) / perOrder.length
          : 0.0;
      return EngineHit(
          song: song,
          members: [for (final i in hit.team.members) box.members[i].key],
          snaps: [
            for (final j in hit.team.snaps) j < 0 ? null : box.snaps[j].key,
          ],
          power: hit.power,
          slotPowers: hit.slotPowers,
          key: hit.key,
        )
        ..score = detail.live == null
            ? null
            : scoreSummary(detail.live!.scores, chart, hit.team, box.members)
        // perOrder includes the challenge-point weight; report plain points per play.
        ..event = HitEvent(
          mean: pointsOnly - weight * detail.challengePoints,
          bonusPercent: detail.bonus / 100,
          challengePoints: detail.challengePoints,
          perPlayMin: 0,
          perPlayMax: 0,
        );
    }

    void candidate(List<SearchHit<EventDetail>> hits) {
      if (hits.isEmpty || now() - lastSnapshot < 100 || onSnapshot == null) {
        return;
      }
      lastSnapshot = now();
      final results = [
        ...challenge.results,
        ...normalResults,
        pendingSong(song)..hits = hits.map(planHit).toList(),
        ...goal.normalSongs.skip(index + 1).map(pendingSong),
      ];
      onSnapshot(
        EngineSnapshot(
          requestId: request.requestId ?? '',
          contextKey: request.contextKey ?? '',
          response: EngineResponse(
            results: results,
            overall: _overall(results, request.k),
            unknownCards: box.unknown,
            elapsedMs: now(),
          ),
          completed: results.where((r) => r.proven).length,
          total: total,
        ),
      );
    }

    final out = searchTeams(
      master: master,
      player: player,
      members: box.members,
      snaps: box.snaps,
      music: music,
      objective: objective,
      constraints: constraints,
      k: request.k,
      onCandidate: candidate,
      timeLimitMs: math.min(songBudget, remaining(budgetEnd)),
      cancelled: cancelled,
    );
    final ordered = <SearchHit<EventDetail>>[];
    var proven = out.proven;
    var bound = out.bound;
    final keys = {for (final hit in out.hits) hit.key}.toList()
      ..sort((a, b) => b.compareTo(a));
    for (final key in keys) {
      if (ordered.length >= request.k) break;
      final tie = searchTeams(
        master: master,
        player: player,
        members: box.members,
        snaps: box.snaps,
        music: music,
        objective: eventScoreTieObjective(context, objective, key, [
          for (final hit in ordered) hit.team,
        ]),
        constraints: constraints,
        k: request.k - ordered.length,
        seeds: [
          for (final hit in out.hits)
            if (hit.key == key) hit.team,
        ],
        floor: 0,
        onCandidate: (hits) => candidate(
          _mergeRewardCandidates(
            [...out.hits, ...ordered],
            hits,
            key,
            request.k,
            (detail) => detail.live?.scores.mean ?? 0,
          ),
        ),
        timeLimitMs: math
            .min(songBudget - out.stats.elapsedMs, remaining(budgetEnd))
            .clamp(0, inf),
        cancelled: cancelled,
      );
      out.stats.add(tie.stats);
      if (!tie.proven) {
        proven = false;
        bound = math.max(bound ?? -inf, key);
      }
      ordered.addAll(
        _scoreTiedHits(
          out.hits,
          tie.hits,
          key,
          request.k - ordered.length,
          (detail) => detail.live?.scores.mean ?? 0,
        ),
      );
    }
    normalResults.add(
      SongResult(
        song: song,
        proven: proven,
        bound: bound,
        stats: out.stats,
        hits: ordered.map(planHit).toList(),
      ),
    );
  }
  final bestNormal = ([
    for (final r in normalResults) ...r.hits,
  ]..sort(compareHits)).firstOrNull;
  final lives = goal.boostsPerLive > 0
      ? goal.boostBudget ~/ goal.boostsPerLive
      : goal.boostBudget;
  final earned = (lives * (bestNormal?.event?.challengePoints ?? 0)).floor();
  final pool = goal.startingChallengePoints + earned;
  final challengeLives = goal.challengePointsPerLive > 0
      ? pool ~/ goal.challengePointsPerLive
      : 0;
  final eventPointsTotal =
      lives * (bestNormal?.event?.mean ?? 0) +
      challengeLives * pointsPerChallenge;
  return EngineResponse(
    plan: PlanSummary(
      normal: bestNormal,
      challenge: bestChallenge,
      normalLives: lives,
      challengeLives: challengeLives,
      challengePointsEarned: earned,
      leftoverChallengePoints:
          pool - challengeLives * goal.challengePointsPerLive,
      eventPoints: eventPointsTotal,
      perBoost: goal.boostBudget != 0
          ? eventPointsTotal /
                math.max(
                  1,
                  goal.boostsPerLive > 0
                      ? lives * goal.boostsPerLive
                      : goal.boostBudget,
                )
          : 0,
    ),
    results: [...challenge.results, ...normalResults],
    overall: [?bestNormal, ?bestChallenge],
    unknownCards: goal.challengePointsPerPlay != null
        ? box.unknown
        : challenge.unknownCards,
    elapsedMs: now(),
  );
}

/// A fixed team across songs (team check / comparison).
class TeamSpec {
  TeamSpec(this.members, this.snaps, this.leader);
  factory TeamSpec.fromJson(Map<String, Object?> json) => TeamSpec(
    [for (final key in json['members'] as List) '$key'],
    [for (final key in json['snaps'] as List) key as String?],
    '${json['leader']}',
  );
  Map<String, Object?> toJson() => {
    'members': members,
    'snaps': snaps,
    'leader': leader,
  };
  final List<String> members;
  final List<String?> snaps;
  final String leader;
}

class TeamEvaluation {
  TeamEvaluation({
    required this.song,
    required this.power,
    required this.slotPowers,
    required this.score,
    required this.skipScore,
    required this.event,
  });
  factory TeamEvaluation.fromJson(Map<String, Object?> json) => TeamEvaluation(
    song: SongRef.fromJson(objectRow(json['song'])),
    power: intOf(json['power']),
    slotPowers: intListOf(json['slotPowers']),
    score: HitScore.fromJson(objectRow(json['score'])),
    skipScore: intOf(json['skipScore']),
    event: json['event'] is Map
        ? (
            points: numOf(objectRow(json['event'])['points']),
            items: numOf(objectRow(json['event'])['items']),
            bonusPercent: numOf(objectRow(json['event'])['bonusPercent']),
            itemBonusPercent: numOf(
              objectRow(json['event'])['itemBonusPercent'],
            ),
          )
        : null,
  );
  Map<String, Object?> toJson() => {
    'song': song.toJson(),
    'power': power,
    'slotPowers': slotPowers,
    'score': score.toJson(),
    'skipScore': skipScore,
    'event': event == null
        ? null
        : {
            'points': event!.points,
            'items': event!.items,
            'bonusPercent': event!.bonusPercent,
            'itemBonusPercent': event!.itemBonusPercent,
          },
  };
  final SongRef song;
  final int power;
  final List<int> slotPowers;
  final HitScore score;
  final int skipScore;
  final ({
    double points,
    double items,
    double bonusPercent,
    double itemBonusPercent,
  })?
  event;
}

Future<List<TeamEvaluation>> evaluateTeam(
  EngineMaster master,
  ChartCache charts, {
  required List<MemberInput> members,
  required List<SnapInput> snaps,
  required PlayerInput player,
  UnknownPolicy unknownPolicy = UnknownPolicy.max,
  required TeamSpec team,
  required List<SongRef> songs,
  PlayModel play = ap,
  int? challengeEventId,
  ({int eventId, RouteKind route, int consumption})? event,
}) async {
  final box = resolveBox(master, members, snaps, unknownPolicy);
  final playerValue = playerState(master, player);
  final order = [
    team.leader,
    ...team.members.where((key) => key != team.leader),
  ];
  final memberStates = [
    for (final key in order)
      box.members.where((member) => member.key == key).firstOrNull,
  ];
  if (memberStates.any((member) => member == null)) {
    throw RangeError('unknown-team-member');
  }
  final teamMembers = memberStates.cast<MemberState>();
  final snapByMember = {
    for (final (index, key) in team.members.indexed)
      key: team.snaps.elementAtOrNull(index),
  };
  final snapStates = [
    for (final key in order)
      if (snapByMember[key] case final snap?)
        box.snaps.where((item) => item.key == snap).firstOrNull
      else
        null,
  ];
  final out = <TeamEvaluation>[];
  for (final song in songs) {
    final chart = await charts.chart(song);
    final live = charts.live(chart);
    final challengeId = event?.route == RouteKind.challenge
        ? event!.eventId
        : challengeEventId;
    final effects = challengeId != null
        ? master.events[challengeId]?.effects ?? const <EventEffectRow>[]
        : const <EventEffectRow>[];
    final power = teamPower(
      master,
      playerValue,
      teamMembers,
      snapStates,
      0,
      musicView(master, song.songId, challengeId),
      effects,
    );
    final usedSnaps = snapStates.whereType<SnapState>().toList();
    final evaluated = Team(
      [0, 1, 2, 3, 4],
      [
        for (final snap in snapStates)
          snap == null ? -1 : usedSnaps.indexOf(snap),
      ],
    );
    final objective = liveScoreObjective(
      LiveContext(master, teamMembers, usedSnaps, live, play),
      Criterion.mean,
    );
    final detail = objective.exact(evaluated, power.total, power.slots).detail;
    ({
      double points,
      double items,
      double bonusPercent,
      double itemBonusPercent,
    })?
    eventValue;
    if (event != null) {
      final route = eventRoute(
        master,
        event.eventId,
        event.route,
        event.consumption,
      );
      int bonus(int type) =>
          teamMembers.fold(
            0,
            (sum, member) =>
                sum + memberEventPercent(route.effects, member, type),
          ) +
          usedSnaps.fold(
            0,
            (sum, snap) => sum + snapEventPercent(route.effects, snap, type),
          );
      final pointBonus = bonus(0), itemBonus = bonus(1);
      var points = 0.0, items = 0.0;
      for (final score in detail.scores.scores) {
        final rank = scoreRank(chart, score);
        points += eventPoints(route, pointBonus, rank);
        items += eventItems(route, itemBonus, rank);
      }
      eventValue = (
        points: points / orders.length,
        items: items / orders.length,
        bonusPercent: pointBonus / 100,
        itemBonusPercent: itemBonus / 100,
      );
    }
    out.add(
      TeamEvaluation(
        song: song,
        power: power.total,
        slotPowers: power.slots,
        score: scoreSummary(detail.scores, chart, evaluated, teamMembers),
        skipScore: skipScore(master, chart, power.total),
        event: eventValue,
      ),
    );
  }
  return out;
}

/// The skill windows of one order, for the timeline view.
class SkillWindow {
  SkillWindow(
    this.member,
    this.event,
    this.startMs,
    this.endMs,
    this.percent,
    this.perfectPercent, [
    this.extensionMs = 0,
  ]);
  factory SkillWindow.fromJson(Map<String, Object?> json) => SkillWindow(
    '${json['member']}',
    intOf(json['event']),
    intOf(json['startMs']),
    intOf(json['endMs']),
    numOf(json['percent']),
    numOf(json['perfectPercent']),
    numOf(json['extensionMs']),
  );
  Map<String, Object?> toJson() => {
    'member': member,
    'event': event,
    'startMs': startMs,
    'endMs': endMs,
    'percent': percent,
    'perfectPercent': perfectPercent,
    'extensionMs': extensionMs,
  };
  final String member;
  final int event;
  final int startMs;
  final int endMs;
  final double percent;
  final double perfectPercent;
  final double extensionMs;
}

List<SkillWindow> skillWindows(
  EngineMaster master,
  CompiledChart chart,
  List<MemberState> members,
  List<SnapState?> snaps,
  List<int> order,
) => [
  for (final (event, slot) in order.indexed)
    if (event < chart.skillTimes.length)
      () {
        final skill = resolveSlotSkill(master, members[slot], snaps[slot]);
        var percent = 0.0, perfect = 0.0;
        var length = 0;
        for (final effect in skill.effects) {
          if (effect.gate.blocks(master.live.lifeBase)) continue;
          if (effect.type == 2000) {
            percent += effect.delta / 1000;
          } else {
            perfect += effect.delta / 1000;
          }
          length = math.max(
            length,
            windowMs(effect.seconds, skill.extensionMs),
          );
        }
        final start = chart.skillTimes[event];
        return SkillWindow(
          members[slot].key,
          event,
          start,
          start + length,
          percent,
          perfect,
          skill.extensionMs,
        );
      }(),
];
