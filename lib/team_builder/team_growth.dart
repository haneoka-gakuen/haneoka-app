import 'dart:collection';
import 'dart:convert';

import 'controller.dart';
import 'engine/api.dart';
import 'engine/box.dart';
import 'engine/execution.dart';
import 'engine/master.dart';
import 'engine/num.dart';
import 'engine/power.dart';
import 'engine_client.dart';
import 'pt_recommendation.dart';
import 'result_metric.dart';
import 'result_comparison.dart';
import 'settings.dart';

const growthFields = {
  'level': 'level',
  'training': 'awake',
  'awakening': 'rank',
  'live': 'liveSkillLevel',
  'gekisou': 'gekisoSkillLevel',
  'break': 'rank',
};
const growthLabels = {
  'level': 'level',
  'training': 'training',
  'awakening': 'awakening',
  'live': 'liveSkill',
  'gekisou': 'gekisoSkill',
  'break': 'limitBreak',
  'full': 'tg.full',
};

EngineRequest freshGrowthRequest(EngineRequest source) {
  final input = source.toJson();
  return EngineRequest.fromJson(
    objectRow(
      jsonDecode(
        jsonEncode({
          for (final key in [
            'members',
            'snaps',
            'player',
            'unknownPolicy',
            'goal',
            'constraints',
            'aggregation',
            'songRules',
          ])
            if (input.containsKey(key)) key: input[key],
          'k': 1,
          'timeLimitMs': source.timeLimitMs,
        }),
      ),
    ),
  );
}

class TeamGrowthChoice {
  const TeamGrowthChoice({
    required this.members,
    required this.key,
    this.action = 'level',
    this.target = 'next',
  });
  final bool members;
  final String key, action, target;
  TeamGrowthChoice copyWith({
    bool? members,
    String? key,
    String? action,
    String? target,
  }) => TeamGrowthChoice(
    members: members ?? this.members,
    key: key ?? this.key,
    action: action ?? this.action,
    target: target ?? this.target,
  );
}

class TeamGrowthChange {
  const TeamGrowthChange(this.status, {this.from, this.to, this.request});
  final String status;
  final int? from, to;
  final EngineRequest? request;
}

TeamGrowthChange teamGrowthChange(
  EngineMaster master,
  EngineRequest source,
  TeamGrowthChoice choice,
) {
  final Object? input = choice.members
      ? source.members.where((row) => row.key == choice.key).firstOrNull
      : source.snaps.where((row) => row.key == choice.key).firstOrNull;
  if (input == null) return const TeamGrowthChange('missing-data');
  final values = input is MemberInput
      ? input.toJson()
      : (input as SnapInput).toJson();
  final id = intOf(values['cardId']),
      member = choice.members ? master.members[id] : null,
      snap = choice.members ? null : master.snaps[id];
  if (member == null && snap == null) {
    return const TeamGrowthChange('missing-data');
  }
  final maximum = member != null
      ? (() {
          final growth = maxMemberGrowth(master, member);
          return {
            'level': growth.level,
            'awake': growth.awake,
            'rank': growth.rank,
            'liveSkillLevel': growth.liveSkillLevel,
            'gekisoSkillLevel': growth.gekisoSkillLevel,
          };
        })()
      : (() {
          final growth = maxSnapGrowth(master, snap!);
          return {'level': growth.level, 'rank': growth.rank};
        })();
  final patch = <String, Object?>{};
  if (choice.action == 'full') {
    final effective = member != null
        ? (() {
            final growth = memberGrowth(
              master,
              member,
              input as MemberInput,
              source.unknownPolicy,
            );
            return {
              'level': growth.level,
              'awake': growth.awake,
              'rank': growth.rank,
              'liveSkillLevel': growth.liveSkillLevel,
              'gekisoSkillLevel': growth.gekisoSkillLevel,
            };
          })()
        : (() {
            final growth = snapGrowth(
              master,
              snap!,
              input as SnapInput,
              source.unknownPolicy,
            );
            return {'level': growth.level, 'rank': growth.rank};
          })();
    if (maximum.entries.every((entry) => effective[entry.key] == entry.value)) {
      return const TeamGrowthChange('at-cap');
    }
    patch.addAll(maximum);
  } else {
    if (!choice.members && !['level', 'break'].contains(choice.action) ||
        choice.members && choice.action == 'break') {
      return const TeamGrowthChange('missing-data');
    }
    final field = growthFields[choice.action]!, from = values[field] as int?;
    if (from == null) return const TeamGrowthChange('missing-state');
    var cap = maximum[field]!;
    if (choice.action == 'level') {
      final stage = values[choice.members ? 'awake' : 'rank'] as int?;
      if (stage == null) return TeamGrowthChange('missing-state', from: from);
      cap = member != null
          ? memberLevelCap(master, member, stage)
          : snapLevelCap(master, snap!, stage);
    }
    if (from < 1 || from > cap) {
      return TeamGrowthChange('invalid-state', from: from);
    }
    if (from == cap) return TeamGrowthChange('at-cap', from: from);
    final to = choice.action == 'level' && choice.target == 'cap'
        ? cap
        : from + 1;
    final request = _patched(source, choice, {field: to});
    return TeamGrowthChange('ready', from: from, to: to, request: request);
  }
  return TeamGrowthChange('ready', request: _patched(source, choice, patch));
}

