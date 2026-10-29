import 'dart:async';

import 'package:flutter/material.dart';

import '../shell/links.dart';
import '../ui/detail.dart';
import '../ui/upgrade.dart';
import 'box_tab.dart' show showCardEditor;
import 'controller.dart';
import 'engine/api.dart';
import 'engine/execution.dart';
import 'engine/objectives.dart';
import 'pt_recommendation.dart';
import 'engine/num.dart';
import 'engine_client.dart';
import 'result_metric.dart';
import 'results_view.dart' show Formation;
import 'team_growth.dart';
import 'widgets.dart';

class TeamGrowthComparison extends ChangeNotifier {
  TeamGrowthComparison(this.host, this.source, {TeamGrowthChoice? choice})
    : choice =
          choice ??
          TeamGrowthChoice(members: true, key: source.hit.members.first) {
    host.addListener(_sync);
    restore();
    unawaited(loadMaterials());
  }
  final TeamBuilderController host;
  final TeamGrowthSource source;
  TeamGrowthChoice choice;
  final results = <String, EngineResponse>{};
  String? phase;
  String error = '';
  Doc? materials;
  bool materialError = false;
  bool _closed = false, _stopped = false;
  int _materialGeneration = 0;
  Object? _task;
  TeamGrowthChange get change =>
      teamGrowthChange(host.catalog!.master, source.input, choice);
  void _sync() {
    if (_closed) return;
    if (source.identity != host.training.identity) {
      stop();
      error = host.state.text('common.states.unavailable');
      notifyListeners();
    }
  }

  bool get current => source.identity == host.training.identity;
  void restore() {
    final before = source.cycle == null
        ? host.training.cached(source.input)
        : null;
    if (before != null) results['searchBefore'] = before;
    final input = change.request;
    if (input != null) {
      final after = source.cycle == null ? host.training.cached(input) : null;
      if (after != null) results['searchAfter'] = after;
    }
  }

  void select(TeamGrowthChoice value) {
    if (phase != null) return;
    choice = value;
    results.remove('fixedAfter');
    results.remove('searchAfter');
    error = '';
    restore();
    unawaited(loadMaterials());
    notifyListeners();
  }

  Future<void> loadMaterials() async {
    final generation = ++_materialGeneration,
        kind = choice.members ? 'members' : 'snapshots';
    final row = choice.members
        ? source.input.members
              .firstWhere((row) => row.key == choice.key)
              .toJson()
        : source.input.snaps
              .firstWhere((row) => row.key == choice.key)
              .toJson();
    final cross = objectRow(host.catalog!.data['crossServer']),
        server =
            '${objectRow(objectRow(cross['owners'])[kind])['${row['cardId']}'] ?? host.server}';
    final identity = objectRow(objectRow(cross['identities'])[server]),
        locale = host.state.text.locale;
    materialError = false;
    if (materials?['locale'] == locale &&
        objectRow(materials?['identity'])['releaseId'] ==
            identity['releaseId'] &&
        objectRow(materials?['identity'])['server'] == server) {
      return;
    }
    materials = null;
    try {
      final data = objectRow(
        await host.state
            .apiFor(server)
            .json(
              '/$server/$locale/growth-data.json?release=${identity['releaseId']}',
            ),
      );
      if (data['schema'] != 'haneoka-growth-page-v1' ||
          data['locale'] != locale ||
          objectRow(data['identity'])['server'] != server ||
          objectRow(data['identity'])['releaseId'] != identity['releaseId'] ||
          objectRow(data['identity'])['sourceId'] != identity['sourceId']) {
        throw const FormatException('growth-data-release');
      }
      if (!_closed && generation == _materialGeneration) materials = data;
    } catch (_) {
      if (!_closed && generation == _materialGeneration) materialError = true;
    }
    if (!_closed && generation == _materialGeneration) notifyListeners();
  }

  void stop() {
    _stopped = true;
    if (_task != null && host.ownsAuxiliaryTask(_task!)) host.engine?.cancel();
  }

