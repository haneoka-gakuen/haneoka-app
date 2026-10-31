/// The Event rewards tab's state: the strict request built from the box,
/// its unmet inputs, and the recommendation job (`PtController` in
/// `lit/team-builder/pt-tab.ts`).
library;

import 'controller.dart';
import 'engine/api.dart';
import 'engine/box.dart';
import 'engine/live.dart' show ap;
import 'engine/num.dart';
import 'engine/objectives.dart' show CpExchange, RouteKind;
import 'engine/pt_eligibility.dart';
import 'engine/execution.dart' show completeResponse;
import 'engine_client.dart';
import 'pt_recommendation.dart';

/// Where an unmet input is edited (`issueField`).
String? issueField(PtIssue issue) {
  switch (issue.code) {
    case 'practice' || 'player':
      return issue.target;
    case 'constraint':
      return issue.target == 'minBonus' ? 'minBonus' : 'constraints';
    case 'inventory':
      return 'inventory';
    case 'chart':
      return issue.target.startsWith('challenge')
          ? 'challenge-selection'
          : 'selection';
    case 'mode':
      return issue.target == 'gekiso-input' ? 'gekiso-input' : null;
    case 'event':
      return issue.target == 'consumption' ||
              issue.target == 'challenge-consumption'
          ? issue.target
          : 'event';
    case 'skill':
      final card = RegExp(r'^(m\d+|s\d+)(?:[.:/]|$)').firstMatch(issue.target);
      return card == null ? null : '${card[1]}.use';
  }
  return null;
}

class PtController {
  PtController(this.host);
  final TeamBuilderController host;
  final _store = PtCheckpoint();
  PtJob? job;
  bool running = false;
  bool showAll = false;
  String measure = 'points';
  bool storageError = false;
  String error = '';
  bool showIssues = false;
  List<PtIssue> issues = const [];
  String _signature = '';
  String _restoreKey = '';
  int _generation = 0;
  PtRunner? _runner;

  String get owner => host.store?.owner ?? 'local';

  /// The release identities the result depends on.
  String get dataFingerprint {
    final data = host.catalog?.data;
    if (data == null) return '';
    final identities = objectRow(objectRow(data['crossServer'])['identities']);
    return [
      for (final key in identities.keys.toList()..sort())
        '$key:${objectRow(identities[key])['releaseId']}',
    ].join('|');
  }

  EngineRequest? request() {
    final view = host.view, master = host.catalog?.master;
    if (view == null || master == null) return null;
    final s = host.searchSettings;
    final cards = host.engineCards();
    int bySong(SongRef a, SongRef b) => a.songId != b.songId
        ? a.songId - b.songId
        : a.difficulty - b.difficulty;
    return EngineRequest(
      members: cards.members,
      snaps: s.noSnaps ? const [] : cards.snaps,
      player: PlayerInput(
        characterRanks: view.player.characterRanks,
        characterTotalRank: view.player.characterTotalRank,
        bandItems: view.player.bandItems,
        vipRank: view.player.vipRank,
        // The game has no memory growth yet; stored values must not count.
        characterMemory: {for (final id in master.characters.keys) '$id': 0},
        musicMemory: {for (final id in master.songs.keys) '$id': 0},
      ),
      unknownPolicy: UnknownPolicy.min,
      goal: EventGoal(
        ptOnly: true,
        minComboBonus: s.minComboBonus,
        minJustWindowMs: host.hasMission(3, s.songs) ? s.justWindowMs : 0,
        measure: measure,
        route: RouteKind.live,
        eventId: s.eventId ?? -1,
        songs: [...s.songs]..sort(bySong),
        consumption: s.boosts,
        play: ap,
        gekiso: s.ptGekiso
            ? (just: s.ptJust / 100, luckSamples: s.resolvedPtLuckSamples)
            : null,
      ),
      constraints: ConstraintInput(
        requiredMembers: [
          for (final row in view.members.values)
            if (row.lock) 'm${row.cardId}',
        ],
        requiredSnaps: [
          for (final row in view.snaps.values)
            if (row.lock) 's${row.cardId}',
        ],
        leader: s.leader == null ? null : 'm${s.leader}',
        bindings: [
          for (final (member, snap) in s.bindings)
            ('m$member', snap == null ? null : 's$snap'),
        ],
        noSnaps: s.noSnaps,
        minBonusPercent: s.minBonus,
      ),
      k: 1,
      timeLimitMs: 3000,
    );
  }

  PtCycle? cycle() {
    final s = host.searchSettings;
    return s.ptCycle
        ? PtCycle(
            [...s.planChallengeSongs]..sort(
              (a, b) => a.songId != b.songId
                  ? a.songId - b.songId
                  : a.difficulty - b.difficulty,
            ),
            s.challengePoints,
          )
        : null;
  }

  String _inputSignature() =>
      canonical([request()?.toJson(), cycle()?.toJson()]);