EngineRequest _patched(
  EngineRequest source,
  TeamGrowthChoice choice,
  Doc patch,
) {
  final input = freshGrowthRequest(source).toJson(),
      kind = choice.members ? 'members' : 'snaps';
  input[kind] = [
    for (final row in dataRows(input[kind]))
      row['key'] == choice.key ? {...row, ...patch} : row,
  ];
  return EngineRequest.fromJson(input);
}

EngineRequest fixedGrowthRequest(EngineRequest source, EngineHit team) {
  final input = freshGrowthRequest(source).toJson();
  input['members'] = [
    for (final key in team.members)
      source.members.firstWhere((row) => row.key == key).toJson(),
  ];
  input['snaps'] = [
    for (final row in source.snaps)
      if (team.snaps.contains(row.key)) row.toJson(),
  ];
  input['constraints'] = ConstraintInput(
    requiredMembers: team.members,
    requiredSnaps: team.snaps.whereType<String>().toList(),
    leader: team.members.first,
    bindings: [
      for (final (i, key) in team.members.indexed) (key, team.snaps[i]),
    ],
    noSnaps: team.snaps.every((key) => key == null),
  ).toJson();
  input['timeLimitMs'] = null;
  final goal = objectRow(input['goal']);
  if (goal['kind'] == 'plan') throw StateError('growth-plan-needs-route');
  if (goal['songs'] is List) {
    goal['songs'] = team.aggregate != null
        ? [for (final hit in team.aggregate!) hit.song!.toJson()]
        : [if (team.song != null) team.song!.toJson()];
  }
  if (goal['kind'] == 'power') goal['song'] = team.song?.toJson();
  return EngineRequest.fromJson(input);
}

class TeamGrowthSource {
  TeamGrowthSource({
    required EngineRequest input,
    required EngineHit hit,
    required BuildSettings settings,
    required this.identity,
    this.cycle,
  }) : input = freshGrowthRequest(input),
       hit = EngineHit.fromJson(
         objectRow(jsonDecode(jsonEncode(hit.toJson()))),
       ),
       settings = BuildSettings(settings.toJson()).forGoal(settings.goal);
  final EngineRequest input;
  final EngineHit hit;
  final BuildSettings settings;
  final String identity;
  final PtCycle? cycle;
}

class TeamGrowthService {
  TeamGrowthService(this.host);
  final TeamBuilderController host;
  final _cache = <String, EngineResponse>{};
  String _identity = '';
  String get identity => canonical([
    host.store?.owner,
    host.server,
    host.catalog?.data['identity'],
    objectRow(host.catalog?.data['crossServer'])['identities'],
  ]);
  String cacheKey(EngineRequest source) {
    if (_identity != identity) {
      _identity = identity;
      _cache.clear();
    }
    final request = freshGrowthRequest(source).toJson()..remove('timeLimitMs');
    return canonical([identity, request]);
  }

