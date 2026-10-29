/// The team builder's state: release data, the synced box, the Build
/// settings, the engine and its results (`lit/team-builder.ts`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../catalog/visuals.dart';
import '../catalog/catalog_query.dart';
import '../core/app_state.dart';
import 'box.dart';
import 'arena_state.dart';
import 'manual_event.dart';
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
import 'team_growth.dart';
import 'song_comparison.dart';
import 'result_comparison.dart';
import 'pt_recommendation.dart' show PtJob;

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

class _TaskResults {
  const _TaskResults(
    this.results,
    this.settings,
    this.input,
    this.fingerprint,
    this.session,
    this.compared,
  );
  final EngineResponse? results;
  final BuildSettings? settings;
  final EngineRequest? input;
  final String fingerprint, session;
  final List<ComparedResult> compared;
}

class TeamBuilderController extends ChangeNotifier {
  TeamBuilderController(this.state, {this.serverOverride});
  final AppState state;
  final String? serverOverride;
  String get server => serverOverride ?? state.server;

  TeamCatalog? catalog;
  BoxStore? store;
  BoxView? view;
  EngineClient? engine;
  BuildSettings settings = BuildSettings(const {});
  Object? loadError;
  String _server = '';
  bool _disposed = false;
  Object? _boxVersion;

  EngineResponse? results;
  BuildSettings? resultSettings;
  EngineRequest? resultInputs;
  bool _activity = false;
  bool _arenaActive = false;
  Doc arenaDraft = arenaDefaults();
  Timer? _arenaTimer;
  bool get arenaActive => _arenaActive;
  ArenaState get arena => ArenaState(catalog!, server, arenaDraft);
  bool get activity => _activity;
  set activity(bool value) => activate(value ? 'pt' : 'build');
  void activate(String task) {
    final nextActivity = task == 'pt', nextArena = task == 'arena';
    if (_activity == nextActivity && _arenaActive == nextArena) return;
    _saveTaskResults();
    _activity = nextActivity;
    _arenaActive = nextArena;
    _restoreTaskResults();
    _checkActiveContext();
  }

  void updateArena(Doc patch) {
    if (patch['automatic'] == false &&
        arenaDraft['automatic'] != false &&
        arenaDraft['customized'] != true &&
        !patch.containsKey('rule')) {
      patch = {...patch, 'rule': arena.rule};
    }
    arenaDraft = {...arenaDraft, ...patch};
    write([('pref.arena', arenaDraft)]);
    _scheduleArena();
    _checkActiveContext();
    notifyListeners();
  }

  void _scheduleArena() {
    _arenaTimer?.cancel();
    if (catalog == null) return;
    final next = arena.nextAt;
    if (next == null) return;
    _arenaTimer = Timer(
      Duration(
        milliseconds: (next - DateTime.now().millisecondsSinceEpoch + 50).clamp(
          1,
          2147483647,
        ),
      ),
      () {
        _contextStamp = null;
        _checkActiveContext();
        _scheduleArena();
        notifyListeners();
      },
    );
  }

  String resultSession = '';
  List<ComparedResult> compared = [];
  List<ComparedResult> ptCompared = [];
  String ptComparisonSession = '';
  int comparisonCandidate = 1;
  final _taskResults = <String, _TaskResults>{};
  String get _taskKey => arenaActive
      ? 'arena'
      : !activity
      ? 'build'
      : settings.rewardMode == 'plan'
      ? 'plan'
      : 'event';
  void _saveTaskResults([String? key]) {
    _taskResults[key ?? _taskKey] = _TaskResults(
      results,
      resultSettings,
      resultInputs,
      resultsFor,
      resultSession,
      compared,
    );
  }

  void _restoreTaskResults() {
    final previous = _taskResults[_taskKey];
    results = previous?.results;
    resultSettings = previous?.settings;
    resultInputs = previous?.input;
    resultsFor = previous?.fingerprint ?? '';
    resultSession = previous?.session ?? '';
    compared = previous?.compared ?? [];
  }

  BuildSettings settingsForHit(EngineHit hit) {
    final s = resultSettings ?? settings;
    if (s.goal != GoalKind.plan) return s;
    final challenge = identical(results?.plan?.challenge, hit);
    return s
        .copyWith({
          'route': challenge ? 'challenge' : 'live',
          'measure': 'points',
          'boosts': s.planBoostsPerLive,
          'ptCycle': false,
        })
        .forGoal(GoalKind.event);
  }

