import 'dart:convert';

import '../catalog/chart_rates.dart' show roomRequiredScore;
import 'controller.dart';
import 'engine/api.dart';
import 'engine/box.dart';
import 'engine/full/play.dart' show Accuracy;
import 'engine/num.dart';
import 'engine/objectives.dart' show Criterion;
import 'engine_client.dart';
import 'settings.dart' show normalizeSongRules;

class SongComparisonRow {
  SongComparisonRow(this.song, {this.hit});
  final SongRef song;
  EngineHit? hit;
  String status = 'pending';
}

class SongComparison {
  SongComparison(this.host);
  final TeamBuilderController host;
  static const defaults = <String, Object?>{
    'songs': <Object?>[],
    'target': 'SS',
    'players': 5,
    'mode': null,
    'great': 0,
    'just': null,
    'missEvery': 0,
    'rank': null,
    'sort': 'contribution',
    'songRules': null,
  };
  Doc settings = {...defaults};
  List<SongComparisonRow> rows = [];
  final _cache = <String, EngineHit>{};
  String _context = '', _owner = '', _selection = '';
  int _generation = 0;
  bool running = false, stale = false;
  String? error;
  List<SongComparisonRow>? _previous;
  Doc? evaluatedSettings;

  List<SongRef> get songs => [
    for (final value in settings['songs'] as List)
      SongRef.fromJson(objectRow(value)),
  ];
  List<SongComparisonRow> get resultRows => _previous ?? rows;
  String text(String key, [Map<String, Object?> values = const {}]) =>
      host.tb('sc.$key', key, values);
  bool available(String collection, int id) {
    final cross = objectRow(host.catalog?.data['crossServer']);
    if (cross.isEmpty) return true;
    return (objectRow(objectRow(cross['availability'])[collection])['$id']
                as List? ??
            [])
        .contains(host.server);
  }

  String _identity() => jsonEncode([
    host.store?.owner,
    host.server,
    host.catalog?.data['identity'],
    host.catalog?.data['crossServer'],
  ]);
  String _fingerprint() => jsonEncode([
    _identity(),
    host.manual.members,
    host.manual.snaps,
    host.manual.leader,
    host.view
        ?.engineInputs(true)
        .members
        .where((row) => host.manual.members.contains(row.cardId))
        .map((row) => row.toJson())
        .toList(),
    host.view
        ?.engineInputs(true)
        .snaps
        .where((row) => host.manual.snaps.contains(row.cardId))
        .map((row) => row.toJson())
        .toList(),
    host.view?.player.toJson(),
    settings['mode'],
    settings['great'],
    settings['just'],
    settings['missEvery'],
    settings['rank'],
    songRules,
  ]);

  ({int musicType, List<int> missions})? get ruleValues =>
      settings['songRules'] == null
      ? null
      : normalizeSongRules(settings['songRules']);
  Doc? get songRules {
    final rule = ruleValues;
    return rule == null ||
            rule.musicType == 0 && rule.missions.every((v) => v == 0)
        ? null
        : {'musicType': rule.musicType, 'missions': rule.missions};
  }

  bool hasMission(int mission) {
    final rules = ruleValues;
    return songs.any((ref) {
      final original =
          host.catalog?.master.songs[ref.songId]?.gekisoMissions ??
          const <int>[];
      return [
        for (var i = 0; i < 3; i++)
          (rules?.missions[i] ?? 0) == 0
              ? (original.elementAtOrNull(i) ?? 0)
              : rules!.missions[i],
      ].contains(mission);
    });
  }

  void restore() {
    final stored = host.view?.prefs['song-comparison'];
    if (stored is Map) {
      settings = {...defaults, ...stored.cast<String, Object?>()};
    }
    sync();
  }

  void update(Doc patch) {
    settings = {...settings, ...patch};
    if (numOf(settings['rank']) > numOf(settings['players'])) {
      settings['rank'] = null;
    }
    host.write([('pref.song-comparison', settings)]);
    sync();
    host.changed();
  }

  void sync() {
    if (host.view == null || host.catalog == null) return;
    final owner = _identity(),
        signature = _fingerprint(),
        selection = jsonEncode(settings['songs']);
    if (_owner != owner) {
      stop();
      _cache.clear();
      _previous = null;
      rows = [];
      evaluatedSettings = null;
      stale = false;
      _owner = owner;
    }
    if (_context == signature && _selection == selection) return;
    stop();
    if (_previous == null && rows.any((row) => row.hit != null)) {
      _previous = rows;
      stale = true;
    }
    if (_context != signature) _cache.clear();
    _context = signature;
    _selection = selection;
    rows = [
      for (final song in songs)
        if (available('songs', song.songId) &&
            host.catalog!.difficultyRow(song.songId, song.difficulty) != null)
          SongComparisonRow(song, hit: _cache[song.key]),
    ];
    for (final row in rows) {
      if (row.hit != null) row.status = 'complete';
    }
  }

