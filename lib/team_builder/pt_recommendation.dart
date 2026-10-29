/// Reward recommendation jobs (`team-builder/pt-recommendation.ts`,
/// `pt-checkpoint.ts`): the best team of every chosen song for event
/// points and shop medals, with the challenge lives its challenge points
/// pay for. A completed or certified-excluded chart is the smallest
/// resumable unit; the job is kept on the device only.
library;

import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'engine/api.dart';
import 'engine/execution.dart';
import 'engine/num.dart';
import 'engine/objectives.dart' show CpExchange, RouteKind;

const ptVersion = 'reward-conservative-bounds-v10';

class PtCycle {
  PtCycle(this.songs, this.consumption);
  factory PtCycle.fromJson(Map<String, Object?> json) => PtCycle([
    for (final song in json['songs'] as List? ?? const [])
      SongRef.fromJson(objectRow(song)),
  ], intOf(json['consumption']));
  final List<SongRef> songs;
  final int consumption;
  Map<String, Object?> toJson() => {
    'songs': [for (final song in songs) song.toJson()],
    'consumption': consumption,
  };
}

/// `queued`, `running`, `complete`, `empty`, `pruned` or `failed`.
class PtTask {
  PtTask(this.route, this.measure, this.song);
  factory PtTask.fromJson(Map<String, Object?> json) =>
      PtTask(
          RouteKind.values.byName('${json['route']}'),
          '${json['measure']}',
          SongRef.fromJson(objectRow(json['song'])),
        )
        ..status = '${json['status'] ?? 'queued'}'
        ..result = json['result'] is Map
            ? SongResult.fromJson(objectRow(json['result']))
            : null
        ..error = '${json['error'] ?? ''}';
  final RouteKind route;
  final String measure;
  final SongRef song;
  String status = 'queued';
  SongResult? result;
  String error = '';
  Map<String, Object?> toJson() => {
    'route': route.name,
    'measure': measure,
    'song': song.toJson(),
    'status': status,
    'result': result?.toJson(),
    'error': error,
  };

  bool get complete =>
      (status == 'complete' || status == 'empty') && result?.proven == true;

  bool excluded(RewardCutoff? cutoff) {
    final proof = result?.exclusion;
    return cutoff != null &&
        proof != null &&
        status == 'pruned' &&
        proof.contextKey == cutoff.contextKey &&
        proof.ranking == cutoff.ranking &&
        (proof.key < cutoff.key ||
            (proof.key == cutoff.key &&
                (proof.comparison == 'gte' || cutoff.comparison == 'gt')));
  }
}