  ComparedResult? ptCompareEntry(EngineHit hit, PtJob job, int position) {
    final task = job.tasks
        .where(
          (task) =>
              task.result?.hits.any((candidate) => identical(candidate, hit)) ==
              true,
        )
        .firstOrNull;
    if (task == null) return null;
    final goal = job.request.goal as EventGoal;
    final s = BuildSettings({
      'goal': 'event',
      'eventId': goal.eventId,
      'measure': task.measure,
      'route': task.route.name,
      'boosts': goal.consumption,
      'challengePoints': job.cycle?.consumption ?? 200,
      'ptCycle': job.cycle != null,
      'ptMode': goal.gekiso == null ? 'solo' : 'gekiso',
      'minComboBonus': goal.minComboBonus,
    }).forGoal(GoalKind.event);
    return ComparedResult(
      hit: EngineHit.fromJson(hit.toJson()),
      settings: s,
      input: job.request,
      identity: job.dataFingerprint,
      session: job.id,
      position: position,
    );
  }

  void syncPtCompared(PtJob job) {
    if (ptComparisonSession != job.id) {
      ptComparisonSession = job.id;
      ptCompared = [];
    }
    final hits = job.tasks
        .expand((task) => task.result?.hits ?? <EngineHit>[])
        .toList();
    ptCompared = [
      for (final old in ptCompared)
        () {
          final hit = hits
              .where((hit) => ptCompareEntry(hit, job, 0)?.id == old.id)
              .firstOrNull;
          return hit == null
              ? (old..listed = false)
              : ptCompareEntry(hit, job, old.position)!;
        }(),
    ];
  }

  void togglePtCompared(EngineHit hit, PtJob job, int position) {
    syncPtCompared(job);
    final entry = ptCompareEntry(hit, job, position);
    if (entry == null) return;
    final old = ptCompared.indexWhere((row) => row.id == entry.id);
    if (old >= 0) {
      ptCompared.removeAt(old);
    } else if (ptCompared.length < 3) {
      ptCompared.add(entry);
    } else {
      error = tb(
        'comparisonLimit',
        'Select up to 3 candidates from this search.',
      );
    }
    changed();
  }

  ComparedResult? compareEntry(EngineHit hit, int position) {
    final input = resultInputs, s = settingsForHit(hit);
    if (input == null) return null;
    return ComparedResult(
      hit: EngineHit.fromJson(hit.toJson()),
      settings: BuildSettings(s.toJson()).forGoal(s.goal),
      input: input,
      identity: catalog?.data['identity'],
      session: resultSession,
      position: position,
      placements: results?.results
          .where((row) => row.song == hit.song)
          .firstOrNull
          ?.placements,
    );
  }

  void toggleCompared(EngineHit hit, int position) {
    final entry = compareEntry(hit, position);
    if (entry == null) return;
    final existing = compared.indexWhere((row) => row.id == entry.id);
    if (existing >= 0) {
      compared.removeAt(existing);
    } else if (compared.length < 3) {
      compared.add(entry);
    } else {
      error = tb(
        'comparisonLimit',
        'Select up to 3 candidates from this search.',
      );
    }
    changed();
  }

  void syncCompared() {
    final hits = results?.plan != null
        ? [?results!.plan!.normal, ?results!.plan!.challenge]
        : results?.results.expand((row) => row.hits).toList() ?? <EngineHit>[];
    compared = [
      for (final selected in compared)
        () {
          final hit = hits
              .where((row) => compareEntry(row, 0)?.id == selected.id)
              .firstOrNull;
          return hit == null
              ? (selected..listed = false)
              : compareEntry(hit, hits.indexOf(hit) + 1)!;
        }(),
    ];
  }

  BuildSettings get _contextSettings => arenaActive && catalog != null
      ? arena.settings
      : !activity
      ? settings
      : settings.rewardMode == 'plan'
      ? settings.forGoal(GoalKind.plan)
      : settings.forFarming();

  List<int>? get allowedSongIds {
    final s = _contextSettings, catalog = this.catalog;
    if (arenaActive && catalog != null) return arena.songIds;
    if (catalog == null || s.eventId == null) return null;
    final goal = activity ? settings.rewardMode : s.goal.name;
    final challenge = goal == 'event'
        ? s.route == 'challenge'
        : (goal == 'score' || goal == 'power') && s.challengeRules;
    if (challenge) {
      return [
        for (final row in catalog.challengeSongs(s.eventId)) row.liveMusicId,
      ];
    }
    final normalEvent = const {
      'event',
      'plan',
      'recommendation',
    }.contains(goal);
    return normalEvent ? catalog.normalEventSongIds(s.eventId) : null;
  }

