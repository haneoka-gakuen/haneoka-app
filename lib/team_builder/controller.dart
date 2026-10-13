/// The team builder's state: release data, the synced box, the Build
/// settings, the engine and its results (`lit/team-builder.ts`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../catalog/visuals.dart';
import '../core/app_state.dart';
import 'box.dart';
import 'catalog.dart';
import 'data.dart';
import 'engine/api.dart';
import 'engine/box.dart';
import 'engine/full/play.dart' show Accuracy;
import 'engine/live.dart';
import 'engine/master.dart';
import 'engine/num.dart';
import 'engine/objectives.dart';
import 'engine_client.dart';
import 'pt_controller.dart';
import 'settings.dart';

Future<EngineMaster> _compileMaster(Doc data) =>
    Isolate.run(() => compileTeamData(data));

class ManualTeam {
  const ManualTeam({
    this.members = const [null, null, null, null, null],
    this.snaps = const [null, null, null, null, null],
    this.leader = 2,
  });
  final List<int?> members;
  final List<int?> snaps;
  final int leader;
  ManualTeam copyWith({List<int?>? members, List<int?>? snaps, int? leader}) =>
      ManualTeam(
        members: members ?? this.members,
        snaps: snaps ?? this.snaps,
        leader: leader ?? this.leader,
      );
}

class TeamBuilderController extends ChangeNotifier {
  TeamBuilderController(this.state);
  final AppState state;

  TeamCatalog? catalog;
  BoxStore? store;
  BoxView? view;
  EngineClient? engine;
  BuildSettings settings = BuildSettings(const {});
  Object? loadError;
  String _server = '';
  int _boxVersion = -1;

  EngineResponse? results;
  BuildSettings? resultSettings;
  bool activity = false;
  BuildSettings get searchSettings =>
      activity && settings.rewardMode != 'recommendation'
      ? settings.copyWith({'goal': settings.rewardMode})
      : settings;
  String resultsFor = '';
  bool running = false;
  int runGeneration = 0;
  (int, int)? progress;
  String? error;

  late final pt = PtController(this);

  ManualTeam manual = const ManualTeam();
  List<TeamEvaluation>? manualResults;
  bool manualBusy = false;

  String tb(
    String key,
    String fallback, [
    Map<String, Object?> values = const {},
  ]) => state.text('tools.teamBuilder.$key', fallback, values);

  Future<void> load() async {
    final server = state.server;
    if (_server == server && catalog != null) return;
    _server = server;
    loadError = null;
    notifyListeners();
    try {
      final data = await loadTeamData(server);
      final master = await _compileMaster(data);
      final visuals = await CatalogVisuals.of(state.api)
          .then<CatalogVisuals?>((v) => v, onError: (Object _) => null);
      if (_server != server) return;
      catalog = TeamCatalog(state, data, master, visuals);
      engine?.dispose();
      engine = EngineClient(data, catalog!.chartUrl)..warm();
      store?.removeListener(_adopt);
      store?.dispose();
      store = BoxStore(server)..addListener(_adopt);
      await store!.start();
      _adopt();
    } catch (error) {
      if (_server == server) {
        loadError = error;
        _server = '';
      }
    }
    notifyListeners();
  }

  void _adopt() {
    final box = store;
    if (box == null) return;
    if (box.version != _boxVersion) {
      _boxVersion = box.version;
      view = BoxView.read(box.entries);
      final stored = view!.prefs['build'];
      if (stored is Map) {
        settings = BuildSettings(stored.cast<String, Object?>());
      }
    }
    notifyListeners();
    pt.restore();
  }

  @override
  void dispose() {
    pt.dispose();
    store?.removeListener(_adopt);
    store?.dispose();
    engine?.dispose();
    super.dispose();
  }

  /// Box writes: applied locally at once, synced in the background.
  bool write(List<(String, Object?)> changes) {
    if (store == null || changes.isEmpty) return false;
    try {
      store!.set(changes);
      return true;
    } catch (_) {
      error = tb('saveRejected', 'That value cannot be saved.');
      notifyListeners();
      return false;
    }
  }

  void updateSettings(Doc patch) {
    settings = settings.copyWith(patch);
    write([('pref.build', settings.toJson())]);
    notifyListeners();
  }

