/// Event rewards: the best team of every chosen song for event points and
/// shop medals, counting the challenge lives its challenge points pay for
/// (`lit/team-builder/pt-tab.ts`).
library;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'box_tab.dart' show showCardEditor;
import 'build_tab.dart' show BuildTab, ManualEventControls;
import 'controller.dart';
import 'engine/api.dart';
import 'engine/num.dart';
import 'engine/pt_eligibility.dart';
import 'pickers.dart';
import 'pt_controller.dart';
import 'pt_recommendation.dart';
import 'results_view.dart' show Formation, openResultSongAnalysis;
import 'settings.dart';
import 'reward_plan_view.dart';
import 'widgets.dart';

class PtTab extends StatefulWidget {
  const PtTab({super.key, required this.controller, required this.openTab});
  final TeamBuilderController controller;

  /// Opens `box` or `account` for an unmet input.
  final ValueChanged<String> openTab;

  @override
  State<PtTab> createState() => _PtTabState();
}

class _PtTabState extends State<PtTab> {
  TeamBuilderController get controller => widget.controller;
  void Function(String) get openTab => widget.openTab;
  Object? _setupStamp;
  List<Widget> _setupCache = const [];
  List<Widget> _cachedSetup(BuildContext context) {
    final stamp = (
      c.settings,
      c.catalog,
      c.view,
      pt.measure,
      pt.showIssues,
      pt.issues,
      Theme.of(context),
      c.state.text,
      MediaQuery.textScalerOf(context),
    );
    if (stamp != _setupStamp) {
      _setupStamp = stamp;
      _setupCache = _setup(context);
    }
    return _setupCache;
  }

  TeamBuilderController get c => controller;
  PtController get pt => controller.pt;
  String t(String key, String fallback, [Map<String, Object?> v = const {}]) =>
      c.tb('pt.$key', fallback, v);