  bool hasMission(int mission, [List<SongRef>? selected]) =>
      _missionEnabled(_contextSettings, mission, selected);
  bool _missionEnabled(
    BuildSettings s,
    int mission, [
    List<SongRef>? selected,
  ]) {
    final rules =
        s.arena ??
        (s.songRulesOverride == null
            ? null
            : {
                'musicType': s.songRulesOverride!.musicType,
                'missions': s.songRulesOverride!.missions,
              });
    final overrides = intListOf(rules?['missions']);
    return (selected ?? s.songs).any((song) {
      final original =
          catalog?.master.songs[song.songId]?.gekisoMissions ?? const <int>[];
      return [
        for (var i = 0; i < 3; i++)
          overrides.elementAtOrNull(i) != null && overrides[i] != 0
              ? overrides[i]
              : original.elementAtOrNull(i) ?? 0,
      ].contains(mission);
    });
  }

  Doc? songRulesFor(BuildSettings s, {bool gekiso = true}) {
    final rule = s.songRulesOverride;
    if (rule == null) return null;
    final missions = gekiso ? rule.missions : [0, 0, 0];
    return rule.musicType != 0 || missions.any((value) => value != 0)
        ? {'musicType': rule.musicType, 'missions': missions}
        : null;
  }

  List<Doc>? manualEventEffects(BuildSettings s) => s.manualEventEnabled
      ? resolveManualEvent(catalog!.master, s.manualEvent).effects
      : null;

  BuildSettings get searchSettings {
    var s = _contextSettings;
    final catalog = this.catalog;
    if (s.shared &&
        !arenaActive &&
        (s.goal == GoalKind.score || s.goal == GoalKind.gekiso)) {
      s = s.copyWith({
        'criterion': 'mean',
        'scoreTarget': 'none',
        'gekisoPlacementMode': 'rank',
      });
    }
    if (catalog == null || s.eventId == null) return s;
    final allowed = allowedSongIds?.toSet();
    final challenges = {
      for (final row in catalog.challengeSongs(s.eventId)) row.liveMusicId,
    };
    return s.copyWith({
      'songs': [
        for (final song in s.songs)
          if ((allowed == null || allowed.contains(song.songId)) &&
              catalog.available('songs', song.songId) &&
              catalog.difficultyRow(song.songId, song.difficulty)?['file']
                  is String)
            song.toJson(),
      ],
      'planChallengeSongs': [
        for (final song in s.planChallengeSongs)
          if (challenges.contains(song.songId)) song.toJson(),
      ],
    });
  }

  String resultsFor = '';
  bool running = false;
  int runGeneration = 0;
  (int, int)? progress;
  String? error;
  Doc? growth;
  String growthContext = '';
  (int, int) growthProgress = (0, 0);
  bool growthRunning = false;
  bool get currentGrowth => growthContext == _fingerprint();

  late final training = TeamGrowthService(this);
  Object? _auxiliaryTask;
  Object? acquireAuxiliaryTask() {
    if (running || _disposed) return null;
    final task = _auxiliaryTask = Object();
    running = true;
    notifyListeners();
    return task;
  }

  bool ownsAuxiliaryTask(Object task) =>
      !_disposed && identical(_auxiliaryTask, task);
  void releaseAuxiliaryTask(Object task) {
    if (!ownsAuxiliaryTask(task)) return;
    _auxiliaryTask = null;
    running = false;
    notifyListeners();
  }

  late final pt = PtController(this);
  late final comparison = SongComparison(this);

  ManualTeam manual = const ManualTeam();
  List<TeamEvaluation>? manualResults;
  bool manualBusy = false;
  ({int slot, List<EngineHit> hits})? manualSuggestions;
  int manualSuggesting = -1;
  String? manualSuggestionsContext;
  int manualGeneration = 0;
  bool _manualSuggestion = false;
  String? activeManualContext;
  String? _manualResultsContext;
  List<SongRef> get manualSongs => settings.songs
      .where(
        (song) =>
            catalog?.available('songs', song.songId) == true &&
            catalog?.difficultyRow(song.songId, song.difficulty)?['file']
                is String,
      )
      .toList();
  String get manualContext {
    if (view == null || catalog == null) return '';
    final selected = manualInputs();
    return jsonEncode([
      store?.owner,
      catalog?.data['identity'],
      catalog?.data['crossServer'],
      manual.members,
      manual.snaps,
      manual.leader,
      selected.members.map((row) => row.toJson()).toList(),
      selected.snaps.map((row) => row.toJson()).toList(),
      selected.player.toJson(),
      goalJson(manualGoal()!),
      songRulesFor(settings, gekiso: settings.manualScoreMode == 'gekiso'),
    ]);
  }