  /// Recomputes the unmet inputs when the request changed.
  void sync() {
    final custom = host.activity && host.settings.rewardMode == 'event';
    final request = custom ? host.request() : this.request();
    final master = host.catalog?.master;
    final signature = custom
        ? canonical([
            request?.toJson(),
            host.settings.farming['requireGrowth'],
            owner,
            dataFingerprint,
          ])
        : _inputSignature();
    if (signature == _signature) return;
    _signature = signature;
    issues = const [];
    if (request == null || master == null) return;
    if (custom) {
      if (request.goal is EventGoal &&
          host.settings.farming['requireGrowth'] == true) {
        final input = request.toJson();
        input['k'] = 1;
        input['player'] = {
          ...request.player.toJson(),
          'characterMemory': {
            for (final id in master.characters.keys)
              '$id': request.player.characterMemory['$id'] ?? 0,
          },
        };
        input['goal'] = {
          ...goalJson(request.goal),
          'ranking': 'pt-only',
          'route': 'live',
          'measure': 'points',
          'play': {'great': 0, 'good': 0, 'bad': 0, 'miss': 0},
          'songs': <Object?>[],
        };
        issues = validatePtRequest(master, EngineRequest.fromJson(input))
            .where(
              (issue) => const {
                'practice',
                'player',
                'inventory',
                'constraint',
              }.contains(issue.code),
            )
            .toList();
      }
      return;
    }
    final goal = request.goal as EventGoal;
    final found = <PtIssue>[];
    for (final route in [
      RouteKind.live,
      if (cycle() != null) RouteKind.challenge,
    ]) {
      for (final measure in [goal.measure]) {
        final variant = route == RouteKind.live
            ? goal.copyWith(
                route: route,
                measure: measure,
                cpExchange: CpExchange(0, 1),
              )
            : goal.copyWith(
                route: route,
                measure: measure,
                songs: cycle()!.songs,
                consumption: cycle()!.consumption,
                dropGekiso: true,
              );
        found.addAll(
          validatePtRequest(
            master,
            request.withGoal(variant, null),
          ).where((issue) => issue.code != 'skill'),
        );
      }
    }
    if (cycle() != null && cycle()!.songs.isEmpty) {
      found.add(const PtIssue('chart', 'challenge-selection'));
    }
    issues = {for (final issue in found) issue.key: issue}.values.toList();
  }

  bool get stale {
    final job = this.job;
    return job != null &&
        (canonical([job.request.toJson(), job.cycle?.toJson()]) !=
                _inputSignature() ||
            job.owner != owner ||
            job.dataFingerprint != dataFingerprint);
  }

  /// Loads the device's latest job of this server and owner.
  Future<void> restore() async {
    if (host.catalog == null || host.store == null) return;
    final key = '${host.server}|$owner|$dataFingerprint';
    if (key == _restoreKey) return;
    _restoreKey = key;
    job = null;
    host.ptCompared.clear();
    final generation = ++_generation;
    try {
      final (restored, saved) = await (
        _store.latest(host.server, owner),
        _store.latestResult(host.server, owner),
      ).wait;
      if (generation != _generation) return;
      for (final task in restored?.tasks ?? const <PtTask>[]) {
        if (task.status == 'running') task.status = 'queued';
      }
      job =
          restored?.dataFingerprint == dataFingerprint &&
              restored?.owner == owner
          ? restored
          : null;
      if (host.farmResultMode == null) {
        if (saved != null &&
            saved['dataFingerprint'] == dataFingerprint &&
            saved['owner'] == owner &&
            intOf(saved['updatedAt']) >= (job?.updatedAt ?? 0)) {
          host.restoreFarmingResult(saved);
          host.farmResultMode = 'event';
        } else if (job != null) {
          host.farmResultMode = 'recommendation';
        }
      }
    } catch (_) {
      if (generation != _generation) return;
      storageError = true;
    }
    host.changed();
  }

  Future<void> rememberResult() async {
    final response = host.results,
        request = host.resultInputs,
        settings = host.resultSettings;
    if (response == null ||
        request == null ||
        settings == null ||
        dataFingerprint.isEmpty ||
        !completeResponse(response) ||
        response.stopReason != 'complete') {
      return;
    }
    try {
      await _store.saveResult({
        'server': host.server,
        'owner': owner,
        'dataFingerprint': dataFingerprint,
        'contextKey': host.resultsFor,
        'request': request.toJson(),
        'response': response.toJson(),
        'settings': settings.toJson(),
        'session': host.resultSession,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {
      storageError = true;
    }
  }

  void stop() => _runner?.stop();

  void dispose() {
    ++_generation;
    stop();
  }

  Future<void> start({bool resume = false, bool? topFive}) async {
    sync();
    if (issues.isNotEmpty) {
      showIssues = true;
      host.changed();
      return;
    }
    final request = this.request();
    final engine = host.engine;
    if (request == null ||
        engine == null ||
        host.running ||
        host.manualBusy ||
        dataFingerprint.isEmpty) {
      return;
    }
    final generation = _generation;
    final cycle = this.cycle();
    final signature = _inputSignature();
    running = host.running = true;
    host.farmResultMode = 'recommendation';
    error = '';
    host.changed();
    try {
      var current = job;
      final fingerprint = ptFingerprint(request, dataFingerprint, owner, cycle);
      if (!resume || current == null || current.fingerprint != fingerprint) {
        if (resume) throw StateError('pt-input-changed');
        current = createPtJob(
          request,
          server: host.server,
          dataFingerprint: dataFingerprint,
          owner: owner,
          cycle: cycle,
        );
      }
      if (generation != _generation || signature != _inputSignature()) return;
      job = current;
      final runner = _runner = PtRunner(
        run: engine.run,
        cancel: engine.cancel,
        changed: (next) {
          if (generation != _generation) return;
          job = next;
          host.changed();
        },
        save: (next) async {
          try {
            await _store.save(next);
          } catch (_) {
            if (generation == _generation) {
              storageError = true;
              host.changed();
            }
          }
        },
      );
      await runner.start(current, topFive: topFive, deadline: double.infinity);
    } on EngineCancelled {
      // Stopped by the reader.
    } catch (failure) {
      if (generation == _generation) error = '$failure';
    } finally {
      running = host.running = false;
      host.changed();
    }
  }
}
