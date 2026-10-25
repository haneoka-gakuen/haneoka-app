/// Search results: ranked team cards, per-song rankings, the plan summary,
/// skill orders and comparison (`lit/team-builder/results.ts`).
library;

import 'reward_plan_view.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../catalog/catalog_screen.dart' show cardRarityName;
import '../catalog/chart_rates.dart';
import '../catalog/deck_state.dart';
import '../catalog/song_meta.dart';
import 'rank_targets.dart';
import 'engine/box.dart';
import 'engine/skills.dart';
import 'engine/power.dart';

import '../ui/app_image.dart';
import '../ui/card_artwork.dart';
import '../ui/scrollable_choice_chips.dart';
import '../ui/theme.dart';
import 'box.dart';
import 'controller.dart';
import 'engine/api.dart';
import 'engine/num.dart';
import 'engine/execution.dart';
import 'engine/live.dart' show orders;
import 'engine_client.dart';
import 'result_image.dart';
import 'result_metric.dart';
import 'result_comparison.dart';
import 'settings.dart';
import 'widgets.dart';

const rankNames = {1: 'E', 2: 'D', 3: 'C', 4: 'B', 5: 'A', 6: 'S', 7: 'SS'};

String hitKey(EngineHit hit) =>
    '${hit.song?.key ?? '-'}|${hit.members.join(',')}|${hit.snaps.join(',')}';

CardGrowthDisplay? _resultGrowth(
  TeamBuilderController c,
  String key,
  bool member,
) {
  final inputs = c.activity && c.settings.rewardMode == 'recommendation'
      ? c.pt.job?.request
      : c.resultInputs;
  if (inputs == null) return null;
  final input = member
      ? inputs.members.where((row) => row.key == key).firstOrNull
      : inputs.snaps.where((row) => row.key == key).firstOrNull;
  return input == null
      ? null
      : c.catalog!.resolvedGrowth(input, inputs.unknownPolicy);
}

void openResultSongAnalysis(
  BuildContext context,
  TeamBuilderController c,
  EngineHit hit,
  BuildSettings settings,
) {
  final inputs = c.activity && c.settings.rewardMode == 'recommendation'
      ? c.pt.job?.request
      : c.resultInputs;
  if (inputs == null) return;
  final master = c.catalog!.master,
      box = resolveBox(
        master,
        inputs.members.where((row) => hit.members.contains(row.key)).toList(),
        inputs.snaps.where((row) => hit.snaps.contains(row.key)).toList(),
        inputs.unknownPolicy,
      );
  final slots = [
    for (var index = 0; index < hit.members.length; index++)
      () {
        final member = box.members
            .where((m) => m.key == hit.members[index])
            .firstOrNull;
        if (member == null) return const DeckSlot(score: 0);
        final snapKey = hit.snaps.elementAtOrNull(index),
            snap = box.snaps.where((s) => s.key == snapKey).firstOrNull,
            skill = resolveSlotSkill(master, member, snap);
        double percent(int type) => effectPercent(skill, type);
        return DeckSlot(
          score: percent(2000),
          perfect: percent(2004),
          extensionMs: skill.extensionMs.round(),
        );
      }(),
  ];
  if (slots.length != 5) return;
  var deck = AnalysisDeckController.instance.value.copyWith(
    power: hit.power,
    slots: slots,
  );
  final event = master.events[settings.eventId];
  if (hit.event != null &&
      settings.goal == GoalKind.event &&
      settings.route != 'challenge' &&
      event != null) {
    int bonus(int type) =>
        ((box.members.fold<int>(
                      0,
                      (sum, member) =>
                          sum + memberEventPercent(event.effects, member, type),
                    ) +
                    box.snaps.fold<int>(
                      0,
                      (sum, snap) =>
                          sum + snapEventPercent(event.effects, snap, type),
                    )) /
                100)
            .floor();
    deck = deck.copyWith(
      event: settings.eventId,
      boosts: settings.boosts,
      pointBonus: bonus(0),
      itemBonus: bonus(1),
    );
  }

  AnalysisDeckController.instance.set(deck);
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: RouteSettings(
        name: Uri(
          path: '/catalog/song-meta',
          queryParameters: deck.query,
        ).toString(),
      ),
      builder: (_) =>
          SongMetaScreen(initialQuery: deck.query, server: c.server),
    ),
  );
}