  /// Cards taking part in a search, after the candidate filters.
  ({List<MemberInput> members, List<SnapInput> snaps}) engineCards() {
    final catalog = this.catalog, view = this.view;
    if (catalog == null || view == null) return (members: [], snaps: []);
    final master = catalog.master;
    final s = settings;
    final base = s.theoretical
        ? theoreticalInputs(master)
        : view.engineInputs();
    bool memberOk(int id) {
      final card = master.members[id];
      return card != null &&
          (s.attributes.isEmpty || s.attributes.contains(card.cardType)) &&
          (s.bands.isEmpty || s.bands.contains(card.bandId)) &&
          card.rarity >= s.minRarity;
    }

    bool snapOk(int id) {
      final card = master.snaps[id];
      return card != null &&
          (s.attributes.isEmpty || s.attributes.contains(card.cardType)) &&
          card.rarity >= s.minRarity;
    }

    return (
      members: [
        for (final row in base.members)
          if (memberOk(row.cardId)) row,
      ],
      snaps: [
        for (final row in base.snaps)
          if (snapOk(row.cardId)) row,
      ],
    );
  }

  PlayModel get play => settings.allPerfect
      ? ap
      : PlayModel(
          great: settings.great / 100,
          good: settings.good / 100,
          miss: settings.miss / 100,
          missEvery: settings.missEvery.toDouble(),
        );

  Goal? goal() {
    final s = searchSettings;
    final challengeId = s.challengeRules && s.eventId != null
        ? s.eventId
        : null;
    final criterion =
        Criterion.values.where((c) => c.name == s.criterion).firstOrNull ??
        Criterion.mean;
    switch (s.goal) {
      case GoalKind.power:
        return PowerGoal(s.powerSong ? s.songs.firstOrNull : null, challengeId);
      case GoalKind.score:
        return s.songs.isEmpty
            ? null
            : ScoreGoal(s.songs, criterion, play, challengeId);
      case GoalKind.gekiso:
        return s.songs.isEmpty
            ? null
            : GekisoGoal(
                songs: s.songs,
                criterion: criterion,
                accuracy: Accuracy(
                  great: s.allPerfect ? 0 : s.great / 100,
                  just: s.just / 100,
                  missEvery: s.allPerfect ? 0 : s.missEvery,
                ),
                rank: s.gekisoRank,
              );
      case GoalKind.event:
        if (s.eventId == null) return null;
        if (s.route != 'skip' && s.songs.isEmpty) return null;
        return EventGoal(
          ranking: s.fullRanking ? null : 'primary',
          measure: s.measure,
          route: RouteKind.values.byName(s.route),
          eventId: s.eventId!,
          songs: s.route == 'skip' ? const [] : s.songs,
          consumption: s.route == 'challenge' ? s.challengePoints : s.boosts,
          play: play,
        );
      case GoalKind.potential:
        return PotentialGoal(s.window.toDouble());
      case GoalKind.plan:
        if (s.eventId == null ||
            s.songs.isEmpty ||
            s.planChallengeSongs.isEmpty) {
          return null;
        }
        return PlanGoal(
          eventId: s.eventId!,
          normalSongs: s.songs,
          challengeSongs: s.planChallengeSongs,
          boostsPerLive: s.planBoostsPerLive,
          boostBudget: s.planBudget,
          startingChallengePoints: s.planStartingCp,
          challengePointsPerLive: s.challengePoints,
          play: play,
        );
    }
  }

  EngineRequest? request() {
    final goal = this.goal();
    final view = this.view;
    if (goal == null || view == null) return null;
    final cards = engineCards();
    final s = settings;
    final memberKeys = {for (final row in cards.members) row.key};
    final snapKeys = {for (final row in cards.snaps) row.key};
    List<String> locked(bool members) => s.theoretical
        ? const []
        : [
            for (final row
                in members ? view.members.values : const <OwnedMember>[])
              if (row.use && row.lock) 'm${row.cardId}',
            for (final row in members ? const <OwnedSnap>[] : view.snaps.values)
              if (row.use && row.lock) 's${row.cardId}',
          ];
    return EngineRequest(
      members: cards.members,
      snaps: cards.snaps,
      player: view.player,
      unknownPolicy: s.theoretical || s.unknownPolicy == 'max'
          ? UnknownPolicy.max
          : UnknownPolicy.min,
      goal: goal,
      constraints: ConstraintInput(
        requiredMembers: [
          for (final key in locked(true))
            if (memberKeys.contains(key)) key,
        ],
        requiredSnaps: [
          for (final key in locked(false))
            if (snapKeys.contains(key)) key,
        ],
        leader: s.leader != null && memberKeys.contains('m${s.leader}')
            ? 'm${s.leader}'
            : null,
        bindings: [
          for (final (member, snap) in s.bindings)
            if (memberKeys.contains('m$member'))
              ('m$member', snap == null ? null : 's$snap'),
        ],
        noSnaps: s.noSnaps,
        minBonusPercent: goal is EventGoal || goal is PlanGoal
            ? s.minBonus
            : null,
      ),
      k: s.k,
      timeLimitMs: s.timeLimit != null && s.timeLimit! > 0
          ? s.timeLimit! * 1000.0
          : null,
    );
  }