class PtJob {
  PtJob({
    required this.id,
    required this.fingerprint,
    required this.dataFingerprint,
    required this.owner,
    required this.server,
    required this.request,
    required this.cycle,
    required this.tasks,
    this.scope = 'top-one',
    int? createdAt,
    int? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
       updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;
  factory PtJob.fromJson(Map<String, Object?> json) => PtJob(
    id: '${json['id']}',
    fingerprint: '${json['fingerprint']}',
    dataFingerprint: '${json['dataFingerprint']}',
    owner: '${json['owner']}',
    server: '${json['server']}',
    request: EngineRequest.fromJson(objectRow(json['request'])),
    cycle: json['cycle'] is Map
        ? PtCycle.fromJson(objectRow(json['cycle']))
        : null,
    tasks: [
      for (final task in json['tasks'] as List? ?? const [])
        PtTask.fromJson(objectRow(task)),
    ],
    scope: '${json['scope'] ?? 'top-one'}',
    createdAt: intOf(json['createdAt']),
    updatedAt: intOf(json['updatedAt']),
  );
  final String id;
  final String fingerprint;
  final String dataFingerprint;
  final String owner;
  final String server;
  final EngineRequest request;
  final PtCycle? cycle;
  final List<PtTask> tasks;

  /// The scope: the top five songs, or every song to proof.
  String scope;
  bool get topFive => scope != 'all';
  set topFive(bool value) => scope = value ? 'top-five' : 'all';
  final int createdAt;
  int updatedAt;
  Map<String, Object?> toJson() => {
    'version': ptVersion,
    'id': id,
    'fingerprint': fingerprint,
    'dataFingerprint': dataFingerprint,
    'owner': owner,
    'server': server,
    'request': request.toJson(),
    'cycle': cycle?.toJson(),
    'scope': scope,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'tasks': [for (final task in tasks) task.toJson()],
  };
}

Object? _canonical(Object? value) => switch (value) {
  final Map map => {
    for (final key in map.keys.map((k) => '$k').toList()..sort())
      key: _canonical(map[key]),
  },
  final List list => [for (final item in list) _canonical(item)],
  _ => value,
};

/// Canonical JSON: key order cannot change identity.
String canonical(Object? value) => jsonEncode(_canonical(value));

String ptFingerprint(
  EngineRequest request,
  String dataFingerprint,
  String owner,
  PtCycle? cycle,
) => sha256
    .convert(
      utf8.encode(
        canonical({
          'version': ptVersion,
          'dataFingerprint': dataFingerprint,
          'owner': owner,
          'request': request.toJson(),
          'cycle': cycle?.toJson(),
        }),
      ),
    )
    .toString();

PtJob createPtJob(
  EngineRequest request, {
  required String server,
  required String dataFingerprint,
  required String owner,
  PtCycle? cycle,
}) {
  final goal = request.goal;
  if (goal is! EventGoal ||
      !goal.ptOnly ||
      goal.route != RouteKind.live ||
      !(goal.measure == 'points' || goal.measure == 'items')) {
    throw StateError('pt-mode');
  }
  if (cycle != null && (cycle.songs.isEmpty || cycle.consumption <= 0)) {
    throw StateError('pt-cycle-input');
  }
  final tasks = <PtTask>[
    if (cycle != null)
      for (final song in cycle.songs)
        PtTask(RouteKind.challenge, goal.measure, song),
    for (final song in goal.songs) PtTask(RouteKind.live, goal.measure, song),
  ];
  return PtJob(
    id: '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 32)}',
    fingerprint: ptFingerprint(request, dataFingerprint, owner, cycle),
    dataFingerprint: dataFingerprint,
    owner: owner,
    server: server,
    request: request,
    cycle: cycle,
    tasks: tasks,
  );
}

/// The best hit of each song, best first.
List<EngineHit> ptSongRanking(
  PtJob job,
  String measure, [
  RouteKind route = RouteKind.live,
]) {
  final songs = <int, EngineHit>{};
  for (final task in job.tasks) {
    if (task.measure != measure || task.route != route) {
      continue;
    }
    for (final hit in task.result?.hits ?? const <EngineHit>[]) {
      if (hit.song == null || hit.event == null || !hit.event!.mean.isFinite) {
        continue;
      }
      final previous = songs[hit.song!.songId];
      if (previous == null || compareHits(hit, previous) < 0) {
        songs[hit.song!.songId] = hit;
      }
    }
  }
  return stableSorted(songs.values, compareHits);
}

EngineHit? ptChallengeBest(PtJob job, String measure) {
  final tasks = [
    for (final task in job.tasks)
      if (task.route == RouteKind.challenge && task.measure == measure) task,
  ];
  if (tasks.isEmpty || !tasks.every((task) => task.complete)) return null;
  return ptSongRanking(job, measure, RouteKind.challenge).firstOrNull;
}

double? ptCutoff(PtJob job, String measure) {
  final ranking = ptSongRanking(job, measure),
      count = job.scope == 'top-one' ? 1 : 5;
  return ranking.length >= count ? ranking[count - 1].key : null;
}

RewardCutoff? ptTaskCutoff(PtJob job, PtTask task) {
  if (job.scope == 'all' || task.route != RouteKind.live) return null;
  final ranking = ptSongRanking(job, task.measure),
      count = job.scope == 'top-one' ? 1 : 5;
  if (ranking.length < count) return null;
  // Equal rewards remain eligible: their mean score can still improve the rank.
  return RewardCutoff(ranking[count - 1].key, 'gte', job.fingerprint);
}

bool ptAllComplete(PtJob job) =>
    job.tasks.isNotEmpty && job.tasks.every((task) => task.complete);
bool ptComplete(PtJob job) =>
    job.tasks.isNotEmpty &&
    job.tasks.every(
      (task) => task.complete || task.excluded(ptTaskCutoff(job, task)),
    );

/// One CP's long-run reward value as a reduced fraction (`cpExchange`).
CpExchange cpExchangeOf(double rewardSum, int orders, int consumption) {
  final sum = rewardSum.toInt();
  if (sum != rewardSum || sum < 0 || orders < 1 || consumption < 1) {
    throw StateError('pt-invalid-cp-value');
  }
  final denominator = orders * consumption;
  var a = sum, b = denominator;
  while (b != 0) {
    final r = a % b;
    a = b;
    b = r;
  }
  return CpExchange(sum ~/ a, denominator ~/ a);
}

typedef PtEngineRun = Future<EngineResponse> Function(
  EngineRequest request, [
  void Function(int, int)? progress,
  void Function(EngineSnapshot)? snapshot,
]);

class PtRunner {
  PtRunner({
    required this.run,
    required this.cancel,
    required this.changed,
    required this.save,
  });
  final PtEngineRun run;
  final void Function() cancel;
  final void Function(PtJob job) changed;
  final Future<void> Function(PtJob job) save;
  bool running = false;
  bool _stopped = false;

  void stop() {
    _stopped = true;
    cancel();
  }

  Future<void> start(
    PtJob job, {
    bool? topFive,
    String? scope,
    double? deadline,
  }) async {
    deadline ??= executionClock() + 3000;
    if (running) throw StateError('pt-busy');
    running = true;
    _stopped = false;
    job.scope =
        scope ??
        (topFive == null
            ? job.scope
            : topFive
            ? 'top-five'
            : 'all');
    // The page redraws at most four times a second and the checkpoint is
    // written at most once a second; both once more at the end.
    var savedAt = 0, shownAt = 0;
    Future<void> publish([bool force = false]) async {
      job.updatedAt = DateTime.now().millisecondsSinceEpoch;
      if (force || job.updatedAt - shownAt >= 100) {
        shownAt = job.updatedAt;
        changed(job);
      }
      if (!force && job.updatedAt - savedAt < 1000) return;
      savedAt = job.updatedAt;
      await save(job);
    }

    try {
      for (final task in job.tasks) {
        if (!task.complete && !task.excluded(ptTaskCutoff(job, task))) {
          task
            ..status = 'queued'
            ..error = '';
        }
      }
      await publish();
      int flag(bool value) => value ? 1 : 0;
      final tasks = stableSorted(job.tasks, (a, b) {
        var d =
            flag(a.route == RouteKind.live) - flag(b.route == RouteKind.live);
        if (d != 0) return d;
        d = a.song.songId - b.song.songId;
        if (d != 0) return d;
        d = a.song.difficulty - b.song.difficulty;
        if (d != 0) return d;
        return flag(a.measure == 'items') - flag(b.measure == 'items');
      });
      final base = job.request.goal as EventGoal;
      for (final task in tasks) {
        if (_stopped || remaining(deadline) == 0) break;
        if (task.complete || task.excluded(ptTaskCutoff(job, task))) {
          continue;
        }
        final cycle = job.cycle;
        final challenge = cycle != null && task.route == RouteKind.live
            ? ptChallengeBest(job, task.measure)
            : null;
        if (cycle != null &&
            task.route == RouteKind.live &&
            challenge == null) {
          continue;
        }
        task.status = 'running';
        await publish();
        if (_stopped) {
          task.status = 'queued';
          break;
        }
        try {
          final cutoff = ptTaskCutoff(job, task);
          final isChallenge = task.route == RouteKind.challenge;
          final goal = EventGoal(
            measure: task.measure,
            route: task.route,
            eventId: base.eventId,
            songs: [task.song],
            consumption: isChallenge ? cycle!.consumption : base.consumption,
            play: base.play,
            ptOnly: true,
            cpExchange: challenge != null
                ? cpExchangeOf(
                    challenge.event!.rewardSum!,
                    challenge.event!.orders!,
                    cycle!.consumption,
                  )
                : null,
            gekiso: isChallenge ? null : base.gekiso,
          );
          final previous = task.result?.hits ?? <EngineHit>[];
          void accept(EngineResponse response) {
            final result = response.results
                .where((r) => r.song == task.song)
                .firstOrNull;
            if (result == null) return;
            if (result.hits.isEmpty && !result.proven) {
              result.hits = task.result?.hits.isNotEmpty == true
                  ? task.result!.hits
                  : previous;
            }
            if (result.exclusion != null &&
                result.hits.isNotEmpty &&
                result.hits.first.key >= result.exclusion!.key) {
              result.proven = true;
              result.bound = null;
              result.exclusion = null;
            }
            task.result = result;
            if (response.stopReason == 'error') {
              task.status = 'failed';
              task.error = response.error ?? 'engine-error';
              return;
            }
            task.status = result.exclusion != null
                ? 'pruned'
                : result.proven
                ? (result.hits.isNotEmpty ? 'complete' : 'empty')
                : 'partial';
          }

          final request = job.request
              .withGoal(goal, null)
              .copyWith(
                cutoff: cutoff,
                deadline: deadline,
                contextKey: job.fingerprint,
                seeds: previous,
              );
          final response = await run(request, null, (snapshot) {
            if (snapshot.contextKey != job.fingerprint) return;
            final first =
                !job.tasks.any(
                  (entry) => entry.result?.hits.isNotEmpty == true,
                ) &&
                snapshot.response.overall.isNotEmpty;
            accept(snapshot.response);
            publish(first).ignore();
          });
          accept(response);
        } catch (error) {
          if (_stopped) {
            task.status = 'queued';
            break;
          }
          task
            ..status = 'failed'
            ..error = '$error';
        }
        await publish();
      }
    } finally {
      for (final task in job.tasks) {
        if (task.status == 'running') task.status = 'queued';
      }
      running = false;
      await publish(true);
    }
  }
}

/// Device-only job storage, separate from the synced box.
class PtCheckpoint {
  Future<File> _file(String server, String owner) async {
    final dir = await getApplicationSupportDirectory();
    return File(
      p.join(
        dir.path,
        'team-box',
        'pt-${Uri.encodeComponent(owner)}-$server.json',
      ),
    );
  }

  static Future<void> _writes = Future.value();
  Future<void> _write(
    String server,
    String owner,
    String payload, {
    bool result = false,
  }) {
    final pending = _writes.then((_) async {
      final base = await _file(server, owner);
      final file = result ? File('${base.path}.result') : base;
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(payload, flush: true);
      await temp.rename(file.path);
    });
    _writes = pending.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return pending;
  }

  Future<void> save(PtJob job) =>
      _write(job.server, job.owner, jsonEncode(job.toJson()));

  Future<void> saveResult(Doc value) => _write(
    value['server'] as String,
    value['owner'] as String,
    jsonEncode({...value, 'version': 'reward-cycle-result-v1'}),
    result: true,
  );

  Future<Doc?> latestResult(String server, String owner) async {
    await _writes;
    final base = await _file(server, owner), file = File('${base.path}.result');
    if (!await file.exists()) return null;
    final value = objectRow(jsonDecode(await file.readAsString()));
    return value['version'] == 'reward-cycle-result-v1' ? value : null;
  }

  Future<PtJob?> latest(String server, String owner) async {
    await _writes;
    final file = await _file(server, owner);
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString());
    if (json is! Map || json['version'] != ptVersion) return null;
    return PtJob.fromJson(json.cast<String, Object?>());
  }
}
