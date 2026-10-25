/// Native reward controls and labels for immutable result plans.
library;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'controller.dart';
import 'engine/num.dart';
import 'pickers.dart';
import 'reward_plan.dart';
import 'widgets.dart';

String rewardLabel(TeamBuilderController c, String metric) => metric == 'points'
    ? 'PT'
    : metric == 'challenge-points'
    ? 'CP'
    : c.tb('rewardPlan.badges', 'Badges');
String rewardRankingLabel(TeamBuilderController c, Doc plan) => [
  for (final (index, level) in (plan['levels'] as List).indexed)
    '${index > 0 ? '${c.tb('rewardPlan.tie', 'Tie-break')} ' : ''}${[for (final raw in level as List) '${rewardLabel(c, '${objectRow(raw)['metric']}')}${index == 0 && objectRow(raw)['weight'] != plan['unit'] ? ' × ${numOf(objectRow(raw)['weight']) / numOf(plan['unit'])}' : ''}'].join(' + ')}',
].join(' › ');

class RewardPlanControls extends StatelessWidget {
  const RewardPlanControls({super.key, required this.controller});
  final TeamBuilderController controller;
  @override
  Widget build(BuildContext context) {
    final c = controller, s = c.searchSettings;
    final plan = s.effectiveRewardPlan;
    String t(String key, String fallback) => c.tb('rewardPlan.$key', fallback);
    void set(RewardPlan value) => c.updateSettings({
      'rewardPlan': value.toJson(),
      'ptCycle': false,
      'weighted': false,
      'measure': value.primary,
    });
    final preview =
        [
          rewardLabel(c, plan.primary),
          for (final metric in rewardMetrics)
            if (metric != plan.primary &&
                plan.options[metric]!['mode'] == 'convert')
              '${rewardLabel(c, metric)} × ${plan.options[metric]!['auto'] == true ? t('auto', 'Automatic') : plan.options[metric]!['rate'] ?? '—'}',
        ].join(' + ') +
        [
          for (final metric in plan.tieOrder)
            if (plan.options[metric]!['mode'] == 'tie')
              ' › ${t('tie', 'Tie-break')} ${rewardLabel(c, metric)}',
        ].join();
    return ToolSection(
      icon: Symbols.emoji_events_rounded,
      title: t('title', 'Reward plan'),
      children: [
        ToolField(
          label: t('primary', 'Main reward'),
          child: Segmented<String>(
            value: plan.primary,
            options: [
              for (final metric in rewardMetrics)
                if (s.route == 'live' || metric != 'challenge-points')
                  Choice(metric, rewardLabel(c, metric)),
            ],
            onSelected: (value) => set(plan.main(value)),
          ),
        ),
        for (final metric in rewardMetrics)
          if (metric != plan.primary &&
              (s.route == 'live' || metric != 'challenge-points')) ...[
            ToolField(
              label: rewardLabel(c, metric),
              child: Segmented<String>(
                value: '${plan.options[metric]!['mode']}',
                options: [
                  Choice('ignore', t('ignore', 'Ignore')),
                  Choice('convert', t('convert', 'Convert')),
                  Choice('tie', t('tie', 'Tie-break')),
                ],
                onSelected: (mode) => set(plan.mode(metric, mode)),
              ),
            ),
            if (plan.options[metric]!['mode'] == 'convert') ...[
              if (metric == 'challenge-points')
                Segmented<String>(
                  value: plan.options[metric]!['auto'] == true
                      ? 'auto'
                      : 'manual',
                  options: [
                    Choice('manual', t('manual', 'Manual')),
                    Choice('auto', t('auto', 'Automatic')),
                  ],
                  onSelected: (value) =>
                      set(plan.option(metric, {'auto': value == 'auto'})),
                ),
              if (plan.options[metric]!['auto'] != true)
                TextFormField(
                  key: ValueKey('reward-rate-${plan.primary}-$metric'),
                  initialValue: '${plan.options[metric]!['rate'] ?? ''}',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText:
                        '${rewardLabel(c, plan.primary)} / ${rewardLabel(c, metric)}',
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (value) => set(
                    plan.option(metric, {'rate': double.tryParse(value)}),
                  ),
                ),
            ],
            if (plan.options[metric]!['mode'] == 'tie' &&
                plan.tieOrder.indexOf(metric) > 0)
              OutlinedButton(
                onPressed: () => set(plan.first(metric)),
                child: Text(t('first', 'Compare this first')),
              ),
          ],
        Text('${t('order', 'Ranking')}: $preview'),
        if (plan.autoCp) ...[
          FilledButton.tonalIcon(
            icon: const Icon(Symbols.swords_rounded),
            label: Text(
              '${c.tb('planChallengeSongs', 'Challenge songs')} · ${s.planChallengeSongs.length}',
            ),
            onPressed: () async {
              final picked = await pickSongs(
                context,
                c.catalog!,
                s.planChallengeSongs,
                allowed: [
                  for (final row in c.catalog!.challengeSongs(s.eventId))
                    row.liveMusicId,
                ],
              );
              if (picked != null) {
                c.updateSettings({
                  'planChallengeSongs': [
                    for (final song in picked) song.toJson(),
                  ],
                });
              }
            },
          ),
          DropdownMenu<int>(
            expandedInsets: EdgeInsets.zero,
            label: Text(c.tb('pt.challengeCost', 'CP per challenge')),
            initialSelection: s.challengePoints,
            onSelected: (value) {
              if (value != null) c.updateSettings({'challengePoints': value});
            },
            dropdownMenuEntries: [
              for (final row in c.catalog!.master.challengeBoosts)
                if (row.consumed > 0)
                  DropdownMenuEntry(
                    value: row.consumed,
                    label: '${row.consumed} CP',
                  ),
            ],
          ),
        ],
        if (s.ptGekiso && s.rewardPlan != null) ...[
          TextFormField(
            key: const ValueKey('reward-just'),
            initialValue: '${s.ptJust}',
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: c.tb('pt.baselineJust', 'Baseline JUST (%)'),
            ),
            onChanged: (value) {
              final parsed = int.tryParse(value);
              if (parsed != null) c.updateSettings({'ptJust': parsed});
            },
          ),
          TextFormField(
            key: const ValueKey('reward-samples'),
            initialValue: '${s.ptLuckSamples}',
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: c.tb('pt.luckSamples', 'Luck samples'),
            ),
            onChanged: (value) {
              final parsed = int.tryParse(value);
              if (parsed != null) c.updateSettings({'ptLuckSamples': parsed});
            },
          ),
          TextFormField(
            key: const ValueKey('reward-combo'),
            initialValue: '${s.minComboBonus}',
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: c.tb('minComboBonus', 'Minimum COMBO BONUS'),
            ),
            onChanged: (value) {
              final parsed = int.tryParse(value);
              if (parsed != null) c.updateSettings({'minComboBonus': parsed});
            },
          ),
        ],
      ],
    );
  }
}