  Object? _contextStamp;
  String _contextValue = '';

  /// What the request depends on, to tell stale results.
  String _fingerprint() {
    final stamp = (
      settings,
      catalog,
      view,
      store?.owner,
      state.server,
      activity,
    );
    if (stamp == _contextStamp) return _contextValue;
    _contextStamp = stamp;
    final request = this.request();
    if (request == null) return _contextValue = '';
    return _contextValue = jsonEncode([
      store?.owner,
      state.server,
      catalog?.data['identity'],
      objectRow(catalog?.data['crossServer'])['identities'],
      request.toJson(),
    ]);
  }

  bool get stale => results != null && resultsFor != _fingerprint();

  Future<void> run({bool resume = false}) async {
    var request = this.request();
    final engine = this.engine;
    if (request == null || engine == null || running) return;
    final fingerprint = _fingerprint();
    if (resume) {
      request = request.copyWith(
        deadline: double.infinity,
        keepTimeLimit: false,
      );
    }
    if (resume && results != null && !stale) {
      request = request.copyWith(
        seeds: [for (final r in results!.results) ...r.hits],
        completed: results!.results.where((r) => r.proven).toList(),
      );
    }
    final settings = searchSettings;
    final generation = ++runGeneration;
    running = true;
    error = null;
    progress = (0, 1);
    notifyListeners();
    try {
      final response = await engine.run(
        request.copyWith(contextKey: fingerprint),
        (done, total) {
          if (generation != runGeneration || fingerprint != _fingerprint()) {
            return;
          }
          progress = (done, total);
          notifyListeners();
        },
        (snapshot) {
          if (generation != runGeneration || fingerprint != _fingerprint()) {
            return;
          }
          if (snapshot.response.stopReason == 'error') {
            error = tb('searchFailed', 'The search failed: {reason}', {
              'reason': snapshot.response.error ?? 'engine-error',
            });
          }
          results = snapshot.response;
          resultsFor = fingerprint;
          resultSettings = settings;
          notifyListeners();
        },
      );
      if (generation == runGeneration && fingerprint == _fingerprint()) {
        if (response.stopReason == 'error') {
          error = tb('searchFailed', 'The search failed: {reason}', {
            'reason': response.error ?? 'engine-error',
          });
        }
        results = response;
        resultsFor = fingerprint;
        resultSettings = settings;
      }
    } on EngineCancelled {
      // Cancelled by the reader.
    } catch (failure) {
      error = tb('searchFailed', 'The search failed: {reason}', {
        'reason': '$failure',
      });
    } finally {
      if (generation == runGeneration) {
        running = false;
        progress = null;
        notifyListeners();
      }
    }
  }

  void cancel() {
    pt.stop();
    engine?.cancel();
  }

  /// Repaints after a change made outside the controller's own methods.
  void changed() => notifyListeners();

  /// Saves a formation to Teams; the leader comes first.
  void saveTeam(
    List<int> members,
    List<int?> snaps,
    SongRef? song, [
    String? name,
  ]) {
    final catalog = this.catalog!;
    final random = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final label =
        name ??
        '${catalog.characterName(catalog.characterIds(true, members.first).firstOrNull ?? 0)} · '
            '${song != null ? catalog.songTitle(song.songId) : tb('noSong', 'No song')}';
    write([
      (
        'team.$random',
        {
          'name': label.length > 80 ? label.substring(0, 80) : label,
          'members': members,
          'snaps': snaps,
          'leader': members.firstOrNull,
          'song': song?.toJson(),
          'createdAt': DateTime.now().millisecondsSinceEpoch,
        },
      ),
    ]);
  }
}