  EngineResponse? cached(EngineRequest input) {
    final key = cacheKey(input), value = _cache.remove(key);
    if (value != null) _cache[key] = value;
    return value;
  }

  void remember(EngineRequest input, EngineResponse value) {
    final key = cacheKey(input);
    _cache.remove(key);
    _cache[key] = value;
    while (_cache.length > 256) {
      _cache.remove(_cache.keys.first);
    }
  }

  TeamGrowthSource? resultSource(EngineHit hit) {
    final job = host.usesPtResults ? host.pt.job : null;
    final base = job?.request ?? host.requestForHit(hit);
    if (base == null || base.goal is PlanGoal || host.running) return null;
    final settings = job == null
        ? host.settingsForHit(hit)
        : host.ptCompareEntry(hit, job, 0)?.settings;
    if (settings == null) return null;
    final input = freshGrowthRequest(base).toJson();
    if (job != null) {
      final goal = objectRow(input['goal']);
      goal['route'] = settings.route;
      goal['measure'] = settings.measure;
      goal['songs'] = [
        for (final task in job.tasks)
          if (task.route.name == settings.route &&
              task.measure == settings.measure)
            task.song.toJson(),
      ];
      if (settings.route == 'challenge') {
        goal['consumption'] = job.cycle!.consumption;
        goal.remove('gekiso');
      } else if (job.cycle != null) {
        final best = ptChallengeBest(
          job,
          settings.measure == 'items' ? 'items' : 'points',
        );
        if (best?.event?.rewardSum == null || best?.event?.orders == null) {
          return null;
        }
        final exchange = cpExchangeOf(
          best!.event!.rewardSum!,
          best.event!.orders!,
          job.cycle!.consumption,
        );
        goal['cpExchange'] = {
          'numerator': exchange.numerator,
          'denominator': exchange.denominator,
        };
      }
    }
    return TeamGrowthSource(
      input: EngineRequest.fromJson(input),
      hit: hit,
      settings: settings,
      identity: identity,
      cycle: job != null && settings.route == 'live' ? job.cycle : null,
    );
  }

  TeamGrowthSource? comparedSource(ComparedResult entry) {
    if (host.running || entry.input.goal is PlanGoal) return null;
    final job = host.pt.job;
    if (job != null && entry.session == job.id) {
      final original = job.tasks
          .expand((task) => task.result?.hits ?? <EngineHit>[])
          .where(
            (hit) => canonical(hit.toJson()) == canonical(entry.hit.toJson()),
          )
          .firstOrNull;
      return original == null ? null : resultSource(original);
    }
    return TeamGrowthSource(
      input: entry.input,
      hit: entry.hit,
      settings: entry.settings,
      identity: identity,
    );
  }

  TeamGrowthSource? manualSource(TeamEvaluation row) {
    if (host.running || host.manualResults?.contains(row) != true) return null;
    final goal = host.manualGoal()!,
        base = host.request(overrideGoal: goal),
        owned = host.view!.engineInputs(true),
        selected = host.manualInputs();
    if (base == null) return null;
    final input = freshGrowthRequest(base).toJson()..remove('aggregation');
    input['members'] = {
      for (final value in [
        ...base.members.map(
          (row) =>
              owned.members.where((card) => card.key == row.key).firstOrNull ??
              row,
        ),
        ...selected.members,
      ])
        value.key: value.toJson(),
    }.values.toList();
    input['snaps'] = {
      for (final value in [
        ...base.snaps.map(
          (row) =>
              owned.snaps.where((card) => card.key == row.key).firstOrNull ??
              row,
        ),
        ...selected.snaps,
      ])
        value.key: value.toJson(),
    }.values.toList();
    input['unknownPolicy'] = selected.policy.name;
    final order = [
      host.manual.leader,
      ...[0, 1, 2, 3, 4].where((i) => i != host.manual.leader),
    ];
    final hit =
        EngineHit(
            song: row.song,
            members: [for (final i in order) 'm${host.manual.members[i]}'],
            snaps: [
              for (final i in order)
                host.manual.snaps[i] == null
                    ? null
                    : 's${host.manual.snaps[i]}',
            ],
            power: row.power,
            slotPowers: [for (final i in order) row.slotPowers[i]],
            key: row.score.mean,
          )
          ..score = row.score
          ..skipScore = row.skipScore;
    return TeamGrowthSource(
      input: EngineRequest.fromJson(input),
      hit: hit,
      settings: host.settings
          .copyWith({'criterion': 'mean', 'scoreTarget': 'none'})
          .forGoal(goal is GekisoGoal ? GoalKind.gekiso : GoalKind.score),
      identity: identity,
    );
  }