  List<String> get issues {
    final c = host,
        manual = c.manual,
        view = c.view,
        master = c.catalog?.master;
    if (view == null || master == null) return ['formation'];
    final issues = <String>[];
    final characters = <int>{}, snaps = <int>{};
    for (var i = 0; i < 5; i++) {
      final member = manual.members[i], snap = manual.snaps[i];
      if (member == null ||
          !view.members.containsKey(member) ||
          !master.members.containsKey(member)) {
        issues.add('memberMissing');
      } else if (!available('members', member)) {
        issues.add('source');
      } else if (!characters.add(master.members[member]!.characterId)) {
        issues.add('duplicateCharacter');
      }
      if (snap != null) {
        if (!view.snaps.containsKey(snap) || !master.snaps.containsKey(snap)) {
          issues.add('snapMissing');
        } else if (!available('snapshots', snap)) {
          issues.add('source');
        } else if (!snaps.add(snap)) {
          issues.add('duplicateSnap');
        }
      }
    }
    if (rows.isEmpty) issues.add('songs');
    if (settings['mode'] == null) issues.add('mode');
    bool percent(String key) =>
        settings[key] is num &&
        numOf(settings[key]).isFinite &&
        numOf(settings[key]) >= 0 &&
        numOf(settings[key]) <= 100;
    if (hasMission(3) && !percent('just') ||
        settings['mode'] == 'custom' && !percent('great')) {
      issues.add('percent');
    }
    if (settings['mode'] == 'custom' &&
        (settings['missEvery'] is! int || intOf(settings['missEvery']) < 0)) {
      issues.add('miss');
    }
    if (settings['rank'] is! int ||
        intOf(settings['rank']) < 1 ||
        intOf(settings['rank']) > intOf(settings['players'])) {
      issues.add('rank');
    }
    return issues.toSet().toList();
  }

  Future<void> run() async {
    sync();
    if (running || host.running || issues.isNotEmpty) return;
    final c = host, engine = host.engine;
    if (engine == null) return;
    final generation = ++_generation;
    final context = _context;
    final manual = c.manual, owned = c.view!.engineInputs(true);
    final members = owned.members
        .where((row) => manual.members.contains(row.cardId))
        .toList();
    final snaps = owned.snaps
        .where((row) => manual.snaps.contains(row.cardId))
        .toList();
    _previous = null;
    stale = false;
    error = null;
    evaluatedSettings = jsonDecode(jsonEncode(settings)) as Doc;
    running = c.running = true;
    c.changed();
    try {
      for (final row in rows) {
        if (row.hit != null) continue;
        row.status = 'running';
        c.changed();
        final request = EngineRequest(
          members: members,
          snaps: snaps,
          player: c.view!.player,
          unknownPolicy: UnknownPolicy.min,
          songRules: songRules,
          goal: GekisoGoal(
            songs: [row.song],
            criterion: Criterion.mean,
            accuracy: Accuracy(
              great: settings['mode'] == 'ap'
                  ? 0
                  : numOf(settings['great']) / 100,
              just: hasMission(3) ? numOf(settings['just']) / 100 : 1,
              missEvery: settings['mode'] == 'ap'
                  ? 0
                  : intOf(settings['missEvery']),
            ),
            rank: intOf(settings['rank']),
            seeds: 0,
          ),
          constraints: ConstraintInput(
            requiredMembers: members.map((row) => row.key).toList(),
            requiredSnaps: snaps.map((row) => row.key).toList(),
            leader: 'm${manual.members[manual.leader]}',
            bindings: [
              for (var i = 0; i < 5; i++)
                (
                  'm${manual.members[i]}',
                  manual.snaps[i] == null ? null : 's${manual.snaps[i]}',
                ),
            ],
          ),
          k: 1,
          contextKey: context,
        );
        try {
          final response = await engine.run(request);
          if (generation != _generation || context != _context) return;
          final hit = response.results
              .where((result) => result.song == row.song)
              .firstOrNull
              ?.hits
              .firstOrNull;
          if (response.error != null ||
              response.unknownCards.isNotEmpty ||
              response.stopReason != 'complete' ||
              hit?.score?.orders.length != 120 ||
              hit!.members.length != 5 ||
              hit.members.first != request.constraints.leader) {
            throw StateError('incomplete-score');
          }
          final bindings = Map.fromEntries(
            request.constraints.bindings.map(
              (pair) => MapEntry(pair.$1, pair.$2),
            ),
          );
          if (hit.members.asMap().entries.any(
            (entry) =>
                !bindings.containsKey(entry.value) ||
                bindings[entry.value] != hit.snaps[entry.key],
          )) {
            throw StateError('formation-changed');
          }
          row.hit = hit;
          row.status = 'complete';
          _cache[row.song.key] = hit;
        } on EngineCancelled {
          rethrow;
        } catch (_) {
          row.status = 'failed';
        }
        c.changed();
      }
    } on EngineCancelled {
      for (final row in rows.where((row) => row.status == 'running')) {
        row.status = 'cancelled';
      }
    } finally {
      if (generation == _generation) {
        running = c.running = false;
        c.changed();
      }
    }
  }

  ({double contribution, double remaining, int total, double average})? metrics(
    SongComparisonRow row,
  ) {
    final score = row.hit?.score;
    if (score == null) return null;
    final players = intOf(settings['players'], 5),
        master = host.catalog!.master;
    final rank = settings['target'] == 'S' ? 6 : 7;
    final base = master.scoreRanks[master.songs[row.song.songId]?.rankGroup]
        ?.where((row) => row.rank == rank)
        .firstOrNull
        ?.battleRequired;
    if (base == null || base <= 0 || players < 2 || players > 5) return null;
    final total = roomRequiredScore(base, players);
    if (total <= 0 || total >= 2147483647) return null;
    final average = total / players;
    return (
      contribution: score.mean / average * 100,
      remaining: (total - score.mean).clamp(0, double.infinity) / (players - 1),
      total: total,
      average: average,
    );
  }

  void stop() {
    if (running) {
      host.engine?.cancel();
      running = host.running = false;
    }
    _generation++;
    for (final row in rows.where((row) => row.status == 'running')) {
      row.status = 'cancelled';
    }
  }
}