  Future<bool> _step(
    String key,
    EngineRequest input,
    EngineRequest candidateInput,
    TeamGrowthChange change,
    Object task,
  ) async {
    bool active() =>
        !_closed && !_stopped && host.ownsAuxiliaryTask(task) && current;
    if (!active()) return false;
    var previous =
        results[key] ??
        (source.cycle == null ? host.training.cached(input) : null);
    if (previous != null) {
      results[key] = previous;
      if (previous.error == null && completeResponse(previous)) return true;
    }
    phase = key;
    notifyListeners();
    var request = freshGrowthRequest(input);
    if (source.cycle != null &&
        request.goal is EventGoal &&
        (request.goal as EventGoal).route == RouteKind.live) {
      final calibration = freshGrowthRequest(candidateInput).toJson(),
          goal = objectRow(calibration['goal']);
      goal['route'] = 'challenge';
      goal['songs'] = [for (final song in source.cycle!.songs) song.toJson()];
      goal['consumption'] = source.cycle!.consumption;
      goal.remove('gekiso');
      goal.remove('cpExchange');
      calibration.remove('aggregation');
      final calibrated = await host.training.evaluate(
        EngineRequest.fromJson(calibration),
      );
      if (!active()) return false;
      if (calibrated.error != null || !completeResponse(calibrated)) {
        throw StateError(calibrated.error ?? 'growth-cp-incomplete');
      }
      final event = calibrated.overall.firstOrNull?.event;
      if (event?.rewardSum == null || event?.orders == null) {
        throw StateError('growth-cp-empty');
      }
      final rate = cpExchangeOf(
        event!.rewardSum!,
        event.orders!,
        source.cycle!.consumption,
      );
      request = request.copyWith(
        goal: (request.goal as EventGoal).copyWith(cpExchange: rate),
      );
    }
    request = request.copyWith(
      contextKey: '${source.identity}:$key',
      seeds: previous?.overall,
      completed: previous?.results.where((row) => row.proven).toList(),
    );
    void accept(EngineResponse response) {
      if (!active()) return;
      results[key] = response;
      host.training.remember(request, response);
      notifyListeners();
    }

    final result = await host.engine!.run(
      request,
      null,
      (snapshot) => accept(snapshot.response),
    );
    accept(result);
    if (result.error != null) throw StateError(result.error!);
    return active() &&
        completeResponse(result) &&
        result.stopReason != 'cancelled';
  }

  Future<void> run({bool search = false}) async {
    final change = this.change;
    if (!current ||
        change.request == null ||
        host.engine == null ||
        host.running) {
      return;
    }
    if (search &&
        (results['fixedAfter'] == null ||
            !completeResponse(results['fixedAfter']!))) {
      return;
    }
    final task = host.acquireAuxiliaryTask();
    if (task == null) return;
    _task = task;
    _stopped = false;
    error = '';
    try {
      if (search) {
        if (await _step(
          'searchBefore',
          source.input,
          source.input,
          change,
          task,
        )) {
          await _step(
            'searchAfter',
            change.request!,
            change.request!,
            change,
            task,
          );
        }
      } else {
        var before = source.input, after = change.request!;
        if (before.goal is EventGoal &&
            (before.goal as EventGoal).rewardPlan?['autoCp'] != null) {
          if (!await _step('searchBefore', before, before, change, task) ||
              !await _step('searchAfter', after, after, change, task)) {
            return;
          }
          EngineRequest resolve(EngineRequest input, String phase) {
            final plan = results[phase]!.overall.firstOrNull?.event?.rewardPlan;
            if (plan == null) throw StateError('growth-missing-reward-plan');
            return input.copyWith(
              goal: (input.goal as EventGoal).copyWith(rewardPlan: plan),
            );
          }

          before = resolve(before, 'searchBefore');
          after = resolve(after, 'searchAfter');
        }
        if (await _step(
          'fixedBefore',
          fixedGrowthRequest(before, source.hit),
          before,
          change,
          task,
        )) {
          await _step(
            'fixedAfter',
            fixedGrowthRequest(after, source.hit),
            after,
            change,
            task,
          );
        }
      }
    } on EngineCancelled {
      _stopped = true;
    } catch (failure) {
      if (!_closed && !_stopped && current) {
        error = host.tb('searchFailed', 'The search failed: {reason}', {
          'reason': '$failure',
        });
      }
    } finally {
      host.releaseAuxiliaryTask(task);
      _task = null;
      phase = null;
      if (!_closed) notifyListeners();
    }
  }