List<(String, String)> resultConditions(
  TeamBuilderController c,
  EngineHit hit,
  BuildSettings settings,
) {
  final input = c.activity && c.settings.rewardMode == 'recommendation'
      ? c.pt.job?.request
      : c.resultInputs;
  if (input == null) return [];
  final goal = input.goal;
  final metric = resultMetric(hit, settings, c.tb);
  final play = switch (goal) {
    ScoreGoal(:final play) => play,
    EventGoal(:final play) => play,
    PlanGoal(:final play) => play,
    _ => null,
  };
  return [
    (
      c.state.text('common.fields.source'),
      c.tb('boxImport.servers.${c.server}', c.server),
    ),
    (
      c.tb('members', 'Members'),
      c.tb(settings.theoretical ? 'scopeAll' : 'scopeBox', ''),
    ),
    (
      c.tb('unknownPolicy', 'Growth not entered'),
      c.tb(
        input.unknownPolicy == UnknownPolicy.max ? 'unknownMax' : 'unknownMin',
        '',
      ),
    ),
    (c.tb('goal', 'Goal'), metric.label),
    if (goal is EventGoal || goal is PlanGoal)
      (
        c.tb('farm.memory', 'Character / song memory bonuses'),
        c.tb(
          goal is PlanGoal ||
                  settings.farming['includeMemory'] == true &&
                      settings.rewardMode != 'recommendation'
              ? 'farm.included'
              : 'farm.excluded',
          '',
        ),
      ),
    if (hit.event?.rewardPlan case final plan?)
      (c.tb('rewardPlan.order', 'Ranking'), rewardRankingLabel(c, plan)),
    if (hit.event?.rewardValues case final values?)
      for (final entry in values.entries)
        (
          rewardLabel(c, entry.key),
          formatNumber(
            c.state.text.locale,
            numOf(objectRow(entry.value)['value']),
            4,
          ),
        ),
    if (goal is EventGoal && goal.weights != null)
      for (final (key, label) in [
        ('points', 'weightPoints'),
        ('items', 'weightItems'),
        ('challengePoints', 'weightCp'),
      ])
        (c.tb(label, ''), '${goal.weights![key]}'),
    if (play != null)
      (
        c.tb('playJudgements', 'Play judgements'),
        play.isAllPerfect
            ? c.tb('playAp', 'All Perfect')
            : 'GREAT ${formatNumber(c.state.text.locale, play.great * 100, 1)}% · GOOD ${formatNumber(c.state.text.locale, play.good * 100, 1)}% · BAD ${formatNumber(c.state.text.locale, play.bad * 100, 1)}% · MISS ${formatNumber(c.state.text.locale, play.miss * 100, 1)}%',
      ),
    if (play != null && play.missEvery > 0)
      (c.tb('missEvery', 'Miss every N notes'), '${play.missEvery}'),
    if (goal is GekisoGoal) ...[
      (
        'GREAT',
        '${formatNumber(c.state.text.locale, goal.accuracy.great * 100, 1)}%',
      ),
      (
        'JUST',
        '${formatNumber(c.state.text.locale, goal.accuracy.just * 100, 1)}%',
      ),
      (c.tb('pt.luckSamples', 'Luck samples'), '${goal.seeds}'),
      (c.tb('missEvery', 'Miss every N notes'), '${goal.accuracy.missEvery}'),
      (
        c.tb('minComboBonus', 'Minimum base COMBO BONUS'),
        '×${goal.minComboBonus}',
      ),
      (
        c.tb('gekisoPlacements', 'Scoring placements'),
        (c.results?.results
                    .where((row) => row.song == hit.song)
                    .firstOrNull
                    ?.placements ??
                [goal.rank, goal.rank, goal.rank])
            .join(' · '),
      ),
    ],
    if (goal is EventGoal && goal.gekiso != null) ...[
      (
        'JUST',
        '${formatNumber(c.state.text.locale, goal.gekiso!.just * 100, 1)}%',
      ),
      (c.tb('pt.luckSamples', 'Luck samples'), '${goal.gekiso!.luckSamples}'),
      (
        c.tb('minComboBonus', 'Minimum base COMBO BONUS'),
        '×${goal.minComboBonus}',
      ),
    ],
    if (goal is EventGoal || goal is PlanGoal) ...[
      (
        c.tb('event', 'Event'),
        c.catalog!
                .events()
                .where((row) => row.id == settings.eventId)
                .firstOrNull
                ?.name ??
            '${settings.eventId}',
      ),
      (
        c.tb('route', 'Live type'),
        c.tb(switch (settings.route) {
          'challenge' => 'routeChallenge',
          'skip' => 'routeSkip',
          _ => 'routeLive',
        }, ''),
      ),
    ],
    if (goal is PlanGoal) ...[
      (c.tb('planBudget', 'Boosts to spend'), '${goal.boostBudget}'),
      (
        c.tb('planStartCp', 'Challenge points now'),
        '${goal.startingChallengePoints}',
      ),
    ],
    if (goal is EventGoal || goal is PlanGoal)
      (
        c.tb(settings.route == 'challenge' ? 'cpPerLive' : 'boosts', ''),
        '${settings.route == 'challenge' ? settings.challengePoints : settings.boosts}',
      ),
    if (settings.goal == GoalKind.score && settings.scoreTarget != 'none')
      (
        c.tb('targetScore', 'Target score'),
        formatNumber(c.state.text.locale, settings.targetScore ?? 0),
      ),
  ];
}

class ResultsView extends StatefulWidget {
  const ResultsView({super.key, required this.controller});
  final TeamBuilderController controller;

  @override
  State<ResultsView> createState() => _ResultsViewState();
}

class _ResultsViewState extends State<ResultsView> {
  String _tab = 'overall';