  String get manualSuggestionContext => jsonEncode([
    manualContext,
    engineCards().members.map((row) => row.toJson()).toList(),
    engineCards().snaps.map((row) => row.toJson()).toList(),
    view?.engineInputs(true).members.map((row) => row.toJson()).toList(),
    view?.engineInputs(true).snaps.map((row) => row.toJson()).toList(),
  ]);
  int beginManual({bool suggestion = false}) {
    _manualSuggestion = suggestion;
    activeManualContext = suggestion ? manualSuggestionContext : manualContext;
    if (!suggestion) _manualResultsContext = manualContext;
    manualBusy = running = true;
    return ++manualGeneration;
  }

  void endManual(int generation) {
    if (generation == manualGeneration) {
      manualBusy = running = false;
      activeManualContext = null;
      changed();
    }
  }

  ({
    List<MemberInput> members,
    List<SnapInput> snaps,
    PlayerInput player,
    UnknownPolicy policy,
  })
  manualInputs() {
    final owned = view!.engineInputs(true), all = catalog!.fullGrowthInputs;
    return (
      members: [
        for (final id in manual.members)
          if (id != null)
            ?owned.members.where((row) => row.cardId == id).firstOrNull ??
                (settings.theoretical
                    ? all.members.where((row) => row.cardId == id).firstOrNull
                    : null),
      ],
      snaps: [
        for (final id in manual.snaps)
          if (id != null)
            ?owned.snaps.where((row) => row.cardId == id).firstOrNull ??
                (settings.theoretical
                    ? all.snaps.where((row) => row.cardId == id).firstOrNull
                    : null),
      ],
      player: view!.player,
      policy: settings.unknownPolicy == 'min'
          ? UnknownPolicy.min
          : UnknownPolicy.max,
    );
  }

  Goal? manualGoal() {
    final rules = settings.songRulesOverride;
    bool mission(int index) => _missionEnabled(settings, index, manualSongs);
    if (settings.manualScoreMode != 'gekiso') {
      return ScoreGoal(
        manualSongs,
        Criterion.mean,
        play,
        settings.challengeRules ? settings.eventId : null,
      );
    }
    return GekisoGoal(
      songs: manualSongs,
      criterion: Criterion.mean,
      accuracy: Accuracy(
        great: settings.allPerfect ? 0 : settings.great / 100,
        just: mission(3) ? settings.just / 100 : 1,
        missEvery: settings.allPerfect ? 0 : settings.missEvery,
      ),
      rank: settings.gekisoRank,
      seeds: mission(2) ? settings.gekisoSeeds : 0,
      musicType: rules?.musicType,
      missions: rules?.missions,
    );
  }

  String tb(
    String key,
    String fallback, [
    Map<String, Object?> values = const {},
  ]) => state.text('tools.teamBuilder.$key', fallback, values);

  Future<void> load() async {
    await CatalogQueryEngine.loadAliases();
    if (_disposed) return;
    final server = this.server;
    if (_server == server && catalog != null) return;
    _server = server;
    loadError = null;
    notifyListeners();
    try {
      final data = await loadTeamData(server);
      if (_disposed || _server != server) return;
      final songVisuals = loadTeamSongVisuals(data, state.apiFor);
      final (master, visuals) = await (
        _compileMaster(data),
        CatalogVisuals.of(state.apiFor(server))
            .then<CatalogVisuals?>((v) => v, onError: (Object _) => null),
      ).wait;
      if (_disposed || _server != server) return;
      final current = TeamCatalog(state, data, master, visuals, server: server);
      catalog?.dispose();
      catalog = current;
      unawaited(
        songVisuals.then((rows) {
          if (_disposed || _server != server || !identical(catalog, current)) {
            return;
          }
          current.updateSongVisuals(rows);
          notifyListeners();
        }),
      );
      engine?.dispose();
      engine = EngineClient(data, catalog!.chartUrl)..warm();
      store?.removeListener(_adopt);
      store?.dispose();
      store = BoxStore(server)..addListener(_adopt);
      await store!.start();
      if (_disposed || _server != server) return;
      _adopt();
    } catch (error) {
      if (_server == server) {
        loadError = error;
        _server = '';
      }
    }
    if (!_disposed) notifyListeners();
  }