  Future<EngineResponse> evaluate(
    EngineRequest input, {
    void Function(EngineResponse)? onSnapshot,
  }) async {
    final previous = cached(input);
    if (previous != null &&
        completeResponse(previous) &&
        previous.error == null) {
      return previous;
    }
    final expected = identity;
    final request = freshGrowthRequest(input).copyWith(
      seeds: previous?.overall,
      completed: previous?.results.where((row) => row.proven).toList(),
    );
    final result = await host.engine!.run(request, null, (snapshot) {
      if (expected == identity) {
        remember(input, snapshot.response);
        onSnapshot?.call(snapshot.response);
      }
    });
    if (expected != identity) throw const EngineCancelled();
    remember(input, result);
    return result;
  }

  Future<Doc> priorities(
    EngineRequest source,
    void Function(int, int) progress,
  ) async {
    final input = freshGrowthRequest(source).copyWith(keepTimeLimit: false),
        expected = identity,
        base = await evaluate(
          freshGrowthRequest(source).copyWith(keepTimeLimit: false),
        );
    if (!completeResponse(base) || base.error != null) {
      throw StateError(base.error ?? 'growth-incomplete');
    }
    if (base.overall.isEmpty) throw StateError('growth-no-team');
    final candidates = <({bool members, String key, EngineRequest request})>[];
    for (final members in [true, false]) {
      for (final key
          in members
              ? input.members.map((row) => row.key)
              : input.snaps.map((row) => row.key)) {
        final change = teamGrowthChange(
          host.catalog!.master,
          input,
          TeamGrowthChoice(
            members: members,
            key: key,
            action: 'full',
            target: 'cap',
          ),
        );
        if (change.request != null) {
          candidates.add((
            members: members,
            key: key,
            request: change.request!,
          ));
        }
      }
    }
    final responses = <int, EngineResponse>{}, pending = <int>[];
    var done = 0;
    for (final (i, candidate) in candidates.indexed) {
      final value = cached(candidate.request);
      if (value != null && value.error == null && completeResponse(value)) {
        responses[i] = value;
        progress(++done, candidates.length);
      } else {
        pending.add(i);
      }
    }
    Object? failure;
    await host.engine!.runBatch(
      [for (final i in pending) candidates[i].request],
      (index, result) {
        if (identity != expected) {
          failure = const EngineCancelled();
          return;
        }
        final i = pending[index];
        remember(candidates[i].request, result);
        if (result.error != null) failure = StateError(result.error!);
        if (!completeResponse(result)) failure = const EngineCancelled();
        responses[i] = result;
        progress(++done, candidates.length);
      },
    );
    if (failure != null) throw failure!;
    final settings = host.resultSettings ?? host.searchSettings;
    num metric(EngineHit hit) => resultMetric(hit, settings, host.tb).value;
    final baseline = metric(base.overall.first);
    final upgrades = [
      for (final (i, candidate) in candidates.indexed)
        if (responses[i]!.overall.isNotEmpty)
          {
            'kind': candidate.members ? 'members' : 'snaps',
            'key': candidate.key,
            'value': metric(responses[i]!.overall.first),
            'gain': metric(responses[i]!.overall.first) - baseline,
            'team': responses[i]!.overall.first.toJson(),
          },
    ]..sort((a, b) => numOf(b['gain']).compareTo(numOf(a['gain'])));
    return {'base': baseline, 'upgrades': upgrades};
  }
}