  @override
  Widget build(BuildContext context) {
    final farm = c.settings.farming;
    final mode = c.settings.rewardMode == 'plan' ? 'plan' : 'farm';
    final modes = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Segmented<String>(
          value: mode,
          grow: false,
          options: [
            Choice('farm', c.tb('farm.title', 'Farming recommendations')),
            Choice('plan', c.tb('farm.plan', 'Resource planning')),
          ],
          onSelected: (value) {
            c.cancel();
            pt.showIssues = false;
            c.updateSettings({
              'rewardMode': value == 'plan' ? 'plan' : c.settings.farmingMode,
            });
          },
        ),
        if (mode == 'farm') ...[
          const SizedBox(height: 16),
          ToolSection(
            title: c.tb('farm.conditions', 'Play and account conditions'),
            children: [
              DropdownButtonFormField<String>(
                key: ValueKey(farm['play']),
                initialValue: farm['play'] as String,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: c.tb('farm.task', 'Event task'),
                ),
                items: [
                  for (final (value, label) in [
                    ('solo', t('solo', 'Solo')),
                    ('gekiso', t('gekiso', 'Gekiso')),
                    ('challenge', c.tb('routeChallenge', 'Challenge live')),
                    ('skip', c.tb('routeSkip', 'Skip')),
                  ])
                    DropdownMenuItem(value: value, child: Text(label)),
                ],
                onChanged: (value) => c.updateSettings({
                  'farming': {...farm, 'play': value},
                }),
              ),
              if (farm['play'] != 'gekiso')
                ExpansionTile(
                  title: Text(c.tb('farm.advanced', 'Advanced conditions')),
                  tilePadding: EdgeInsets.zero,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        c.tb(
                          'farm.requireGrowth',
                          'Complete before calculating',
                        ),
                      ),
                      value: farm['requireGrowth'] == true,
                      onChanged: (value) => c.updateSettings({
                        'farming': {...farm, 'requireGrowth': value},
                      }),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        c.tb('farm.memory', 'Character / song memory bonuses'),
                      ),
                      value: farm['includeMemory'] == true,
                      onChanged: (value) => c.updateSettings({
                        'farming': {...farm, 'includeMemory': value},
                      }),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 16),
          RewardPlanControls(controller: c),
        ],
      ],
    );
    if (c.settings.rewardMode != 'recommendation') {
      return BuildTab(controller: c, leading: modes);
    }
    pt.measure = c.searchSettings.measure == 'items' ? 'items' : 'points';
    pt.sync();
    return TeamToolLayout(
      controller: c,
      storageKey: 'reward',
      summary:
          '${c.tb('farm.title', 'Farming recommendations')} · ${c.searchSettings.songs.length}',
      conditions: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          modes,
          const SizedBox(height: 16),
          ..._cachedSetup(context),
          if (pt.showIssues && pt.issues.isNotEmpty) ...[
            const SizedBox(height: 16),
            _issues(context),
          ],
        ],
      ),
      action: _run,
      results: _ranking,
    );
  }

  List<Widget> _setup(BuildContext context) {
    final s = c.searchSettings;
    final catalog = c.catalog!;
    final master = catalog.master;
    final request = pt.request();
    final events = catalog.events();
    bool invalid(String field) =>
        pt.showIssues && pt.issues.any((issue) => issueField(issue) == field);
    Widget field(String key, Widget child) => invalid(key)
        ? DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.error,
                width: 2,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(padding: const EdgeInsets.all(4), child: child),
          )
        : child;
    Widget songButton(
      String label,
      IconData icon,
      int count,
      VoidCallback? onPressed,
    ) => FilledButton.tonal(
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
      onPressed: onPressed,
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
          Text(
            '$count',
            style: const TextStyle(
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
    final boosts = {for (final row in master.boosts) row.consumed};
    final challengeCosts = [
      for (final row in master.challengeBoosts)
        if (row.consumed > 0 && row.eventPointRate > 0 && row.rewardRate > 0)
          row.consumed,
    ];
    return [
      ToolSection(
        icon: Symbols.emoji_events_rounded,
        title: c.tb('eventSetup', 'Event'),
        children: [
          if (s.ptGekiso && c.hasMission(1, s.songs))
            TextFormField(
              key: const ValueKey('pt-combo'),
              initialValue: s.minComboBonus == 1 ? '' : '${s.minComboBonus}',
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: c.tb('minComboBonus', 'Minimum base COMBO BONUS'),
                prefixText: '×',
                hintText: c.tb('unlimitedCombo', 'No minimum'),
              ),
              onChanged: (value) =>
                  c.updateSettings({'minComboBonus': int.tryParse(value) ?? 1}),
            ),
          field(
            'event',
            DropdownMenu<int>(
              key: ValueKey('pt-event-${s.eventId}'),
              expandedInsets: EdgeInsets.zero,
              label: Text(c.tb('event', 'Event')),
              initialSelection: s.eventId,
              menuHeight: 360,
              onSelected: (value) {
                if (value == null) return;
                c.updateSettings({
                  'eventId': value,
                  'planChallengeSongs': <Object?>[],
                });
              },
              dropdownMenuEntries: [
                for (final event in events)
                  DropdownMenuEntry(value: event.id, label: event.name),
              ],
            ),
          ),
          ManualEventControls(
            controller: c,
            value: s.manualEvent,
            onChanged: (value) => c.updateSettings({'manualEvent': value}),
          ),
          field(
            'consumption',
            DropdownMenu<int>(
              expandedInsets: EdgeInsets.zero,
              label: Text(c.tb('boosts', 'Boosts per live')),
              initialSelection: s.boosts,
              onSelected: (value) {
                if (value != null) c.updateSettings({'boosts': value});
              },
              dropdownMenuEntries: [
                for (final cost in liveBoostCosts)
                  DropdownMenuEntry(
                    value: cost,
                    label: '$cost',
                    enabled: cost == 0 || boosts.contains(cost),
                  ),
              ],
            ),
          ),
          if (s.ptGekiso) ...[
            field(
              'gekiso-input',
              _IntField(
                label: t('baselineJust', 'Baseline JUST (%)'),
                value: s.ptJust,
                onChanged: (value) => c.updateSettings({'ptJust': value}),
              ),
            ),
            _IntField(
              label: t('luckSamples', 'Luck samples'),
              value: s.ptLuckSamples,
              onChanged: (value) => c.updateSettings({'ptLuckSamples': value}),
            ),
          ],
        ],
      ),
      const SizedBox(height: 16),
      ToolSection(
        icon: Symbols.library_music_rounded,
        title: c.tb('songs', 'Songs'),
        children: [
          ...[
            field(
              'selection',
              songButton(
                c.tb('chooseSongs', 'Choose songs'),
                Symbols.library_music_rounded,
                s.songs.length,
                () async {
                  final picked = await pickSongs(
                    context,
                    catalog,
                    s.songs,
                    allowed: catalog.normalEventSongIds(s.eventId),
                  );
                  if (picked != null) {
                    c.updateSettings({
                      'songs': [for (final song in picked) song.toJson()],
                    });
                  }
                },
              ),
            ),
            if (s.ptCycle)
              field(
                'challenge-selection',
                songButton(
                  t('chooseChallenge', 'Challenge songs'),
                  Symbols.swords_rounded,
                  s.planChallengeSongs.length,
                  s.eventId == null
                      ? null
                      : () async {
                          final picked = await pickSongs(
                            context,
                            catalog,
                            s.planChallengeSongs,
                            allowed: [
                              for (final row in master.challengeMusics)
                                if (row.eventId == s.eventId) row.liveMusicId,
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
              ),
          ],
          if (s.ptCycle)
            field(
              'challenge-consumption',
              DropdownMenu<int>(
                expandedInsets: EdgeInsets.zero,
                label: Text(t('challengeCost', 'CP per challenge')),
                initialSelection: challengeCosts.contains(s.challengePoints)
                    ? s.challengePoints
                    : null,
                onSelected: (value) {
                  if (value != null) {
                    c.updateSettings({'challengePoints': value});
                  }
                },
                dropdownMenuEntries: [
                  for (final cost in challengeCosts)
                    DropdownMenuEntry(value: cost, label: '$cost CP'),
                ],
              ),
            ),
        ],
      ),
      const SizedBox(height: 16),
      Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          leading: const Icon(Symbols.tune_rounded),
          title: Text(t('constraints', 'Leader and snapshots')),
          subtitle: Text(
            c.tb('candidateSummary', '{members} members · {snaps} snaps', {
              'members': request?.members.length ?? 0,
              'snaps': request?.snaps.length ?? 0,
            }),
          ),
          initiallyExpanded: invalid('constraints') || invalid('minBonus'),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            field(
              'constraints',
              DropdownMenu<int>(
                expandedInsets: EdgeInsets.zero,
                label: Text(c.tb('leader', 'Leader')),
                initialSelection: s.leader ?? 0,
                enableFilter: true,
                requestFocusOnTap: true,
                menuHeight: 360,
                onSelected: (value) => c.updateSettings({
                  'leader': value == null || value == 0 ? null : value,
                }),
                dropdownMenuEntries: [
                  DropdownMenuEntry(
                    value: 0,
                    label: c.tb('leaderAuto', 'Best leader (automatic)'),
                  ),
                  for (final m in request?.members ?? const [])
                    DropdownMenuEntry(
                      value: m.cardId,
                      label: catalog.cardName(true, m.cardId),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            field(
              'minBonus',
              TextFormField(
                key: ValueKey('pt-min-bonus-${s.minBonus}'),
                initialValue: s.minBonus == null
                    ? ''
                    : '${s.minBonus!.round()}',
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: c.tb('minBonus', 'Minimum event bonus (%)'),
                  border: const OutlineInputBorder(),
                ),
                onFieldSubmitted: (raw) => c.updateSettings({
                  'minBonus': raw.trim().isEmpty ? null : double.tryParse(raw),
                }),
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: s.noSnaps,
              onChanged: (value) =>
                  c.updateSettings({'noSnaps': value == true}),
              title: Text(c.tb('noSnaps', 'No snapshots')),
            ),
            for (final (index, (member, snap)) in s.bindings.indexed)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  '${catalog.cardName(true, member)} → '
                  '${snap == null ? c.tb('noSnap', 'No snap') : catalog.cardName(false, snap)}',
                ),
                trailing: IconButton(
                  tooltip: t('removeBinding', 'Remove binding'),
                  onPressed: () => c.updateSettings({
                    'bindings': [
                      for (final (i, (m, p)) in s.bindings.indexed)
                        if (i != index) [m, p],
                    ],
                  }),
                  icon: const Icon(Symbols.close_rounded),
                ),
              ),
          ],
        ),
      ),
    ];
  }

  String _inputLabel(String target) {
    final catalog = c.catalog!;
    final titles = {
      'p.vip': c.tb('vipRank', 'T.G.W card rank'),
      'five-characters': t(
        'fiveCharacters',
        'At least five different characters',
      ),
      'selection': c.tb('chooseSongs', 'Choose songs'),
      'challenge-selection': t('chooseChallenge', 'Challenge songs'),
      'tables': t('eventTables', 'Event consumption tables'),
      'consumption': c.tb('boosts', 'Boosts per live'),
      'challenge-consumption': t('challengeCost', 'CP per challenge'),
      'gekiso-input': t('gekiso', 'Gekisou'),
      'minBonus': c.tb('minBonus', 'Minimum event bonus (%)'),
      'member': c.tb('members', 'Members'),
      'snap': c.tb('snapshots', 'Snapshots'),
      'required-members': t(
        'requiredMembers',
        'Required members share a character',
      ),
      'photo-bindings': t('photoBindings', 'A snapshot is bound twice'),
    };
    if (titles[target] case final title?) return title;
    final parts = target.split('.');
    final key = parts.first;
    final fieldName = parts.elementAtOrNull(1) ?? '';
    final fields = {
      'level': c.tb('level', 'Level'),
      'awake': c.tb('training', 'Training'),
      'rank': c.tb('awakening', 'Awakening'),
      'liveSkillLevel': c.tb('liveSkill', 'Live skill'),
      'gekisoSkillLevel': c.tb('gekisoSkill', 'Gekisou skill'),
      'cr': c.tb('characterRanks', 'Character ranks'),
      'bi': c.tb('bandItems', 'Band items'),
    };
    if (RegExp(r'^([ms])(\d+)(?:[.:/]|$)').firstMatch(target)
        case final card?) {
      final name = catalog.cardName(card[1] == 'm', int.parse(card[2]!));
      return fields[fieldName] == null ? name : '$name · ${fields[fieldName]}';
    }
    if (RegExp(r'^(?:challenge:|gekiso:)?(\d+):(\d+)$').firstMatch(target)
        case final song?) {
      final id = int.parse(song[1]!);
      return '${catalog.songTitle(id)} · ${catalog.difficultyLabel(id, int.parse(song[2]!))}';
    }
    if (key == 'cr') {
      return '${catalog.characterName(int.tryParse(fieldName) ?? 0)} · ${fields[key]}';
    }
    if (key == 'bi') {
      final name = catalog.text(
        objectRow(objectRow(catalog.data['bandItems'])[fieldName])['name'],
      );
      return '${name.isEmpty ? '#$fieldName' : name} · ${fields[key]}';
    }
    return target;
  }

  void _edit(BuildContext context, PtIssue issue) {
    final field = issueField(issue);
    if (field == null) return;
    if (RegExp(r'^(m|s)(\d+)\.').firstMatch(field) case final card?) {
      showCardEditor(
        context,
        c,
        members: card[1] == 'm',
        id: int.parse(card[2]!),
      );
    } else if (RegExp(r'^(cr|bi|p)\.').hasMatch(field)) {
      openTab('account');
    } else if (field == 'inventory') {
      openTab('box');
    }
  }

  Widget _issues(BuildContext context) => ToolSection(
    icon: Symbols.error_rounded,
    title: t('needsInput', 'Inputs to complete'),
    count: '${pt.issues.length}',
    children: [
      for (final issue in pt.issues)
        Row(
          children: [
            Expanded(child: Text(_inputLabel(issue.target))),
            if (issueField(issue) != null)
              TextButton.icon(
                onPressed: () => _edit(context, issue),
                iconAlignment: IconAlignment.end,
                icon: const Icon(Symbols.arrow_forward_rounded, size: 18),
                label: Text(t('fixInput', 'Edit')),
              ),
          ],
        ),
    ],
  );

  Widget _run(BuildContext context) {
    final job = pt.job;
    final blocked = c.running || c.manualBusy || pt.dataFingerprint.isEmpty;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    );
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pt.running)
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              shape: shape,
            ),
            onPressed: pt.stop,
            icon: const Icon(Symbols.stop_rounded),
            label: Text(t('stop', 'Stop')),
          )
        else
          FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              shape: shape,
              textStyle: theme.textTheme.titleMedium,
            ),
            onPressed: blocked ? null : pt.start,
            icon: const Icon(Symbols.search_rounded),
            label: Text(t('start', 'Calculate')),
          ),
        if (!pt.running && job != null && !ptComplete(job) && !pt.stale) ...[
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              shape: shape,
            ),
            onPressed: blocked ? null : () => pt.start(resume: true),
            icon: const Icon(Symbols.play_arrow_rounded),
            label: Text(
              c.tb('continueOptimal', 'Continue verifying optimality'),
            ),
          ),
        ],
        if (pt.storageError)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              t('storageError', "Progress can't be saved on this device."),
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (pt.error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              t('runError', 'Calculation failed.'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }

  Widget _ranking(BuildContext context) {
    final job = pt.job;
    final theme = Theme.of(context);
    if (job == null) {
      return ToolSection(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Column(
              children: [
                Icon(
                  Symbols.emoji_events_rounded,
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
    c.syncPtCompared(job);
    final catalog = c.catalog!;
    final locale = c.state.text.locale;
    final ranking = ptSongRanking(job, pt.measure);
    final challenge = ptChallengeBest(job, pt.measure);
    final shown = pt.showAll
        ? ranking
        : ranking.take(job.scope == 'top-one' ? 1 : 5).toList();
    final currency = pt.measure == 'points'
        ? t('points', 'Event PT')
        : t('items', 'Shop medals');
    String number(num n) {
      final text = formatNumber(locale, n, 1);
      return n == n.roundToDouble() ? formatNumber(locale, n) : text;
    }

    final settled = job.tasks
        .where((task) => task.status != 'queued' && task.status != 'running')
        .length;
    final pruned = job.tasks.where((task) => task.status == 'pruned').length;
    Widget card(
      EngineHit hit,
      Widget leading,
      String subtitle,
      String value, {
      bool best = false,
      String? breakdown,
    }) => Material(
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
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
            Row(
              children: [
                leading,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        catalog.songTitle(hit.song!.songId),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  value,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            if (breakdown != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(breakdown, style: theme.textTheme.bodySmall),
              ),
            const SizedBox(height: 12),
            Formation(
              controller: c,
              hit: hit,
              settings: c.ptCompareEntry(hit, job, 0)?.settings ?? c.settings,
            ),
            if (hit.comboBonus != null || hit.event?.otherMean != null)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (hit.comboBonus != null)
                    ValueChip(
                      label: c.tb('comboBonus', 'Base COMBO BONUS'),
                      value: '×${hit.comboBonus}',
                    ),
                  if (hit.event?.otherMean case final other?)
                    ValueChip(
                      label: c.tb(
                        pt.measure == 'items'
                            ? 'pointsPerPlay'
                            : 'itemsPerPlay',
                        '',
                      ),
                      value: formatNumber(locale, other, 1),
                    ),
                ],
              ),
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                isSelected: c.ptCompared.any(
                  (row) => row.id == c.ptCompareEntry(hit, job, 0)?.id,
                ),
                tooltip: c.tb('addComparison', 'Add to comparison'),
                icon: const Icon(Symbols.compare_arrows_rounded),
                onPressed: () =>
                    c.togglePtCompared(hit, job, ranking.indexOf(hit) + 1),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: c.tb(
                  'songMetaWithTeam',
                  'Song analysis with this team',
                ),
                icon: const Icon(Symbols.query_stats_rounded),
                onPressed: () => openResultSongAnalysis(
                  context,
                  c,
                  hit,
                  c.searchSettings.forGoal(GoalKind.event).copyWith({
                    'measure': pt.measure,
                  }),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    Widget badge(Widget child, bool best) => CircleAvatar(
      radius: 16,
      backgroundColor: best
          ? theme.colorScheme.primary
          : theme.colorScheme.surfaceContainerHighest,
      foregroundColor: best
          ? theme.colorScheme.onPrimary
          : theme.colorScheme.onSurfaceVariant,
      child: child,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: 'points',
                  label: Text(t('points', 'Event PT')),
                ),
                ButtonSegment(
                  value: 'items',
                  label: Text(t('items', 'Shop medals')),
                ),
              ],
              selected: {pt.measure},
              onSelectionChanged: (value) {
                pt
                  ..measure = value.single
                  ..showAll = false;
                c.updateSettings({'measure': value.single});
                c.changed();
              },
            ),
            Text(
              '$settled/${job.tasks.length}',
              style: theme.textTheme.labelLarge,
            ),
            if (pt.stale) Chip(label: Text(t('stale', 'Inputs changed'))),
          ],
        ),
        if (pt.running) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: job.tasks.isEmpty ? 0 : settled / job.tasks.length,
          ),
        ],
        if (challenge != null) ...[
          const SizedBox(height: 12),
          card(
            challenge,
            badge(const Icon(Symbols.swords_rounded, size: 18), false),
            '${catalog.difficultyLabel(challenge.song!.songId, challenge.song!.difficulty)} · '
            '${t('challengeBest', 'Challenge team')}',
            number(challenge.event!.mean),
          ),
        ],
        for (final (position, hit) in shown.indexed) ...[
          const SizedBox(height: 12),
          card(
            hit,
            badge(Text('${position + 1}'), position == 0),
            '${catalog.difficultyLabel(hit.song!.songId, hit.song!.difficulty)} · '
                '${c.tb('eventBonus', 'Event bonus')} +${number(hit.event!.bonusPercent.floor())}%',
            '${number(hit.event!.mean)} $currency',
            best: position == 0,
            breakdown: job.cycle == null
                ? null
                : t('breakdown', 'Live {direct} + CP {converted}', {
                    'direct': number(hit.event!.directMean ?? 0),
                    'converted': number(hit.event!.convertedMean ?? 0),
                  }),
          ),
        ],
        if (ranking.length > (job.scope == 'top-one' ? 1 : 5))
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () {
                pt.showAll = !pt.showAll;
                c.changed();
              },
              child: Text(
                pt.showAll
                    ? (job.scope == 'top-one'
                          ? t('topOne', 'Top song')
                          : t('topFive', 'Top five'))
                    : t('showAll', 'All {count} songs', {
                        'count': ranking.length,
                      }),
              ),
            ),
          ),
        if (pruned > 0 && !ptAllComplete(job) && !pt.running) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              onPressed: c.running || pt.stale || pt.issues.isNotEmpty
                  ? null
                  : () => pt.start(resume: true, topFive: false),
              child: Text(t('calculateAll', 'Calculate every song')),
            ),
          ),
        ],
      ],
    );
  }
}

class _IntField extends StatelessWidget {
  const _IntField({
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => TextFormField(
    key: ValueKey('$label-$value'),
    initialValue: '$value',
    keyboardType: TextInputType.number,
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
    ),
    onFieldSubmitted: (raw) => onChanged(int.tryParse(raw.trim()) ?? value),
    onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
  );
}