  void _adopt() {
    final box = store;
    if (box == null) return;
    final version = (box, box.owner, box.version);
    if (version != _boxVersion) {
      _boxVersion = version;
      view = BoxView.read(box.entries);
      arenaDraft = {...arenaDefaults(), ...objectRow(view!.prefs['arena'])};
      _contextStamp = null;
      _scheduleArena();
      final stored = view!.prefs['build'];
      if (stored is Map) {
        settings = BuildSettings(stored.cast<String, Object?>());
      }
    }
    notifyListeners();
    pt.restore();
    comparison.restore();
    _checkActiveContext();
  }

  @override
  void dispose() {
    _arenaTimer?.cancel();
    catalog?.dispose();
    _disposed = true;
    _server = '';
    ++runGeneration;
    pt.dispose();
    comparison.stop();
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
    if (arenaActive) {
      updateArena({
        'build': {...objectRow(arenaDraft['build']), ...patch},
      });
      return;
    }
    final task = _taskKey;
    _saveTaskResults(task);
    if (activity &&
        settings.rewardMode != 'plan' &&
        !patch.containsKey('rewardMode')) {
      final farm = {
        ...settings.farming,
        ...objectRow(patch['farming']),
        for (final key in BuildSettings.farmingDefaults.keys)
          if (patch.containsKey(key)) key: patch[key],
        if (patch.containsKey('route'))
          'play': patch['route'] == 'live' ? 'solo' : patch['route'],
        if (patch.containsKey('ptMode')) 'play': patch['ptMode'],
      };
      patch = {...patch, 'farming': farm};
    }
    settings = settings.copyWith(patch);
    if (_taskKey != task) _restoreTaskResults();
    _checkActiveContext();
    write([('pref.build', settings.toJson())]);
    notifyListeners();
  }