  TeamBuilderController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    final activityResult =
        c.resultSettings?.goal == GoalKind.event ||
        c.resultSettings?.goal == GoalKind.plan;
    final results = activityResult == c.activity ? c.results : null;
    final theme = Theme.of(context);
    final locale = c.state.text.locale;
    if (results == null) {
      return ToolSection(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Column(
              children: [
                Icon(
                  Symbols.groups_rounded,
                  size: 40,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 12),
                Text(
                  c.tb('resultsEmpty', 'Results appear here'),
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
          ),
        ],
      );
    }
    final settings = c.resultSettings ?? c.settings;
    final catalog = c.catalog!;
    if (_tab != 'overall' && !results.results.any((r) => r.song?.key == _tab)) {
      _tab = 'overall';
    }
    final multi = results.results.length > 1 && settings.goal != GoalKind.plan;
    final tab = multi ? _tab : 'all';
    final shown = results.plan != null
        ? [?results.plan!.normal, ?results.plan!.challenge]
        : tab == 'overall' || !multi
        ? (multi ? results.overall : results.results.firstOrNull?.hits ?? [])
        : results.results.where((r) => r.song?.key == tab).firstOrNull?.hits ??
              [];
    final groups = multi && tab != 'overall'
        ? [
            for (final r in results.results)
              if (r.song?.key == tab) r,
          ]
        : results.results;
    final proven = groups.isNotEmpty && groups.every((r) => r.proven);
    final gap = proven ? null : improvementPercent(groups);
    final exact = results.results.fold(0, (sum, r) => sum + r.stats.exact);
    final proof = proven
        ? c.tb('proven', 'Proven optimal')
        : c.tb('recommendation', 'Recommendation');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  proven
                      ? Symbols.verified_rounded
                      : Symbols.hourglass_bottom_rounded,
                  size: 18,
                  color: proven
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    gap == null
                        ? proof
                        : '$proof · ${c.tb('improvementBound', 'Up to {percent}% improvement', {'percent': gap})}',
                    style: theme.textTheme.labelLarge,
                  ),
                ),
              ],
            ),
            if (c.stale)
              FilledButton.tonalIcon(
                onPressed: c.run,
                icon: const Icon(Symbols.refresh_rounded),
                label: Text(c.tb('rerun', 'Search again')),
              )
            else
              Text(
                c.tb(
                  'resultMeta',
                  '{ms} ms · {exact} teams simulated exactly',
                  {
                    'ms': formatNumber(locale, results.elapsedMs),
                    'exact': exact,
                  },
                ),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonal(
            onPressed: proven || c.stale || c.running
                ? null
                : () => c.run(resume: true),
            child: Text(
              c.tb('continueOptimal', 'Continue verifying optimality'),
            ),
          ),
        ),
        if (results.unknownCards.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            c.tb(
              'unknownCards',
              '{count} saved cards are not in this data release and were skipped.',
              {'count': results.unknownCards.length},
            ),
          ),
        ],
        if (results.plan case final plan?) ...[
          const SizedBox(height: 12),
          ToolSection(
            title: c.tb('planTotal', 'Total event points'),
            children: [
              Text(
                formatNumber(locale, plan.eventPoints),
                style: theme.textTheme.headlineMedium,
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ValueChip(
                    label: c.tb('normalLives', 'Normal lives'),
                    value: '${plan.normalLives}',
                  ),
                  ValueChip(
                    label: c.tb('challengeLives', 'Challenge lives'),
                    value: formatNumber(locale, plan.challengeLives, 2),
                  ),
                  ValueChip(
                    label: c.tb('cpEarned', 'Challenge points earned'),
                    value: formatNumber(locale, plan.challengePointsEarned, 2),
                  ),
                  ValueChip(
                    label: c.tb('cpLeft', 'Left over'),
                    value: formatNumber(
                      locale,
                      plan.leftoverChallengePoints,
                      2,
                    ),
                  ),
                  ValueChip(
                    label: c.tb('perBoost', 'Per boost'),
                    value: formatNumber(locale, plan.perBoost, 1),
                  ),
                ],
              ),
            ],
          ),
        ],
        if (multi) ...[
          const SizedBox(height: 12),
          ScrollableChoiceChips(
            label: c.tb('songs', 'Songs'),
            previousLabel: c.state.text('common.actions.previous', 'Previous'),
            nextLabel: c.state.text('common.actions.next', 'Next'),
            value: tab,
            items: [
              ('overall', c.tb('overall', 'Overall')),
              for (final r in results.results)
                (
                  r.song!.key,
                  '${catalog.songTitle(r.song!.songId)} ${catalog.difficultyLabel(r.song!.songId, r.song!.difficulty)}',
                ),
            ],
            onSelected: (id) => setState(() => _tab = id),
          ),
        ],
        const SizedBox(height: 12),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text(c.tb('noTeams', 'No team meets these conditions')),
            ),
          )
        else
          for (final (index, hit) in shown.indexed) ...[
            if (index > 0) const SizedBox(height: 12),
            _HitCard(
              key: ValueKey((c.resultSession, hitKey(hit))),
              controller: c,
              hit: hit,
              index: index,
              settings: c.settingsForHit(hit),
              compared: c.compared.any(
                (row) => row.id == c.compareEntry(hit, index + 1)?.id,
              ),
              onCompare: () => c.toggleCompared(hit, index + 1),
            ),
          ],
        if (shown.isNotEmpty &&
            settings.goal != GoalKind.plan &&
            !settings.theoretical &&
            !c.stale) ...[
          const SizedBox(height: 16),
          ToolSection(
            title: c.tb('growthTitle', 'Training priorities'),
            children: [
              if (c.currentGrowth && c.growth != null) ...[
                if ((c.growth!['upgrades'] as List)
                    .where(
                      (row) =>
                          (row as Map)['gain'] is num &&
                          (row['gain'] as num) > 1e-9,
                    )
                    .isEmpty)
                  Text(
                    c.tb(
                      'growthNone',
                      'No single card upgrade improves the best team.',
                    ),
                  ),
                for (final row
                    in (c.growth!['upgrades'] as List)
                        .cast<Map>()
                        .where((row) => (row['gain'] as num) > 1e-9)
                        .take(8))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: SizedBox(
                      width: 48,
                      child: CardArt(
                        catalog: catalog,
                        members: row['kind'] == 'members',
                        id: cardIdOf('${row['key']}'),
                        emblems: false,
                      ),
                    ),
                    title: Text(
                      catalog.cardName(
                        row['kind'] == 'members',
                        cardIdOf('${row['key']}'),
                      ),
                    ),
                    subtitle: Text(
                      '+${formatNumber(locale, row['gain'] as num, 2)}',
                    ),
                  ),
              ] else
                FilledButton.tonalIcon(
                  onPressed: c.running ? null : c.recommendGrowth,
                  icon: const Icon(Symbols.trending_up_rounded),
                  label: Text(
                    c.growthRunning
                        ? c.tb(
                            'growthProgress',
                            'Checking cards {done}/{total}',
                            {
                              'done': c.growthProgress.$1,
                              'total': c.growthProgress.$2,
                            },
                          )
                        : c.tb('growthRun', 'Find the best card to train'),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

Future<void> showResultComparison(
  BuildContext context,
  TeamBuilderController controller, {
  bool rewards = false,
}) => showDialog<void>(
  context: context,
  builder: (context) => Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 24),
    child: SizedBox(
      width: 1100,
      height: MediaQuery.sizeOf(context).height * .86,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final entries = rewards ? controller.ptCompared : controller.compared;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        controller.tb('comparison', 'Comparison'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    TextButton(
                      onPressed: entries.isEmpty
                          ? null
                          : () {
                              entries.clear();
                              controller.changed();
                              Navigator.of(context).pop();
                            },
                      child: Text(
                        controller.state.text('common.actions.clear'),
                      ),
                    ),
                    const CloseButton(),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final entry in entries)
                            InputChip(
                              label: Text('#${entry.position}'),
                              onDeleted: () {
                                entries.remove(entry);
                                controller.changed();
                                if (entries.isEmpty) {
                                  Navigator.of(context).pop();
                                }
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (entries.length >= 2)
                        ResultComparisonPanel(
                          controller: controller,
                          entries: entries,
                        )
                      else
                        Text(
                          controller.tb(
                            'comparisonNeedTwo',
                            'Select one more candidate to compare.',
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  ),
);

class ResultComparisonPanel extends StatefulWidget {
  const ResultComparisonPanel({
    super.key,
    required this.controller,
    required this.entries,
  });
  final TeamBuilderController controller;
  final List<ComparedResult> entries;
  @override
  State<ResultComparisonPanel> createState() => _ResultComparisonPanelState();
}

class _ResultComparisonPanelState extends State<ResultComparisonPanel> {
  String? _baseline, _candidate;
  TeamBuilderController get c => widget.controller;
  @override
  Widget build(BuildContext context) {
    final pickedEntries = widget.entries;
    if (pickedEntries.length < 2) return const SizedBox.shrink();
    final foundBaseline = pickedEntries.indexWhere(
      (entry) => entry.id == _baseline,
    );
    final baselineIndex = foundBaseline < 0 ? 0 : foundBaseline;
    final baseline = pickedEntries[baselineIndex];
    final compact = MediaQuery.sizeOf(context).width < 840;
    var candidate = pickedEntries.indexWhere((entry) => entry.id == _candidate);
    if (candidate < 0 || candidate == baselineIndex) {
      candidate = baselineIndex == 0 ? 1 : 0;
    }
    final entries = compact
        ? [baseline, pickedEntries[candidate]]
        : [
            baseline,
            for (var i = 0; i < pickedEntries.length; i++)
              if (i != baselineIndex) pickedEntries[i],
          ];
    final picked = entries.map((row) => row.hit).toList();
    final locale = c.state.text.locale;
    final catalog = c.catalog!;
    final rows = <(String, String Function(EngineHit))>[
      (
        c.tb('comparisonValue', 'Value'),
        (hit) {
          final entry = entries[picked.indexOf(hit)];
          final metric = resultMetric(hit, entry.settings, c.tb);
          return '${formatNumber(locale, metric.value, metric.digits)}${metric.unit}';
        },
      ),
      (c.tb('power', 'Power'), (hit) => formatNumber(locale, hit.power)),
      if (picked.any((hit) => hit.score != null)) ...[
        (
          c.tb('expectedScore', 'Expected score'),
          (hit) =>
              hit.score == null ? '—' : formatNumber(locale, hit.score!.mean),
        ),
        (
          c.tb('worstScore', 'Worst-order score'),
          (hit) =>
              hit.score == null ? '—' : formatNumber(locale, hit.score!.min),
        ),
        (
          c.tb('bestScore', 'Best-order score'),
          (hit) =>
              hit.score == null ? '—' : formatNumber(locale, hit.score!.max),
        ),
      ],
      if (picked.any((hit) => hit.event != null)) ...[
        (
          c.tb('eventBonus', 'Event bonus'),
          (hit) => hit.event == null
              ? '—'
              : '+${formatNumber(locale, hit.event!.bonusPercent.floor())}%',
        ),
      ],
      (
        c.tb('leader', 'Leader'),
        (hit) => catalog.characterName(
          catalog.characterIds(true, cardIdOf(hit.members.first)).firstOrNull ??
              0,
        ),
      ),
    ];
    return ToolSection(
      children: [
        DropdownButtonFormField<int>(
          key: ValueKey('baseline:$baselineIndex:${pickedEntries.length}'),
          initialValue: baselineIndex,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: c.tb('comparisonBaseline', 'Baseline'),
          ),
          items: [
            for (var i = 0; i < pickedEntries.length; i++)
              DropdownMenuItem(
                value: i,
                child: Text(
                  '#${pickedEntries[i].position} · ${pickedEntries[i].hit.song == null ? c.tb('goalPower', 'Power') : catalog.songTitle(pickedEntries[i].hit.song!.songId)}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (value) =>
              setState(() => _baseline = pickedEntries[value ?? 0].id),
        ),
        if (compact && pickedEntries.length > 2)
          DropdownButtonFormField<int>(
            key: ValueKey('candidate:$candidate:${pickedEntries.length}'),
            initialValue: candidate,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: c.tb('comparisonCandidate', 'Candidate'),
            ),
            items: [
              for (var i = 0; i < pickedEntries.length; i++)
                if (i != baselineIndex)
                  DropdownMenuItem(
                    value: i,
                    child: Text('#${pickedEntries[i].position}'),
                  ),
            ],
            onChanged: (value) =>
                setState(() => _candidate = pickedEntries[value ?? 1].id),
          ),
        for (final entry in entries.skip(1))
          Builder(
            builder: (context) {
              final a = resultMetric(baseline.hit, baseline.settings, c.tb),
                  b = resultMetric(entry.hit, entry.settings, c.tb);
              final difference = baseline.difference(entry);
              final relative = a.value > 0 && b.relative
                  ? (b.value - a.value) / a.value * 100
                  : null;
              final valid =
                  baseline.conditions == entry.conditions &&
                  a.id == b.id &&
                  a.unit == b.unit;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (valid)
                    Text(
                      '${b.label}: ${formatNumber(locale, b.value, b.digits)}${b.unit} (${b.value >= a.value ? '+' : ''}${formatNumber(locale, b.value - a.value, b.digits)}${b.unit}${relative == null ? '' : ' · ${formatNumber(locale, relative, 2)}%'})',
                    ),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      for (final (key, label) in [
                        ('members', c.tb('diffmembers', 'Member replacements')),
                        ('snaps', c.tb('diffsnaps', 'Snapshot replacements')),
                        (
                          'bindings',
                          c.tb('diffbindings', 'Snapshot rebindings'),
                        ),
                        ('growth', c.tb('diffgrowth', 'Growth changes')),
                        ('leader', c.tb('leader', 'Leader')),
                      ])
                        Text('$label: ${difference[key]}'),
                    ],
                  ),
                ],
              );
            },
          ),
        for (final entry in entries.where((entry) => !entry.listed))
          Text(
            '#${entry.position} · ${c.tb('outsideRanking', 'Outside current ranking')}',
          ),
        LayoutBuilder(
          builder: (context, box) {
            final valueWidth = (box.maxWidth - 104) / picked.length;
            Widget cell(String value, {bool label = false}) => compact
                ? SizedBox(
                    width: label ? 80 : valueWidth,
                    child: Text(
                      value,
                      textAlign: label ? TextAlign.start : TextAlign.end,
                    ),
                  )
                : Text(value);
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: compact ? 12 : 56,
                horizontalMargin: compact ? 0 : 24,
                dataRowMaxHeight: double.infinity,
                columns: [
                  DataColumn(
                    label: compact
                        ? const SizedBox(width: 80)
                        : const SizedBox(),
                  ),
                  for (final hit in picked)
                    DataColumn(
                      label: cell('#${entries[picked.indexOf(hit)].position}'),
                      numeric: true,
                    ),
                ],
                rows: [
                  for (final (label, value) in rows)
                    DataRow(
                      cells: [
                        DataCell(cell(label, label: true)),
                        for (final hit in picked) DataCell(cell(value(hit))),
                      ],
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _HitCard extends StatefulWidget {
  const _HitCard({
    super.key,
    required this.controller,
    required this.hit,
    required this.index,
    required this.settings,
    required this.compared,
    required this.onCompare,
  });
  final TeamBuilderController controller;
  final EngineHit hit;
  final int index;
  final BuildSettings settings;
  final bool compared;
  final VoidCallback onCompare;

  @override
  State<_HitCard> createState() => _HitCardState();
}

class _HitCardState extends State<_HitCard> {
  bool _expanded = false;

  TeamBuilderController get c => widget.controller;
  EngineHit get hit => widget.hit;

  void _openAnalysis() =>
      openResultSongAnalysis(context, c, hit, widget.settings);

  ({String label, String value}) _primary() {
    final metric = resultMetric(hit, widget.settings, c.tb);
    return (
      label: metric.label,
      value:
          '${formatNumber(c.state.text.locale, metric.value, metric.digits)}${metric.unit}',
    );
  }

  List<Widget> _chips() {
    final s = widget.settings;
    final locale = c.state.text.locale;
    final placements =
        c.results?.results
            .where((row) => row.song == hit.song)
            .firstOrNull
            ?.placements ??
        (!s.opponentsMode ? [s.gekisoRank, s.gekisoRank, s.gekisoRank] : null);
    return [
      if (s.goal == GoalKind.gekiso && placements != null)
        ValueChip(
          label: c.tb('gekisoPlacements', 'Scoring placements'),
          value: placements.join(' · '),
        ),
      if (hit.comboBonus != null)
        ValueChip(
          label: c.tb('comboBonus', 'Base COMBO BONUS'),
          value: '×${hit.comboBonus}',
        ),
      if (hit.event?.rewardValues case final values?)
        for (final entry in values.entries)
          ValueChip(
            label: rewardLabel(c, entry.key),
            value: formatNumber(
              locale,
              numOf(objectRow(entry.value)['value']),
              4,
            ),
          ),
      if (hit.event?.rewardPlan == null && hit.event?.otherMean != null)
        ValueChip(
          label: c.tb(
            s.measure == 'items' ? 'pointsPerPlay' : 'itemsPerPlay',
            '',
          ),
          value: formatNumber(locale, hit.event!.otherMean!, 1),
        ),
      if (s.goal != GoalKind.power)
        ValueChip(
          icon: Symbols.bolt_rounded,
          label: c.tb('power', 'Power'),
          value: formatNumber(locale, hit.power),
        ),
      if (hit.score case final score?) ...[
        if ((s.goal != GoalKind.score && s.goal != GoalKind.gekiso) ||
            s.criterion != 'mean')
          ValueChip(
            label: c.tb('expectedScore', 'Average score'),
            value: formatNumber(locale, score.mean),
          ),
        ValueChip(
          label: c.tb('scoreRange', 'Range'),
          value:
              '${formatNumber(locale, score.min)} – ${formatNumber(locale, score.max)}',
        ),
        if ((score.ranks.entries.toList()..sort((a, b) => b.key - a.key))
                .firstOrNull
            case final top?)
          ValueChip(
            icon: Symbols.workspace_premium_rounded,
            label: rankNames[top.key] ?? '${top.key}',
            value:
                '${formatNumber(locale, top.value / 120 * 100, top.value == 120 ? 0 : 1)}%',
          ),
      ],
      if (hit.event?.rewardPlan == null && hit.event != null) ...[
        if (hit.event case final event?) ...[
          ValueChip(
            icon: Symbols.trending_up_rounded,
            label: c.tb('eventBonus', 'Event bonus'),
            value: '+${formatNumber(locale, event.bonusPercent.floor())}%',
          ),
          if (event.challengePoints != 0 && s.measure != 'challenge-points')
            ValueChip(
              label: c.tb('cpPerPlay', 'Challenge points per play'),
              value: formatNumber(locale, event.challengePoints, 1),
            ),
        ],
      ],
      if (hit.skipScore case final skip?)
        ValueChip(
          icon: Symbols.fast_forward_rounded,
          label: c.tb('skipScore', 'Skip score'),
          value: formatNumber(locale, skip),
        ),
      if (hit.potential case final potential?)
        ValueChip(
          label: c.tb('skillCoverage', 'Skill coverage'),
          value: '${formatNumber(locale, potential.area * 100)}%·s',
        ),
    ];
  }

  void _copy() {
    final catalog = c.catalog!;
    final main = _primary();
    final lines = [
      if (hit.song case final song?)
        '${catalog.songTitle(song.songId)} ${catalog.difficultyLabel(song.songId, song.difficulty)}',
      '${main.label}: ${main.value} · ${c.tb('power', 'Power')}: ${formatNumber(c.state.text.locale, hit.power)}',
      ...resultConditions(
        c,
        hit,
        widget.settings,
      ).map((condition) => '${condition.$1}: ${condition.$2}'),
      for (final (index, key) in hit.members.indexed)
        '${index == 0 ? '[${c.tb('leader', 'Leader')}] ' : ''}'
            '${catalog.cardName(true, cardIdOf(key))} (${catalog.cardSubtitle(true, cardIdOf(key))}) + '
            '${hit.snaps[index] == null ? '—' : catalog.cardName(false, cardIdOf(hit.snaps[index]!))}',
    ];
    Clipboard.setData(ClipboardData(text: lines.join('\n')));
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(c.tb('copied', 'Copied'))));
  }

  bool _rendering = false;

  /// `exportImage`.
  Future<void> _saveImage() async {
    setState(() => _rendering = true);
    try {
      await saveResultImage(
        await renderHitImage(c, hit, _primary(), Theme.of(context).colorScheme),
      );
    } finally {
      if (mounted) setState(() => _rendering = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final catalog = c.catalog!;
    final main = _primary();
    final best = widget.index == 0;
    return Material(
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Corner.large),
        side: BorderSide(
          color: best
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
          width: best ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final leading = Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: best
                          ? theme.colorScheme.primary
                          : theme.colorScheme.surfaceContainerHighest,
                      foregroundColor: best
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.onSurfaceVariant,
                      child: Text('${widget.index + 1}'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            [
                              main.label,
                              if (hit.song case final song?
                                  when widget.settings.songs.length > 1)
                                '${catalog.songTitle(song.songId)} ${catalog.difficultyLabel(song.songId, song.difficulty)}',
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            main.value,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
                final actions = Wrap(
                  children: [
                    IconButton(
                      tooltip: c.tb('saveTeam', 'Save team'),
                      onPressed: c.stale
                          ? null
                          : () {
                              c.saveTeam(
                                [for (final key in hit.members) cardIdOf(key)],
                                [
                                  for (final key in hit.snaps)
                                    key == null ? null : cardIdOf(key),
                                ],
                                hit.song,
                              );
                              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                SnackBar(
                                  content: Text(
                                    c.tb('savedTeam', 'Saved to Teams'),
                                  ),
                                ),
                              );
                            },
                      icon: const Icon(Symbols.bookmark_add_rounded),
                    ),
                    IconButton(
                      tooltip: c.tb('compare', 'Compare'),
                      isSelected: widget.compared,
                      onPressed: widget.onCompare,
                      icon: const Icon(Symbols.compare_arrows_rounded),
                    ),
                    IconButton(
                      tooltip: c.tb('copyTeam', 'Copy as text'),
                      onPressed: _copy,
                      icon: const Icon(Symbols.content_copy_rounded),
                    ),
                    IconButton(
                      tooltip: c.tb(
                        'songMetaWithTeam',
                        'Song analysis with this team',
                      ),
                      onPressed: _openAnalysis,
                      icon: const Icon(Symbols.query_stats_rounded),
                    ),
                    IconButton(
                      tooltip: c.tb('saveImage', 'Save image'),
                      onPressed: _rendering ? null : _saveImage,
                      icon: const Icon(Symbols.image_rounded),
                    ),
                  ],
                );
                return constraints.maxWidth >= 640
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: leading),
                          actions,
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          leading,
                          Align(
                            alignment: Alignment.centerRight,
                            child: actions,
                          ),
                        ],
                      );
              },
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: _chips()),
            const SizedBox(height: 12),
            Formation(controller: c, hit: hit, settings: widget.settings),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(
                  _expanded
                      ? Symbols.expand_less_rounded
                      : Symbols.expand_more_rounded,
                ),
                label: Text(
                  _expanded
                      ? c.tb('lessDetail', 'Less')
                      : c.tb('moreDetail', 'Details'),
                ),
              ),
            ),
            if (_expanded) ...[
              ToolSection(
                title: c.tb('originalConditions', 'Original result conditions'),
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (label, value) in resultConditions(
                        c,
                        hit,
                        widget.settings,
                      ))
                        ValueChip(label: label, value: value),
                    ],
                  ),
                ],
              ),
              if (hit.score != null) _Distribution(controller: c, hit: hit),
              TeamRankTargets(
                controller: c,
                hit: hit,
                settings: widget.settings,
              ),
              if (hit.song != null &&
                  (hit.score?.orders.isNotEmpty ?? false)) ...[
                const SizedBox(height: 16),
                _SkillOrders(controller: c, hit: hit),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// The five slots, leader in the centre as on the game's formation screen.
class Formation extends StatelessWidget {
  const Formation({
    super.key,
    required this.controller,
    required this.hit,
    required this.settings,
  });
  final TeamBuilderController controller;
  final EngineHit hit;
  final BuildSettings settings;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final catalog = c.catalog!;
    final theme = Theme.of(context);
    final order = [1, 2, 0, 3, 4].where((i) => i < hit.members.length);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final index in order)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: () {
                final member = cardIdOf(hit.members[index]);
                final snapKey = hit.snaps.elementAtOrNull(index);
                final owned = c.view?.members[member];
                return Tooltip(
                  message:
                      '${catalog.cardSubtitle(true, member)} · ${c.tb('slotPower', 'Slot power')} '
                      '${formatNumber(c.state.text.locale, hit.slotPowers.elementAtOrNull(index) ?? 0)}',
                  child: Column(
                    children: [
                      CardArt(
                        catalog: catalog,
                        members: true,
                        id: member,
                        growth: _resultGrowth(c, hit.members[index], true),
                        outline: index == 0 ? theme.colorScheme.primary : null,
                      ),
                      const SizedBox(height: 4),
                      if (snapKey != null)
                        CardArt(
                          catalog: catalog,
                          members: false,
                          id: cardIdOf(snapKey),
                          growth: _resultGrowth(c, snapKey, false),
                        )
                      else
                        AspectRatio(
                          aspectRatio: 16 / 9,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(Corner.small),
                            ),
                            child: Icon(
                              Symbols.hide_image_rounded,
                              size: 18,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      if (owned == null && settings.theoretical)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            c.tb('notOwned', 'Not owned'),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              }(),
            ),
          ),
      ],
    );
  }
}

class _Distribution extends StatelessWidget {
  const _Distribution({required this.controller, required this.hit});
  final TeamBuilderController controller;
  final EngineHit hit;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final score = hit.score!;
    final locale = c.state.text.locale;
    final theme = Theme.of(context);
    final master = c.catalog!.master;
    final thresholds = hit.song == null
        ? const []
        : master.scoreRanks[master.songs[hit.song!.songId]?.rankGroup] ??
              const [];
    var low = score.min, high = score.max;
    for (final row in thresholds) {
      if (row.required >= score.min * 0.9 && row.required <= score.max * 1.05) {
        low = math.min(low, row.required.toDouble());
      }
      if (row.required <= score.max * 1.1 && row.required >= score.min) {
        high = math.max(high, row.required.toDouble());
      }
    }
    final span = math.max(1.0, high - low);
    double at(num value) => (value - low) / span;
    final ranks = score.ranks.entries.toList()..sort((a, b) => b.key - a.key);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 36,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return Stack(
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 14,
                    height: 8,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  Positioned(
                    left: width * at(score.min),
                    width: math.max(2, width * (at(score.max) - at(score.min))),
                    top: 14,
                    height: 8,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  for (final (value, color) in [
                    (score.median, theme.colorScheme.tertiary),
                    (score.mean, theme.colorScheme.onSurface),
                  ])
                    Positioned(
                      left: width * at(value) - 1,
                      top: 10,
                      width: 2,
                      height: 16,
                      child: ColoredBox(color: color),
                    ),
                  for (final row in thresholds)
                    if (row.required > low && row.required < high)
                      Positioned(
                        left: width * at(row.required) - 10,
                        top: 0,
                        width: 20,
                        child: Column(
                          children: [
                            Text(
                              rankNames[row.rank] ?? '',
                              style: theme.textTheme.labelSmall,
                            ),
                            Container(
                              width: 1,
                              height: 20,
                              color: theme.colorScheme.outline,
                            ),
                          ],
                        ),
                      ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        DefaultTextStyle.merge(
          style: theme.textTheme.labelMedium?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(formatNumber(locale, score.min)),
              Text(
                '${c.tb('median', 'median')} ${formatNumber(locale, score.median)}',
              ),
              Text(formatNumber(locale, score.max)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final rank in ranks)
              ValueChip(
                label: rankNames[rank.key] ?? '${rank.key}',
                value:
                    '${formatNumber(locale, rank.value / 120 * 100, rank.value == 120 ? 0 : 1)}%',
              ),
          ],
        ),
      ],
    );
  }
}

/// The skill-order editor: pick two positions to swap, the order's timeline,
/// the best order by first skill and the top orders.
class _SkillOrders extends StatefulWidget {
  const _SkillOrders({required this.controller, required this.hit});
  final TeamBuilderController controller;
  final EngineHit hit;

  @override
  State<_SkillOrders> createState() => _SkillOrdersState();
}

class _SkillOrdersState extends State<_SkillOrders> {
  int? _current;
  int? _picked;
  bool _top = false;
  final _timelines = <int, Future<Timeline>>{};
  List<int>? _firing;

  TeamBuilderController get c => widget.controller;
  EngineHit get hit => widget.hit;

  Future<Timeline> _timeline(int index) => _timelines[index] ??= () {
    final request = c.request();
    final engine = c.engine;
    if (request == null || engine == null) {
      return Future<Timeline>.error(StateError('no-request'));
    }
    return engine.timeline(
      TimelineRequest(
        members: request.members,
        snaps: request.snaps,
        unknownPolicy: request.unknownPolicy,
        memberKeys: hit.members,
        snapKeys: hit.snaps,
        song: hit.song!,
        order: orders[index],
        play: c.play,
      ),
    );
  }();

  ({int character, String name, String face, String card, Color color}) _face(
    int slot,
  ) {
    final catalog = c.catalog!;
    final card = cardIdOf(hit.members[slot]);
    final character = catalog.characterIds(true, card).firstOrNull ?? 0;
    return (
      character: character,
      name: catalog.characterName(character),
      face: catalog.cardImage(true, card),
      card: catalog.cardImage(true, card),
      color: catalog.characterColor(
        character,
        Theme.of(context).colorScheme.primary,
      ),
    );
  }

  Widget _faces(int index, List<int> firing) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final (position, event) in firing.indexed)
        Align(
          widthFactor: position + 1 < firing.length ? 19 / 24 : 1,
          alignment: Alignment.centerLeft,
          child: Tooltip(
            message: _face(orders[index][event]).name,
            child: ClipOval(
              child: SizedBox.square(
                dimension: 24,
                child: AppImage(
                  candidates: [_face(orders[index][event]).face],
                  fit: BoxFit.cover,
                  alignment: const Alignment(0, -0.5),
                ),
              ),
            ),
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locale = c.state.text.locale;
    final score = hit.score!;
    final ranked =
        [
          for (final (index, value) in score.orders.indexed)
            (value: value, index: index),
        ]..sort(
          (a, b) => b.value != a.value ? b.value - a.value : a.index - b.index,
        );
    final best = ranked.first;
    final current = _current ?? best.index;
    final firing = _firing ?? const [0, 1, 2, 3, 4];
    final value = score.orders[current];
    final rank = score.orders.where((other) => other > value).length + 1;
    String gap(int other) => other == best.value
        ? '±0'
        : '−${formatNumber(locale, best.value - other)}';
    void choose(int index) => setState(() {
      _current = index;
      _picked = null;
    });
    void pick(int position) {
      if (_picked == null) {
        setState(() => _picked = position);
      } else if (_picked == position) {
        setState(() => _picked = null);
      } else {
        final order = [...orders[current]];
        final a = firing[_picked!], b = firing[position];
        final swap = order[a];
        order[a] = order[b];
        order[b] = swap;
        choose(orders.indexWhere((o) => o.join(',') == order.join(',')));
      }
    }

    final first = firing.first;
    final byFirst = [
      for (var slot = 0; slot < hit.members.length; slot++)
        ranked.firstWhere((entry) => orders[entry.index][first] == slot),
    ]..sort((a, b) => b.value - a.value);
    int rankOf(int other) => score.orders.where((e) => e > other).length + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                c.tb('skillOrder', 'Skill order'),
                style: theme.textTheme.titleSmall,
              ),
            ),
            TextButton(
              onPressed: current == best.index
                  ? null
                  : () => choose(best.index),
              child: Text(c.tb('bestOrder', 'Best order')),
            ),
            TextButton(
              onPressed: current == ranked.last.index
                  ? null
                  : () => choose(ranked.last.index),
              child: Text(c.tb('worstOrder', 'Worst order')),
            ),
          ],
        ),
        Row(
          children: [
            for (final (position, event) in firing.indexed)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: () {
                    final member = _face(orders[current][event]);
                    final selected = _picked == position;
                    return Material(
                      color: selected
                          ? theme.colorScheme.secondaryContainer
                          : theme.colorScheme.surfaceContainerHigh,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Corner.small),
                        side: BorderSide(color: member.color, width: 2),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => pick(position),
                        child: Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Text(
                                '${position + 1}',
                                style: theme.textTheme.labelMedium,
                              ),
                            ),
                            AspectRatio(
                              aspectRatio: 3 / 4,
                              child: AppImage(
                                candidates: [member.card],
                                fit: BoxFit.cover,
                              ),
                            ),
                            if (_picked != null && !selected)
                              const Icon(Symbols.swap_horiz_rounded, size: 18),
                          ],
                        ),
                      ),
                    );
                  }(),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ValueChip(
              label: c.tb('score', 'Score'),
              value: formatNumber(locale, value),
            ),
            ValueChip(
              label: c.tb('orderRank', 'Rank'),
              value: '$rank / ${score.orders.length}',
            ),
            ValueChip(label: c.tb('orderGap', 'From best'), value: gap(value)),
          ],
        ),
        const SizedBox(height: 12),
        FutureBuilder<Timeline>(
          future: _timeline(current),
          builder: (context, snapshot) {
            final timeline = snapshot.data;
            if (timeline != null && _firing == null) {
              final windows = [...timeline.windows]
                ..sort(
                  (a, b) => a.startMs != b.startMs
                      ? a.startMs - b.startMs
                      : a.event - b.event,
                );
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => setState(
                  () => _firing = [for (final w in windows) w.event],
                ),
              );
            }
            if (snapshot.hasError) {
              return Text(
                c.tb('timelineFailed', 'The timeline could not be drawn.'),
              );
            }
            return SizedBox(
              height: 112,
              child: timeline == null
                  ? const Center(child: LinearProgressIndicator())
                  : _TimelinePlot(
                      timeline: timeline,
                      colorOf: (key) => _face(hit.members.indexOf(key)).color,
                      faceOf: (key) => _face(hit.members.indexOf(key)).face,
                    ),
            );
          },
        ),
        const SizedBox(height: 12),
        Text(
          c.tb('firstSkill', 'Best order by first skill'),
          style: theme.textTheme.titleSmall,
        ),
        for (final entry in byFirst)
          ListTile(
            contentPadding: EdgeInsets.zero,
            onTap: () => choose(entry.index),
            selected: entry.index == current,
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(Corner.small),
              child: SizedBox(
                width: 36,
                height: 48,
                child: AppImage(
                  candidates: [_face(orders[entry.index][first]).card],
                  fit: BoxFit.cover,
                ),
              ),
            ),
            title: Text(_face(orders[entry.index][first]).name),
            subtitle: Text(gap(entry.value)),
            trailing: _faces(entry.index, firing),
          ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(c.tb('topOrders', 'Top orders')),
          trailing: Text('10', style: theme.textTheme.labelLarge),
          initiallyExpanded: _top,
          onExpansionChanged: (open) => _top = open,
          children: [
            for (final entry in ranked.take(10))
              ListTile(
                contentPadding: EdgeInsets.zero,
                onTap: () => choose(entry.index),
                selected: entry.index == current,
                leading: SizedBox(
                  width: 28,
                  child: Center(child: Text('${rankOf(entry.value)}')),
                ),
                title: _faces(entry.index, firing),
                subtitle: Text(
                  '${formatNumber(locale, entry.value)} · ${gap(entry.value)}',
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Note density, fevers and each member's skill window (`skillTimeline`).
class _TimelinePlot extends StatelessWidget {
  const _TimelinePlot({
    required this.timeline,
    required this.colorOf,
    required this.faceOf,
  });
  final Timeline timeline;
  final Color Function(String member) colorOf;
  final String Function(String member) faceOf;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final duration = math.max(1, timeline.durationMs);
        double x(int ms) => ms / duration * width;
        return Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _DensityPainter(
                  timeline,
                  theme.colorScheme.surfaceContainerHighest,
                  theme.colorScheme.tertiaryContainer.withValues(alpha: 0.6),
                ),
              ),
            ),
            for (final (index, window) in timeline.windows.indexed)
              Positioned(
                left: x(window.startMs),
                width: math.max(4, x(window.endMs) - x(window.startMs)),
                top: 8.0 + (index % 3) * 32,
                height: 26,
                child: Tooltip(
                  message:
                      '+${(window.percent + window.perfectPercent).round()}%${window.extensionMs != 0 ? ' · +${(window.extensionMs / 1000).toStringAsFixed(1)}s' : ''}',
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colorOf(window.member).withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: ClipOval(
                          child: SizedBox.square(
                            dimension: 22,
                            child: AppImage(
                              candidates: [faceOf(window.member)],
                              fit: BoxFit.cover,
                              alignment: const Alignment(0, -0.5),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _DensityPainter extends CustomPainter {
  _DensityPainter(this.timeline, this.color, this.fever);
  final Timeline timeline;
  final Color color;
  final Color fever;

  @override
  void paint(Canvas canvas, Size size) {
    final duration = math.max(1, timeline.durationMs);
    for (final (start, end) in timeline.fever) {
      canvas.drawRect(
        Rect.fromLTRB(
          start / duration * size.width,
          0,
          end / duration * size.width,
          size.height,
        ),
        Paint()..color = fever,
      );
    }
    final peak = timeline.density.fold(1, math.max);
    final step = size.width / math.max(1, timeline.density.length);
    final paint = Paint()..color = color;
    for (final (index, count) in timeline.density.indexed) {
      final h = count / peak * size.height;
      canvas.drawRect(
        Rect.fromLTWH(index * step, size.height - h, step, h),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DensityPainter old) => old.timeline != timeline;
}

/// A result as the website's shareable image (`exportImage`).
Future<List<int>> renderHitImage(
  TeamBuilderController c,
  EngineHit hit,
  ({String label, String value}) main,
  ColorScheme scheme,
) {
  final catalog = c.catalog!;
  final locale = c.state.text.locale;
  ResultImageCard card(bool members, String key, bool leader) {
    final id = cardIdOf(key);
    final characters = catalog.characterIds(members, id);
    return ResultImageCard(
      title: catalog.cardName(members, id),
      character: [
        for (final character in characters) catalog.characterName(character),
      ].join(' · '),
      image: catalog.cardImage(members, id),
      avatars: [
        if (members)
          catalog.cardImage(true, id)
        else
          for (final character in characters)
            if (catalog.characterFace(character).isNotEmpty)
              catalog.characterFace(character),
      ],
      attribute: catalog.attributeIcon(catalog.attribute(members, id)),
      rarity: catalog.rarityIcon(catalog.rarity(members, id)),
      attributeLabel: catalog.attributeName(catalog.attribute(members, id)),
      rarityLabel: cardRarityName(catalog.rarity(members, id)),
      leader: leader,
      growth: _resultGrowth(c, key, members),
    );
  }

  return renderTeamResultImage(
    TeamResultImage(
      title: c.tb('title', 'Team builder'),
      subtitle: hit.song == null
          ? main.label
          : '${catalog.songTitle(hit.song!.songId)} · ${catalog.difficultyLabel(hit.song!.songId, hit.song!.difficulty)}',
      membersLabel: c.tb('members', 'Members'),
      snapshotsLabel: c.tb('snapshots', 'Snaps'),
      leaderLabel: c.tb('leader', 'Leader'),
      emptyLabel: c.tb('noSnap', 'No snap'),
      allEmptyLabel: c.tb(
        'allNoSnaps',
        'No Snapshots in any of the five slots',
      ),
      imageUnavailableLabel: c.tb('imageUnavailable', 'Image unavailable'),
      members: [
        for (final (index, key) in hit.members.indexed)
          card(true, key, index == 0),
      ],
      snapshots: [
        for (final key in hit.snaps)
          key == null ? null : card(false, key, false),
      ],
      metrics: [
        (main.label, main.value),
        (c.tb('power', 'Power'), formatNumber(locale, hit.power)),
        if (hit.comboBonus != null)
          (c.tb('comboBonus', 'Base COMBO BONUS'), '×${hit.comboBonus}'),
        if (hit.event?.rewardValues case final values?)
          for (final entry in values.entries)
            (
              rewardLabel(c, entry.key),
              formatNumber(locale, numOf(objectRow(entry.value)['value']), 4),
            ),
        if (hit.event?.rewardPlan == null && hit.event?.otherMean != null)
          (
            c.tb(
              c.settingsForHit(hit).measure == 'items'
                  ? 'pointsPerPlay'
                  : 'itemsPerPlay',
              '',
            ),
            formatNumber(locale, hit.event!.otherMean!, 1),
          ),
        if (hit.score case final score?)
          (
            c.tb('scoreRange', 'Range'),
            '${formatNumber(locale, score.min)} – ${formatNumber(locale, score.max)}',
          ),
      ],
      footer: [
        ...resultConditions(
          c,
          hit,
          c.settingsForHit(hit),
        ).map((row) => '${row.$1}: ${row.$2}'),
        'haneoka.org',
      ],
      theme: ResultImageTheme(
        surface: scheme.surface,
        container: scheme.surfaceContainer,
        text: scheme.onSurface,
        muted: scheme.onSurfaceVariant,
        primary: scheme.primary,
        outline: scheme.outlineVariant,
      ),
    ),
  );
}
