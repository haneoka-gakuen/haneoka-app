import 'dart:math' as math;

import 'api.dart';
import 'num.dart';
import 'objectives.dart';
import 'search.dart';

final _origin = DateTime.now().millisecondsSinceEpoch;
final _steady = Stopwatch()..start();
double executionClock() => _origin + _steady.elapsedMicroseconds / 1000;
double deadlineOf(EngineRequest request) =>
    request.deadline ??
    (request.timeLimitMs == null
        ? double.infinity
        : executionClock() + request.timeLimitMs!);
double remaining(double deadline) => math.max(0, deadline - executionClock());

class RewardCutoff {
  const RewardCutoff(
    this.key,
    this.comparison,
    this.contextKey, [
    this.ranking = 'reward-mean-score-v2',
  ]);
  factory RewardCutoff.fromJson(Map<String, Object?> json) => RewardCutoff(
    (json['key'] as num).toDouble(),
    '${json['comparison']}',
    '${json['contextKey']}',
    '${json['ranking']}',
  );
  final double key;
  final String comparison;
  final String contextKey;
  final String ranking;
  bool accepts(double value) => comparison == 'gt' ? value > key : value >= key;
  bool excludes(double bound) =>
      comparison == 'gt' ? bound <= key : bound < key;
  Map<String, Object?> toJson() => {
    'key': key,
    'comparison': comparison,
    'contextKey': contextKey,
    'ranking': ranking,
  };
}

List<SongRef?> requestSongs(EngineRequest request) => switch (request.goal) {
  PowerGoal(:final song) => [song],
  PotentialGoal() => [null],
  PlanGoal(:final challengeSongs, :final normalSongs) => [
    ...challengeSongs,
    ...normalSongs,
  ],
  EventGoal(:final songs, route: RouteKind.skip) when songs.isEmpty => [null],
  EventGoal(:final songs) ||
  ScoreGoal(:final songs) ||
  GekisoGoal(:final songs) => [...songs],
};
SongResult pendingSong(SongRef? song) => SongResult(
  song: song,
  hits: [],
  proven: false,
  bound: double.infinity,
  stats: SearchStats(),
);
List<SongRef?> requestChartSongs(EngineRequest request) => [
  ...requestSongs(request),
  if (request.goal case EventGoal(:final rewardPlan?))
    for (final song
        in objectRow(rewardPlan['autoCp'])['songs'] as List? ?? const [])
      SongRef.fromJson(objectRow(song)),
];

EngineResponse emptyResponse(EngineRequest request) => EngineResponse(
  results: [
    for (final song in requestSongs(request))
      request.completed.where((result) => result.song == song).firstOrNull ??
          pendingSong(song),
  ],
  overall: [],
  unknownCards: [],
  elapsedMs: 0,
);
bool completeResponse(EngineResponse response) =>
    response.results.isNotEmpty &&
    response.results.every(
      (result) =>
          result.proven ||
          result.exclusion != null ||
          result.excludedBelow != null,
    );
double? improvementPercent(List<SongResult> results) {
  final keys = [
    for (final result in results)
      for (final hit in result.hits) hit.key,
  ];
  if (keys.isEmpty || results.isEmpty) return null;
  final best = keys.reduce(math.max);
  if (!(best > 0)) return null;
  var upper = best;
  for (final result in results) {
    if (result.proven) continue;
    final bound = result.exclusion?.key ?? result.bound;
    if (bound == null || !bound.isFinite) return null;
    upper = math.max(upper, bound);
  }
  return (math.max(0, (upper / best - 1) * 1000)).ceil() / 10;
}

class EngineTiming {
  EngineTiming({
    this.initializationMs = 0,
    this.networkMs = 0,
    this.computationMs = 0,
    this.wallMs = 0,
  });
  factory EngineTiming.fromJson(Map<String, Object?> json) => EngineTiming(
    initializationMs: (json['initializationMs'] as num?)?.toDouble() ?? 0,
    networkMs: (json['networkMs'] as num?)?.toDouble() ?? 0,
    computationMs: (json['computationMs'] as num?)?.toDouble() ?? 0,
    wallMs: (json['wallMs'] as num?)?.toDouble() ?? 0,
  );
  double initializationMs;
  double networkMs;
  double computationMs;
  double wallMs;
  Map<String, Object?> toJson() => {
    'initializationMs': initializationMs,
    'networkMs': networkMs,
    'computationMs': computationMs,
    'wallMs': wallMs,
  };
}

class EngineSnapshot {
  const EngineSnapshot({
    required this.requestId,
    required this.contextKey,
    required this.response,
    required this.completed,
    required this.total,
    this.stopReason,
  });
  factory EngineSnapshot.fromJson(Map<String, Object?> json) => EngineSnapshot(
    requestId: '${json['requestId']}',
    contextKey: '${json['contextKey']}',
    response: EngineResponse.fromJson(
      (json['response'] as Map).cast<String, Object?>(),
    ),
    completed: ((json['completed'] as num?) ?? 0).toInt(),
    total: ((json['total'] as num?) ?? 0).toInt(),
    stopReason: json['stopReason'] as String?,
  );
  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'contextKey': contextKey,
    'response': response.toJson(),
    'completed': completed,
    'total': total,
    'stopReason': stopReason,
  };
  final String requestId;
  final String contextKey;
  final EngineResponse response;
  final int completed;
  final int total;
  final String? stopReason;
}