  /// Cards taking part in a search, after the candidate filters.
  ({List<MemberInput> members, List<SnapInput> snaps}) engineCards() {
    final catalog = this.catalog, view = this.view;
    if (catalog == null || view == null) return (members: [], snaps: []);
    final master = catalog.master;
    final s = _contextSettings;
    final base = s.theoretical ? catalog.fullGrowthInputs : view.engineInputs();
    final fixedMembers = <int>{
      if (!s.theoretical)
        ...view.members.values
            .where((row) => row.use && row.lock)
            .map((row) => row.cardId),
      ...s.bindings.map((pair) => pair.$1),
      if (s.leader != null) s.leader!,
    };
    final fixedSnaps = <int>{
      if (!s.theoretical)
        ...view.snaps.values
            .where((row) => row.use && row.lock)
            .map((row) => row.cardId),
      for (final pair in s.bindings) ?pair.$2,
    };
    bool memberOk(int id) {
      final card = master.members[id];
      return card != null &&
          (!arenaActive ||
              card.bandId == arena.bandId &&
                  catalog.available('members', id) &&
                  arenaReleased(
                    objectRow(catalog.card(true, id)['catalogMetadata']),
                    DateTime.now().millisecondsSinceEpoch,
                  )) &&
          (fixedMembers.contains(id) ||
              (s.attributes.isEmpty || s.attributes.contains(card.cardType)) &&
                  (s.bands.isEmpty || s.bands.contains(card.bandId)) &&
                  card.rarity >= s.minRarity);
    }

    bool snapOk(int id) {
      final card = master.snaps[id];
      return card != null &&
          (!arenaActive ||
              catalog.available('snapshots', id) &&
                  arenaReleased(
                    objectRow(catalog.card(false, id)['catalogMetadata']),
                    DateTime.now().millisecondsSinceEpoch,
                  )) &&
          (fixedSnaps.contains(id) ||
              (s.attributes.isEmpty || s.attributes.contains(card.cardType)) &&
                  card.rarity >= s.minRarity);
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

  PlayModel get play {
    final s = _contextSettings;
    return s.allPerfect
        ? ap
        : PlayModel(
            great: s.great / 100,
            good: s.good / 100,
            miss: s.miss / 100,
            missEvery: s.missEvery.toDouble(),
          );
  }

  String? get inputIssue {
    if (catalog == null || view == null) {
      return tb('loadingData', 'Loading card data');
    }
    final s = searchSettings;
    if (arenaActive && arena.automatic && arena.regulation == null) {
      return tb('arena.needRules', 'Choose custom rules or an active league');
    }
    if (s.goal == GoalKind.event && s.manualEventEnabled) {
      if (objectRow(
            objectRow(
              objectRow(catalog!.data['crossServer'])['owners'],
            )['events'],
          )['${s.eventId}'] !=
          server) {
        return tb('manualEvent.need.rules', 'Choose complete reference rules');
      }
      final issue = resolveManualEvent(catalog!.master, s.manualEvent).issue;
      if (issue != null) {
        return tb('manualEvent.need.$issue', 'Complete the event bonus');
      }
    }
    if (s.goal == GoalKind.power && s.powerSong && s.songs.isEmpty) {
      return tb('needSongs', 'Choose at least one song.');
    }
    if (view != null && catalog != null) {
      final cards = engineCards();
      final fixed = <int>{
        if (!s.theoretical)
          ...view!.members.values
              .where((row) => row.use && row.lock)
              .map((row) => row.cardId),
        ...s.bindings.map((pair) => pair.$1),
        if (s.leader != null) s.leader!,
      };
      final snaps = <int>{
        if (!s.theoretical)
          ...view!.snaps.values
              .where((row) => row.use && row.lock)
              .map((row) => row.cardId),
        for (final pair in s.bindings) ?pair.$2,
      };
      final characters = fixed
          .map((id) => catalog!.master.members[id]?.characterId)
          .toList();
      if (fixed.length > 5 || characters.toSet().length != characters.length) {
        return tb(
          'fixedConflict',
          'Fixed members must be at most five different characters',
        );
      }
      if (fixed.any((id) => !cards.members.any((row) => row.cardId == id)) ||
          snaps.any((id) => !cards.snaps.any((row) => row.cardId == id))) {
        return tb(
          'fixedUnavailable',
          'A fixed card is unavailable in this selection',
        );
      }
      if (snaps.length > 5 ||
          s.bindings.map((pair) => pair.$1).toSet().length !=
              s.bindings.length ||
          s.bindings.map((pair) => pair.$2).whereType<int>().toSet().length !=
              s.bindings.where((pair) => pair.$2 != null).length) {
        return tb(
          'fixedBindingConflict',
          'Fixed Snapshots or bindings conflict',
        );
      }
      if (s.noSnaps && snaps.isNotEmpty) {
        return tb(
          'fixedSnapConflict',
          'Remove fixed Snapshots or allow Snapshots',
        );
      }
    }
    if (s.goal == GoalKind.score &&
        s.scoreTarget != 'none' &&
        (s.targetScore == null || s.targetScore! <= 0)) {
      return tb('needTargetScore', 'Enter a positive target score');
    }
    if (s.goal == GoalKind.gekiso) {
      if (s.opponentsMode && hasMission(2, s.songs)) {
        return tb(
          'opponentsLuck',
          'This chart does not support opponent scores',
        );
      }
      if (s.minComboBonus < 1) {
        return tb('invalidCombo', 'Enter a positive integer');
      }
      if (s.opponentsMode) {
        final ranges = s.opponentDrafts
            .map(
              (text) => text.trim().isEmpty
                  ? <String>[]
                  : text.trim().split(RegExp(r'[\s,，、]+')),
            )
            .toList();
        if (ranges.every((range) => range.isEmpty)) {
          return tb('needOpponents', 'Enter opponent scores');
        }
        if (ranges.any(
          (range) =>
              range.length > 4 ||
              range.any(
                (token) =>
                    double.tryParse(token) == null ||
                    !double.parse(token).isFinite ||
                    double.parse(token) <= 0,
              ),
        )) {
          return tb(
            'invalidOpponents',
            'Use up to four positive scores per range',
          );
        }
      }
    }
    if (activity &&
        s.goal == GoalKind.event &&
        s.rewardPlan == null &&
        s.ptCycle) {
      return tb(
        'farm.conversionConflict',
        'CP conversion requires {condition}',
        {'condition': tb('farm.primaryRanking', 'Primary reward ranking')},
      );
    }
    if (s.goal == GoalKind.event &&
        s.rewardPlan == null &&
        s.weighted &&
        (s.weights!.values.any(
              (value) => !numOf(value).isFinite || numOf(value) < 0,
            ) ||
            s.weights!.values.every((value) => numOf(value) <= 0))) {
      return tb(
        'needRewardWeight',
        'Enter at least one positive reward weight',
      );
    }
    if (s.goal == GoalKind.event &&
        s.rewardPlan != null &&
        s.effectiveRewardPlan.compile(
              s.planChallengeSongs,
              s.challengePoints,
            ) ==
            null) {
      return tb(
        'rewardPlan.invalidRate',
        'Enter conversion rates and challenge charts',
      );
    }
    return null;
  }

  Goal? goal() {
    if (inputIssue != null) return null;
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
            : ScoreGoal(
                s.songs,
                criterion,
                play,
                challengeId,
                target: s.scoreTarget != 'none' && s.targetScore != null
                    ? {'kind': s.scoreTarget, 'score': s.targetScore}
                    : null,
              );
      case GoalKind.gekiso:
        return s.songs.isEmpty
            ? null
            : GekisoGoal(
                songs: s.songs,
                criterion: criterion,
                accuracy: Accuracy(
                  great: s.allPerfect ? 0 : s.great / 100,
                  just: _missionEnabled(s, 3) ? s.just / 100 : 1,
                  missEvery: s.allPerfect ? 0 : s.missEvery,
                ),
                rank: s.gekisoRank,
                seeds: _missionEnabled(s, 2) ? s.gekisoSeeds : 0,
                minComboBonus: _missionEnabled(s, 1) ? s.minComboBonus : 1,
                opponents: s.opponents,
                musicType: s.songRulesOverride?.musicType,
                missions: s.songRulesOverride?.missions,
                arena: s.arena,
              );
      case GoalKind.event:
        if (s.eventId == null) return null;
        if (s.route != 'skip' && s.songs.isEmpty) return null;
        if (s.rewardPlan != null || s.weighted) {
          final plan = s.effectiveRewardPlan;
          final compiled = plan.compile(
            s.planChallengeSongs,
            s.challengePoints,
          );
          if (compiled == null) return null;
          return EventGoal(
            measure: plan.primary,
            route: RouteKind.values.byName(s.route),
            eventId: s.eventId!,
            songs: s.route == 'skip' ? const [] : s.songs,
            consumption: s.route == 'challenge' ? s.challengePoints : s.boosts,
            play: play,
            rewardPlan: compiled,
            ptOnly: s.ptGekiso && s.route == 'live',
            ranking: 'primary',
            minComboBonus: s.minComboBonus,
            gekiso: s.ptGekiso && s.route == 'live'
                ? (just: s.ptJust / 100, luckSamples: s.ptLuckSamples)
                : null,
            eventEffects: manualEventEffects(s),
          );
        }
        return EventGoal(
          ranking: s.fullRanking ? null : 'primary',
          weights: s.weights,
          measure: s.weighted
              ? numOf(s.weights!['points']) > 0
                    ? 'points'
                    : numOf(s.weights!['items']) > 0
                    ? 'items'
                    : 'challenge-points'
              : s.measure,
          route: RouteKind.values.byName(s.route),
          eventId: s.eventId!,
          songs: s.route == 'skip' ? const [] : s.songs,
          consumption: s.route == 'challenge' ? s.challengePoints : s.boosts,
          play: play,
          eventEffects: manualEventEffects(s),
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

  EngineRequest? request({Goal? overrideGoal}) {
    final goal = overrideGoal ?? this.goal();
    final view = this.view;
    if (goal == null || view == null) return null;
    final cards = engineCards();
    final s = searchSettings;
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
      player:
          activity &&
              settings.rewardMode != 'plan' &&
              settings.farmingConditions['includeMemory'] == false
          ? PlayerInput(
              characterRanks: view.player.characterRanks,
              characterTotalRank: view.player.characterTotalRank,
              bandItems: view.player.bandItems,
              vipRank: view.player.vipRank,
              characterMemory: {
                for (final id in catalog!.master.characters.keys) '$id': 0,
              },
              musicMemory: {
                for (final id in catalog!.master.songs.keys) '$id': 0,
              },
            )
          : view.player,
      unknownPolicy: s.theoretical || s.unknownPolicy == 'max'
          ? UnknownPolicy.max
          : UnknownPolicy.min,
      goal: goal,
      songRules: songRulesFor(
        s,
        gekiso: goal is GekisoGoal || goal is EventGoal && goal.gekiso != null,
      ),
      aggregation:
          s.shared &&
              !arenaActive &&
              (goal is ScoreGoal ||
                  goal is GekisoGoal ||
                  goal is EventGoal && goal.route != RouteKind.skip)
          ? 'mean'
          : null,
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

  String? _activeContext;
  String? _resultOwner;
  void _checkActiveContext() {
    final context = manualContext;
    if (_manualResultsContext != null && context != _manualResultsContext) {
      manualResults = null;
    }
    if (activeManualContext != null &&
        (_manualSuggestion ? manualSuggestionContext : context) !=
            activeManualContext) {
      ++manualGeneration;
      engine?.cancel();
      manualBusy = running = false;
      activeManualContext = null;
    }
    final owner = jsonEncode([store?.owner, server, catalog?.data['identity']]);
    if (_resultOwner != null && _resultOwner != owner) {
      results = null;
      resultSettings = null;
      resultInputs = null;
      resultsFor = '';
      manualResults = null;
      manual = const ManualTeam();
      manualSuggestions = null;
      manualSuggesting = -1;
      manualSuggestionsContext = null;
      _taskResults.clear();
      ptCompared.clear();
      growth = null;
      growthContext = '';
      compared.clear();
      resultSession = '';
    }
    _resultOwner = owner;
    if (_activeContext != null && _activeContext != _fingerprint()) {
      ++runGeneration;
      engine?.cancel();
      running = false;
      progress = null;
      growthRunning = false;
      _activeContext = null;
    }
  }

  Object? _contextStamp;
  String _contextValue = '';

  /// What the request depends on, to tell stale results.
  String _fingerprint() {
    final stamp = (
      settings,
      arenaDraft,
      arenaActive,
      arenaActive && catalog != null ? (arena.regulation?['id']) : null,
      catalog,
      view,
      store?.owner,
      server,
      activity,
    );
    if (stamp == _contextStamp) return _contextValue;
    _contextStamp = stamp;
    final request = this.request();
    if (request == null) return _contextValue = '';
    final input = request.toJson()
      ..remove('timeLimitMs')
      ..remove('deadline')
      ..remove('contextKey')
      ..remove('requestId');
    return _contextValue = jsonEncode([
      'native-conservative-bounds-v3',
      store?.owner,
      server,
      catalog?.data['identity'],
      objectRow(catalog?.data['crossServer'])['identities'],
      input,
    ]);
  }

  bool get stale => results != null && resultsFor != _fingerprint();

  Future<void> run({bool resume = false}) async {
    if (activity && this.settings.rewardMode == 'event') {
      pt.sync();
      if (pt.issues.isNotEmpty) {
        pt.showIssues = true;
        changed();
        return;
      }
    }

    var request = this.request();
    final engine = this.engine;
    if (request == null || engine == null || running) return;
    final fingerprint = _fingerprint();
    _activeContext = fingerprint;
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
    if (!resume) {
      resultSession = DateTime.now().microsecondsSinceEpoch.toString();
      compared = [];
    }
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
          resultInputs = request;
          syncCompared();
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
        resultInputs = request;
        syncCompared();
      }
    } on EngineCancelled {
      // Cancelled by the reader.
    } catch (failure) {
      if (generation == runGeneration && !_disposed) {
        error = tb('searchFailed', 'The search failed: {reason}', {
          'reason': '$failure',
        });
      }
    } finally {
      if (generation == runGeneration) {
        running = false;
        _activeContext = null;
        progress = null;
        notifyListeners();
      }
    }
  }

  Future<void> recommendGrowth() async {
    final input = request(), engine = this.engine;
    if (input == null || engine == null || running) return;
    final fingerprint = _fingerprint(), generation = ++runGeneration;
    growthContext = fingerprint;
    growth = null;
    growthProgress = (0, 0);
    running = growthRunning = true;
    _activeContext = fingerprint;
    changed();
    try {
      final result = await training.priorities(input, (done, total) {
        if (generation == runGeneration && fingerprint == _fingerprint()) {
          growthProgress = (done, total);
          changed();
        }
      });
      if (generation == runGeneration && fingerprint == _fingerprint()) {
        growth = result;
      }
    } on EngineCancelled {
      // The next request owns the engine.
    } catch (failure) {
      if (generation == runGeneration) {
        error = tb('searchFailed', 'The search failed: {reason}', {
          'reason': '$failure',
        });
      }
    } finally {
      if (generation == runGeneration) {
        running = growthRunning = false;
        _activeContext = null;
        changed();
      }
    }
  }

  void cancel() {
    _auxiliaryTask = null;
    ++runGeneration;
    _activeContext = null;
    running = growthRunning = false;
    progress = null;
    ++manualGeneration;
    manualBusy = false;
    activeManualContext = null;
    comparison.stop();
    pt.stop();
    engine?.cancel();
    if (!_disposed) notifyListeners();
  }

  /// Repaints after a change made outside the controller's own methods.
  void changed() {
    comparison.sync();
    _checkActiveContext();
    if (!_disposed) notifyListeners();
  }

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