  @override
  void dispose() {
    stop();
    _closed = true;
    _materialGeneration++;
    host.removeListener(_sync);
    super.dispose();
  }
}

Future<void> showTeamGrowth(
  BuildContext context,
  TeamBuilderController host,
  TeamGrowthSource? source, {
  TeamGrowthChoice? choice,
}) async {
  if (source == null) return;
  final comparison = TeamGrowthComparison(host, source, choice: choice);
  try {
    await showDialog<void>(
      context: context,
      builder: (context) => TeamGrowthDialog(comparison: comparison),
    );
  } finally {
    comparison.dispose();
  }
}

class TeamGrowthDialog extends StatelessWidget {
  const TeamGrowthDialog({super.key, required this.comparison});
  final TeamGrowthComparison comparison;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: comparison,
    builder: (context, _) => _content(context),
  );
  Widget _content(BuildContext context) {
    final vm = comparison,
        c = vm.host,
        catalog = c.catalog!,
        source = vm.source,
        choice = vm.choice,
        change = vm.change,
        theme = Theme.of(context);
    String t(String key) => c.tb('tg.$key', key);
    final row = choice.members
        ? source.input.members
              .firstWhere((row) => row.key == choice.key)
              .toJson()
        : source.input.snaps
              .firstWhere((row) => row.key == choice.key)
              .toJson();
    final actions = choice.members
        ? ['level', 'training', 'awakening', 'live', 'gekisou', 'full']
        : ['level', 'break', 'full'];
    String actionLabel(String action) => c.tb(growthLabels[action]!, action);
    EngineHit? hit(String phase) =>
        vm.results[phase]?.overall.firstOrNull ??
        (phase == 'fixedBefore' && !vm.results.containsKey(phase)
            ? source.hit
            : null);
    String metric(EngineHit? value) {
      if (value == null) return '—';
      final metric = resultMetric(value, source.settings, c.tb);
      return '${formatNumber(c.state.text.locale, metric.value, metric.digits)}${metric.unit.isEmpty ? '' : ' ${metric.unit}'}';
    }

    String delta(String a, String b) {
      final before = hit(a), after = hit(b);
      if (before == null || after == null) return '—';
      final x = resultMetric(before, source.settings, c.tb),
          y = resultMetric(after, source.settings, c.tb);
      if (x.unit != y.unit ||
          x.id != y.id && !x.id.startsWith('reward-plan:')) {
        return '—';
      }
      final difference = y.value - x.value;
      return '${difference > 0 ? '+' : ''}${formatNumber(c.state.text.locale, difference, 2)}${y.unit == '%' ? c.tb('percentagePoints', '') : y.unit}';
    }

    String status(String key) {
      final response = vm.results[key];
      if (vm.phase == key) return c.tb('searching', 'Searching teams');
      return response == null
          ? t(key == 'fixedBefore' ? 'original' : 'pending')
          : response.error != null
          ? t('failed')
          : !completeResponse(response)
          ? t('partial')
          : response.overall.isEmpty
          ? t('noTeam')
          : t('complete');
    }

    Widget value(String key) => Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t(key), style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(metric(hit(key)), style: theme.textTheme.headlineSmall),
            Text(status(key), style: theme.textTheme.labelMedium),
          ],
        ),
      ),
    );
    final cards = [
      for (final row in source.input.members)
        (true, row.key, row.cardId, source.hit.members.contains(row.key)),
      for (final row in source.input.snaps)
        (false, row.key, row.cardId, source.hit.snaps.contains(row.key)),
    ]..sort((a, b) => (b.$4 ? 1 : 0) - (a.$4 ? 1 : 0));
    final settings = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (MediaQuery.sizeOf(context).width >= 864) ...[
          Text(t('scenario'), style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
        ],
        DropdownButtonFormField<String>(
          key: ValueKey(choice.key),
          initialValue: choice.key,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: c.tb('growthComparison.card', 'Card'),
          ),
          items: [
            for (final (members, key, id, inTeam) in cards)
              DropdownMenuItem(
                value: key,
                child: Text(
                  '${catalog.cardName(members, id)} · ${t(inTeam ? 'inTeam' : 'inPool')}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: vm.phase != null
              ? null
              : (value) {
                  final selected = cards.firstWhere((row) => row.$2 == value);
                  vm.select(
                    TeamGrowthChoice(members: selected.$1, key: selected.$2),
                  );
                },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey(choice.action),
          initialValue: choice.action,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: c.tb('growthComparison.action', 'Training'),
          ),
          items: [
            for (final action in actions)
              DropdownMenuItem(value: action, child: Text(actionLabel(action))),
          ],
          onChanged: vm.phase != null
              ? null
              : (action) {
                  if (action != null) {
                    vm.select(choice.copyWith(action: action));
                  }
                },
        ),
        if (choice.action == 'level') ...[
          const SizedBox(height: 12),
          Segmented<String>(
            value: choice.target,
            options: [
              for (final target in ['next', 'cap'])
                Choice(target, c.tb('growthComparison.$target', target)),
            ],
            onSelected: (target) {
              if (vm.phase == null) vm.select(choice.copyWith(target: target));
            },
          ),
        ],
        const SizedBox(height: 12),
        Text(
          change.status == 'ready'
              ? (choice.action == 'full'
                    ? t('full')
                    : '${growthStage(choice.action, change.from!)} → ${growthStage(choice.action, change.to!)}')
              : c.tb('growthComparison.status.${change.status}', change.status),
        ),
        if (change.status == 'missing-state')
          TextButton(
            onPressed: () async {
              final before = canonical(
                c.store!.entries.map((k, v) => MapEntry(k, v.toJson())),
              );
              await showCardEditor(
                context,
                c,
                members: choice.members,
                id: intOf(row['cardId']),
              );
              if (context.mounted &&
                  before !=
                      canonical(
                        c.store!.entries.map((k, v) => MapEntry(k, v.toJson())),
                      )) {
                Navigator.of(context).pop();
              }
            },
            child: Text(c.tb('growthComparison.edit', 'Enter growth')),
          ),
        const SizedBox(height: 16),
        SpecList(
          facts: [
            Fact(
              t('pool'),
              '${source.input.members.length} / ${source.input.snaps.length}',
            ),
            Fact(
              c.tb('unknownPolicy', ''),
              c.tb(
                source.input.unknownPolicy.name == 'max'
                    ? 'unknownMax'
                    : 'unknownMin',
                '',
              ),
            ),
          ],
        ),
      ],
    );
    final result = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          source.hit.song == null
              ? resultMetric(source.hit, source.settings, c.tb).label
              : catalog.songTitle(source.hit.song!.songId),
          style: theme.textTheme.titleMedium,
        ),
        Text(t('snapshot'), style: theme.textTheme.labelMedium),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: value('fixedBefore')),
            Expanded(child: value('fixedAfter')),
          ],
        ),
        SpecList(
          facts: [Fact(t('fixedGain'), delta('fixedBefore', 'fixedAfter'))],
        ),
        ExpansionTile(
          title: Text(c.tb('formation', 'Formation')),
          children: [
            Formation(
              controller: c,
              hit: hit('fixedAfter') ?? source.hit,
              settings: source.settings,
              inputs: hit('fixedAfter') == null ? source.input : change.request,
            ),
          ],
        ),
        if (hit('searchAfter') case final upgraded?)
          ExpansionTile(
            title: Text(t('searchAfter')),
            initiallyExpanded: true,
            children: [
              if (upgraded.song != null)
                Text(
                  '${catalog.songTitle(upgraded.song!.songId)} · ${catalog.difficultyLabel(upgraded.song!.songId, upgraded.song!.difficulty)}',
                ),
              Formation(
                controller: c,
                hit: upgraded,
                settings: source.settings,
                inputs: change.request,
              ),
            ],
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(t('searchBefore'), style: theme.textTheme.titleMedium),
                Text(
                  '${metric(hit('searchBefore'))} → ${metric(hit('searchAfter'))}',
                  style: theme.textTheme.titleLarge,
                ),
                Text('${status('searchBefore')} · ${status('searchAfter')}'),
                SpecList(
                  facts: [
                    Fact(
                      t('searchGrowthGain'),
                      delta('searchBefore', 'searchAfter'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        GrowthMaterials(comparison: vm),
      ],
    );
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: SizedBox(
        width: 1160,
        height: MediaQuery.sizeOf(context).height * .9,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(t('title'), style: theme.textTheme.titleLarge),
                  ),
                  const CloseButton(),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => box.maxWidth >= 840
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(20),
                              child: result,
                            ),
                          ),
                          SizedBox(
                            width: 320,
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(20),
                              child: settings,
                            ),
                          ),
                        ],
                      )
                    : SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ExpansionTile(
                              title: Text(t('scenario')),
                              initiallyExpanded: true,
                              children: [settings],
                            ),
                            result,
                          ],
                        ),
                      ),
              ),
            ),
            if (vm.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(vm.error),
              ),
            if (vm.phase != null) const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: vm.phase != null
                    ? [
                        FilledButton.tonal(
                          onPressed: vm.stop,
                          child: Text(c.state.text('common.actions.cancel')),
                        ),
                      ]
                    : [
                        FilledButton(
                          onPressed:
                              change.status != 'ready' ||
                                  c.running ||
                                  !vm.current
                              ? null
                              : vm.run,
                          child: Text(t('runFixed')),
                        ),
                        FilledButton.tonal(
                          onPressed:
                              vm.results['fixedAfter'] == null ||
                                  !completeResponse(
                                    vm.results['fixedAfter']!,
                                  ) ||
                                  vm.results['fixedAfter']!.error != null ||
                                  c.running ||
                                  !vm.current
                              ? null
                              : () => vm.run(search: true),
                          child: Text(
                            t(
                              vm.results['searchAfter'] != null &&
                                      !completeResponse(
                                        vm.results['searchAfter']!,
                                      )
                                  ? 'continue'
                                  : 'runSearch',
                            ),
                          ),
                        ),
                      ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

int growthStage(String action, int value) =>
    ['training', 'awakening', 'break'].contains(action) ? value - 1 : value;

class GrowthMaterials extends StatelessWidget {
  const GrowthMaterials({super.key, required this.comparison});
  final TeamGrowthComparison comparison;
  @override
  Widget build(BuildContext context) {
    final vm = comparison, c = vm.host, choice = vm.choice;
    final input = choice.members
        ? vm.source.input.members
              .firstWhere((row) => row.key == choice.key)
              .toJson()
        : vm.source.input.snaps
              .firstWhere((row) => row.key == choice.key)
              .toJson();
    final card = dataRows(vm.materials?['cards'])
        .where(
          (row) =>
              row['id'] == input['cardId'] &&
              row['kind'] == (choice.members ? 'member' : 'support'),
        )
        .firstOrNull;
    if (card == null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          c.tb(
            vm.materialError ? 'growthComparison.loadError' : 'tg.pending',
            '—',
          ),
        ),
      );
    }
    final tracks = objectRow(card['tracks']),
        before = {
          for (final entry in growthFields.entries)
            entry.key: input[entry.value] as int?,
        },
        after = {
          for (final entry in growthFields.entries)
            entry.key: input[entry.value] as int?,
        };
    final actions = choice.action == 'full'
        ? tracks.keys.toList()
        : [choice.action];
    for (final action in actions) {
      final stages = dataRows(objectRow(tracks[action])['stages']);
      if (stages.isNotEmpty) {
        after[action] = choice.action == 'full'
            ? stages
                  .map((row) => intOf(row['value']))
                  .reduce((a, b) => a > b ? a : b)
            : vm.change.to;
      }
    }
    List<num>? stats(Map<String, int?> values) {
      List<int>? rates(String action) {
        final row = dataRows(objectRow(tracks[action])['stages'])
            .where((row) => row['value'] == values[action])
            .firstOrNull;
        return row?['rates'] is List ? intListOf(row!['rates']) : null;
      }

      final maximum = card['maximum'] is List
              ? intListOf(card['maximum'])
              : null,
          level = rates('level');
      if (maximum == null || level == null) return null;
      if (!choice.members) {
        return [
          for (var i = 0; i < 3; i++)
            f(f(imul(maximum[i], level[i])) / 10000).floor() / 100,
        ];
      }
      final training = rates('training'), rank = rates('awakening');
      if (training == null || rank == null) return null;
      return [
        for (var i = 0; i < 3; i++)
          f(f(maximum[i] * level[i]) / 10000).floor() +
              f(f(training[i] / 10000) * f(maximum[i])).floor() +
              f(f(imul(maximum[i], rank[i])) / 10000).floor(),
      ];
    }

    final oldStats = stats(before), newStats = stats(after);
    int? skillLevel(Doc skill, Map<String, int?> state) {
      final group = skill['group'];
      if (group == 'live') return state['live'];
      if (group == 'gekisou') return state['gekisou'];
      final action = choice.members ? 'awakening' : 'break';
      final effects = objectRow(
        dataRows(objectRow(tracks[action])['stages'])
            .where((row) => row['value'] == state[action])
            .firstOrNull?['effects'],
      );
      return effects[group == 'leader'
              ? 'leaderSkillLevel'
              : '${group == 'support' ? 'support' : 'gekisouSupport'}Skill0${intOf(skill['slot']) + 1}Level']
          as int?;
    }

    return ExpansionTile(
      title: Text(c.tb('tg.materials', 'Materials')),
      initiallyExpanded: true,
      children: [
        if (oldStats != null && newStats != null)
          SpecList(
            facts: [
              for (final (i, key) in [
                'performance',
                'technique',
                'visual',
              ].indexed)
                Fact(
                  c.state.text('catalog.cards.fields.$key'),
                  '${formatNumber(c.state.text.locale, oldStats[i], choice.members ? 0 : 2)} → ${formatNumber(c.state.text.locale, newStats[i], choice.members ? 0 : 2)}${choice.members ? '' : '%'}',
                ),
            ],
          ),
        for (final action in actions)
          if (before[action] != after[action]) ...[
            ListTile(
              title: Text(c.tb(growthLabels[action]!, action)),
              subtitle: Text(
                before[action] == null || after[action] == null
                    ? c.tb('growthComparison.status.missing-state', '—')
                    : '${growthStage(action, before[action]!)} → ${growthStage(action, after[action]!)}',
              ),
            ),
            if (action == 'level')
              Text(c.tb('growthComparison.expUnknown', '—'))
            else if (before[action] != null && after[action] != null)
              Builder(
                builder: (context) {
                  final steps = [
                    for (final row in dataRows(
                      objectRow(tracks[action])['costs'],
                    ))
                      CostStep(intOf(row['from']), intOf(row['to']), [
                        for (final item in dataRows(row['items']))
                          CostItem(
                            '${item['identity']}',
                            '${item['name']}',
                            intOf(item['count']),
                            image: item['image'] as String?,
                            onTap: item['href'] is String
                                ? () => openLink(context, '${item['href']}')
                                : null,
                          ),
                      ]),
                  ];
                  return summarizeCosts(
                            steps,
                            before[action]!,
                            after[action]!,
                          ) ==
                          null
                      ? Text(c.tb('growthComparison.status.missing-data', '—'))
                      : UpgradeCost(
                          label: c.tb(growthLabels[action]!, action),
                          steps: steps,
                          to: after[action]!,
                          initial: before[action]!,
                          framed: false,
                        );
                },
              ),
            for (final skill in dataRows(card['skills']))
              if (skillLevel(skill, before) !=
                  skillLevel(skill, {...before, action: after[action]}))
                ListTile(
                  title: Text('${skill['name']}'),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final state in [
                        before,
                        {...before, action: after[action]},
                      ])
                        Text(
                          '${c.tb('level', 'Level')} ${skillLevel(skill, state) ?? '—'}\n${dataRows(skill['levels']).where((row) => row['level'] == skillLevel(skill, state)).firstOrNull?['description'] ?? '—'}',
                        ),
                    ],
                  ),
                ),
          ],
      ],
    );
  }
}
