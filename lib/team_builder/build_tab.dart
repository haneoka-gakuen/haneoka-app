/// Team search: goal, songs, play, candidates and constraints, with results
/// beside them (`lit/team-builder/build-tab.ts`).
library;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../catalog/catalog_screen.dart' show cardRarityName;
import '../ui/app_image.dart';
import 'controller.dart';
import 'manual_event_view.dart';
import 'engine/api.dart';
import 'pickers.dart';
import 'results_view.dart';
import 'settings.dart';
import 'widgets.dart';

const _goals = [
  (GoalKind.score, Symbols.music_note_rounded),
  (GoalKind.gekiso, Symbols.local_fire_department_rounded),
  (GoalKind.power, Symbols.bolt_rounded),
  (GoalKind.potential, Symbols.auto_awesome_rounded),
];

String goalText(TeamBuilderController c, GoalKind goal) => switch (goal) {
  GoalKind.score => c.tb('goalScore', 'Live score'),
  GoalKind.gekiso => c.tb('goalGekiso', 'Gekiso score'),
  GoalKind.event => c.tb('goalEvent', 'Event rewards'),
  GoalKind.plan => c.tb('goalPlan', 'Event resource plan'),
  GoalKind.power => c.tb('goalPower', 'Highest power'),
  GoalKind.potential => c.tb('goalPotential', 'Songless potential'),
};

/// The score goals' texts (`score-goal.ts`).
const scoreGoals = {
  'mean': (
    label: ('criterionMean', 'Average score'),
    help: (
      'criterionMeanHelp',
      'Rank by the average of 120 skill orders for everyday play.',
    ),
    metric: ('expectedScore', 'Average score'),
    proven: ('provenMean', 'Average score proven optimal within this search'),
    unproven: ('unprovenMean', 'Average score: best found so far'),
  ),
  'max': (
    label: ('criterionMax', 'Single-run maximum (ranking)'),
    help: (
      'criterionMaxHelp',
      'Rank by the best skill order for repeated attempts at a high score.',
    ),
    metric: ('bestScore', 'Best-order score'),
    proven: (
      'provenMax',
      'Single-run maximum proven optimal within this search',
    ),
    unproven: ('unprovenMax', 'Single-run maximum: best found so far'),
  ),
  'min': (
    label: ('criterionMin', 'Minimum score (floor)'),
    help: (
      'criterionMinHelp',
      'Rank by the worst skill order to raise the score floor.',
    ),
    metric: ('worstScore', 'Worst-order score'),
    proven: ('provenMin', 'Minimum score proven optimal within this search'),
    unproven: ('unprovenMin', 'Minimum score: best found so far'),
  ),
};

/// A scrolling pane with its primary action pinned to the bottom (`.tb-run`).
Widget sticky(BuildContext context, Widget scroll, Widget action) {
  final surface = Theme.of(context).colorScheme.surface;
  return Stack(
    children: [
      Positioned.fill(child: scroll),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              stops: const [0, 0.7, 1],
              colors: [surface, surface, surface.withValues(alpha: 0)],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: action,
          ),
        ),
      ),
    ],
  );
}

class BuildTab extends StatefulWidget {
  const BuildTab({super.key, required this.controller, this.leading});
  final TeamBuilderController controller;
  final Widget? leading;

  @override
  State<BuildTab> createState() => _BuildTabState();
}

class _BuildTabState extends State<BuildTab> {
  final _songsScroll = ScrollController();
  final _challengeSongsScroll = ScrollController();

  @override
  void dispose() {
    _songsScroll.dispose();
    _challengeSongsScroll.dispose();
    super.dispose();
  }

  TeamBuilderController get controller => widget.controller;
  Object? _settingsStamp;
  List<Widget> _settingsCache = const [];
  List<Widget> _cachedSettings(BuildContext context) {
    final c = controller;
    final stamp = (
      c.settings,
      c.activity,
      c.arenaActive,
      c.arenaDraft,
      c.arenaActive ? c.arena.regulation : null,
      c.catalog,
      c.view,
      Theme.of(context),
      c.state.text,
      MediaQuery.textScalerOf(context),
      MediaQuery.sizeOf(context),
    );
    if (stamp != _settingsStamp) {
      _settingsStamp = stamp;
      _settingsCache = _settings(context);
    }
    return _settingsCache;
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return TeamToolLayout(
      controller: c,
      summary:
          '${c.searchSettings.theoretical ? c.tb('scopeAll', 'All cards') : c.tb('scopeBox', 'My cards')} · ${c.tb('chartCount', '{count} charts', {'count': c.searchSettings.songs.length})}',
      conditions: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.leading != null) ...[
            widget.leading!,
            const SizedBox(height: 16),
          ],
          ..._cachedSettings(context),
        ],
      ),
      action: _run,
      results: (_) => ResultsView(controller: c),
    );
  }

  Widget _run(BuildContext context) {
    final c = controller;
    final s = c.searchSettings;
    final cards = c.engineCards();
    final missing = cards.members.isEmpty
        ? c.tb(
            'needCards',
            'Add cards in My cards, or search all cards at full growth.',
          )
        : c.inputIssue ??
              (c.goal() == null
                  ? (s.goal == GoalKind.event || s.goal == GoalKind.plan
                        ? c.tb('needEventSongs', 'Choose an event and songs.')
                        : c.tb('needSongs', 'Choose at least one song.'))
                  : null);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    );
    if (c.running) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              shape: shape,
            ),
            onPressed: c.cancel,
            icon: const Icon(Symbols.stop_rounded),
            label: Text(c.state.text('common.actions.cancel', 'Cancel')),
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: c.progress != null && c.progress!.$2 > 1
                ? c.progress!.$1 / c.progress!.$2
                : null,
          ),
        ],
      );
    }
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        shape: shape,
        textStyle: Theme.of(context).textTheme.titleMedium,
      ),
      onPressed: missing == null ? c.run : null,
      icon: missing == null ? const Icon(Symbols.search_rounded) : null,
      label: Text(
        missing ?? c.tb('findTeams', 'Find teams'),
        textAlign: TextAlign.center,
      ),
    );
  }

  List<Widget> _settings(BuildContext context) {
    final c = controller;
    final s = c.searchSettings;
    void set(Map<String, Object?> patch) => c.updateSettings(patch);
    final scored = s.goal == GoalKind.score || s.goal == GoalKind.gekiso;
    final needsSongs =
        scored ||
        s.goal == GoalKind.plan ||
        (s.goal == GoalKind.event && s.route != 'skip') ||
        (s.goal == GoalKind.power && s.powerSong);
    return [
      if ((!c.activity || s.goal != GoalKind.plan) &&
          !(c.activity && s.goal == GoalKind.event && s.rewardPlan != null))
        ToolSection(
          icon: Symbols.flag_rounded,
          title: c.arenaActive
              ? c.tb('arena.objective', 'Team objective')
              : c.activity
              ? goalText(c, s.goal)
              : c.tb('goal', 'Goal'),
          children: [
            if (!c.activity && !c.arenaActive)
              _GoalGrid(
                goals: [
                  for (final (goal, icon) in _goals)
                    (goal, icon, goalText(c, goal)),
                ],
                selected: s.goal,
                onSelected: (goal) => set({'goal': goal.name}),
              ),
            if (s.goal == GoalKind.event && s.rewardPlan == null)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: s.fullRanking,
                title: Text(c.tb('fullRanking', 'Full reward ranking')),
                onChanged: (value) => set({'fullRanking': value == true}),
              ),
            if (!c.arenaActive &&
                (scored || s.goal == GoalKind.event && s.route != 'skip'))
              Segmented<String>(
                value: s.shared ? 'mean' : 'individual',
                options: [
                  Choice(
                    'individual',
                    c.tb('arena.individual', 'A team for each song'),
                  ),
                  Choice(
                    'mean',
                    c.tb('multiSong.mean', 'Best average across songs'),
                  ),
                ],
                onSelected: (value) => set({'aggregation': value}),
              ),
            if (scored && !s.shared && !(c.arenaActive && c.arena.shared)) ...[
              DropdownButtonFormField<String>(
                key: ValueKey((
                  'criterion',
                  s.goal,
                  s.scoreTarget,
                  s.criterion,
                )),
                initialValue:
                    s.goal == GoalKind.score && s.scoreTarget != 'none'
                    ? s.scoreTarget
                    : s.criterion,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: c.tb('criterion', 'Score goal'),
                ),
                items: [
                  for (final (key, label) in [
                    ('mean', c.tb('criterionMean', 'Average score')),
                    ('max', c.tb('criterionMax', 'Single-run maximum')),
                    ('min', c.tb('criterionMin', 'Minimum score')),
                    if (s.goal == GoalKind.score) ...[
                      ('at-least', c.tb('criterionReach', 'Reach rate')),
                      ('capped', c.tb('criterionCapped', 'Capped average')),
                    ],
                  ])
                    DropdownMenuItem(
                      value: key,
                      child: Text(label, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  set(
                    value == 'at-least' || value == 'capped'
                        ? {'scoreTarget': value, 'criterion': 'mean'}
                        : {'scoreTarget': 'none', 'criterion': value},
                  );
                },
              ),
              if (s.goal == GoalKind.score && s.scoreTarget != 'none')
                _NumberField(
                  label: c.tb('targetScore', 'Target score'),
                  value: s.targetScore ?? 0,
                  onChanged: (value) =>
                      set({'targetScore': value > 0 ? value : null}),
                ),
            ],
            if (s.goal == GoalKind.gekiso && !s.opponentsMode)
              ToolField(
                label: c.tb('gekisoRank', 'Placement in each range'),
                child: Segmented<int>(
                  value: s.gekisoRank,
                  grow: false,
                  options: [
                    for (var rank = 1; rank <= 5; rank++) Choice(rank, '$rank'),
                  ],
                  onSelected: (value) => set({'gekisoRank': value}),
                ),
              ),
            if (s.goal == GoalKind.gekiso) ...[
              if (c.hasMission(1, s.songs))
                _NumberField(
                  label: c.tb('minComboBonus', 'Minimum base COMBO BONUS'),
                  value: s.minComboBonus,
                  onChanged: (value) =>
                      set({'minComboBonus': value == 0 ? 1 : value}),
                ),
              _NumberField(
                label: c.tb('pt.luckSamples', 'Luck samples'),
                value: s.gekisoSeeds,
                onChanged: (value) => set({'gekisoSeeds': value}),
              ),
              if (!s.shared && !(c.arenaActive && c.arena.shared))
                _WrappingSegments(
                  value: s.opponentsMode ? 'opponents' : 'rank',
                  options: [
                    ('rank', c.tb('placementRank', 'Specified placement')),
                    (
                      'opponents',
                      c.tb('placementOpponents', 'Opponent scores'),
                    ),
                  ],
                  onSelected: (value) => set({'gekisoPlacementMode': value}),
                ),
              if (s.opponentsMode)
                for (var range = 0; range < 3; range++)
                  TextFormField(
                    key: ValueKey('opponents-$range'),
                    initialValue: s.opponentDrafts[range],
                    keyboardType: TextInputType.text,
                    decoration: InputDecoration(
                      labelText: c.tb('gekisoRange', 'Range {n}', {
                        'n': range + 1,
                      }),
                    ),
                    onChanged: (value) => set({
                      'gekisoOpponents': [
                        for (var i = 0; i < 3; i++)
                          i == range ? value : s.opponentDrafts[i],
                      ],
                    }),
                  ),
            ],
            if (s.goal == GoalKind.potential)
              Segmented<int>(
                value: s.window,
                options: [
                  for (final window in const [60, 120, 180])
                    Choice(window, '$window s'),
                ],
                onSelected: (value) => set({'window': value}),
              ),
            if (s.goal == GoalKind.power)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: s.powerSong,
                onChanged: (value) => set({'powerSong': value == true}),
                title: Text(
                  c.tb('powerSong', "Include a song's type and tag bonus"),
                ),
              ),
            if (s.goal == GoalKind.score || s.goal == GoalKind.power) ...[
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: s.challengeRules,
                onChanged: (value) => set({'challengeRules': value == true}),
                title: Text(
                  c.tb(
                    'challengeRules',
                    'Challenge live rules (event parameter bonus)',
                  ),
                ),
              ),
              if (s.challengeRules) ..._eventSection(context),
            ],
          ],
        ),
      if (!c.arenaActive &&
          (s.goal == GoalKind.gekiso ||
              s.goal == GoalKind.score ||
              s.goal == GoalKind.power ||
              s.goal == GoalKind.event)) ...[
        const SizedBox(height: 16),
        ToolSection(
          icon: Symbols.tune_rounded,
          title: c.tb('songRules', 'Song rules'),
          children: [
            SongRulesEditor(
              controller: c,
              rules: s.songRulesOverride,
              onChanged: (value) => set({'songRules': value}),
            ),
          ],
        ),
      ],
      if (s.goal == GoalKind.event) ...[
        const SizedBox(height: 16),
        ToolSection(
          icon: Symbols.emoji_events_rounded,
          title: c.tb('eventSetup', 'Event'),
          children: [
            ..._eventSection(context),
            ManualEventControls(controller: c),
            Segmented<String>(
              value: s.route,
              options: [
                Choice(
                  'live',
                  c.tb('routeLive', 'Normal live'),
                  Symbols.play_arrow_rounded,
                ),
                Choice(
                  'challenge',
                  c.tb('routeChallenge', 'Challenge live'),
                  Symbols.swords_rounded,
                ),
                Choice(
                  'skip',
                  c.tb('routeSkip', 'Skip'),
                  Symbols.fast_forward_rounded,
                ),
              ],
              onSelected: (route) => set({
                'route': route,
                if (route != 'live' && s.measure == 'challenge-points')
                  'measure': 'points',
              }),
            ),
            if (!c.activity) ...[
              Segmented<String>(
                value: s.measure,
                options: [
                  Choice('points', c.tb('measurePoints', 'Event points')),
                  Choice('items', c.tb('measureItems', 'Shop items')),
                  if (s.route == 'live')
                    Choice(
                      'challenge-points',
                      c.tb('measureCp', 'Challenge points'),
                    ),
                ],
                onSelected: (value) => set({'measure': value}),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(c.tb('measureWeighted', 'Weighted rewards')),
                value: s.weighted,
                onChanged: (value) => set({'weighted': value}),
              ),
              if (s.weighted)
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final (key, label) in [
                      (
                        'weightPoints',
                        c.tb('weightPoints', 'Weight per event point'),
                      ),
                      (
                        'weightItems',
                        c.tb('weightItems', 'Weight per shop item'),
                      ),
                      if (s.route == 'live')
                        (
                          'weightCp',
                          c.tb('weightCp', 'Weight per challenge point'),
                        ),
                    ])
                      TextFormField(
                        key: ValueKey('reward-$key'),
                        initialValue:
                            '${s.weights![key == 'weightPoints'
                                ? 'points'
                                : key == 'weightItems'
                                ? 'items'
                                : 'challengePoints']}',
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(labelText: label),
                        onChanged: (value) =>
                            set({key: double.tryParse(value) ?? 0}),
                      ),
                  ],
                ),
            ],
            if (s.route == 'challenge')
              ToolField(
                label: c.tb('cpPerLive', 'Challenge points per live'),
                child: Segmented<int>(
                  value: s.challengePoints,
                  options: [
                    for (final cp in const [200, 400, 800, 1600])
                      Choice(cp, '$cp'),
                  ],
                  onSelected: (value) => set({'challengePoints': value}),
                ),
              )
            else
              _boostMenu(c, s.boosts, (value) => set({'boosts': value})),
          ],
        ),
      ],
      if (s.goal == GoalKind.plan) ...[
        const SizedBox(height: 16),
        ToolSection(
          icon: Symbols.cycle_rounded,
          title: c.tb('planSetup', 'Resource plan'),
          children: [
            ..._eventSection(context),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _NumberField(
                  label: c.tb('planBudget', 'Boosts to spend'),
                  value: s.planBudget,
                  onChanged: (value) => set({'planBudget': value}),
                ),
                SizedBox(
                  width: 180,
                  child: _boostMenu(
                    c,
                    s.planBoostsPerLive,
                    (value) => set({'planBoostsPerLive': value}),
                  ),
                ),
                _NumberField(
                  label: c.tb('planStartCp', 'Challenge points now'),
                  value: s.planStartingCp,
                  onChanged: (value) => set({'planStartingCp': value}),
                ),
              ],
            ),
            ToolField(
              label: c.tb('cpPerLive', 'Challenge points per live'),
              child: Segmented<int>(
                value: s.challengePoints,
                options: [
                  for (final cp in const [200, 400, 800, 1600])
                    Choice(cp, '$cp'),
                ],
                onSelected: (value) => set({'challengePoints': value}),
              ),
            ),
            ToolField(
              label: c.tb('planChallengeSongs', 'Challenge songs'),
              child: _songList(
                context,
                s.planChallengeSongs,
                (songs) => set({
                  'planChallengeSongs': [
                    for (final song in songs) song.toJson(),
                  ],
                }),
                challenge: true,
                allowed: [
                  for (final row in c.catalog!.challengeSongs(s.eventId))
                    row.liveMusicId,
                ],
              ),
            ),
          ],
        ),
      ],
      if (needsSongs) ...[
        const SizedBox(height: 16),
        ToolSection(
          icon: Symbols.library_music_rounded,
          title: s.goal == GoalKind.plan
              ? c.tb('planNormalSongs', 'Normal-live songs')
              : c.tb('songs', 'Songs'),
          count: s.songs.isEmpty ? null : '${s.songs.length}',
          children: [
            _songList(
              context,
              s.goal == GoalKind.power ? s.songs.take(1).toList() : s.songs,
              (songs) => set({
                'songs': [for (final song in songs) song.toJson()],
              }),
              single: s.goal == GoalKind.power,
              allowed: c.allowedSongIds,
            ),
          ],
        ),
      ],
      if (scored ||
          s.goal == GoalKind.plan ||
          (s.goal == GoalKind.event && s.route != 'skip')) ...[
        const SizedBox(height: 16),
        ToolSection(
          icon: Symbols.piano_rounded,
          title: c.tb('play', 'Play'),
          children: c.activity && s.ptGekiso && s.rewardPlan != null
              ? [Text(c.tb('playAp', 'All Perfect'))]
              : _playSection(context),
        ),
      ],
      const SizedBox(height: 16),
      _Candidates(controller: c),
    ];
  }

  Widget _boostMenu(
    TeamBuilderController c,
    int value,
    ValueChanged<int> onChanged,
  ) {
    final rows = {for (final row in c.catalog!.master.boosts) row.consumed};
    return DropdownMenu<int>(
      expandedInsets: EdgeInsets.zero,
      label: Text(c.tb('boosts', 'Boosts per live')),
      initialSelection: value,
      onSelected: (value) {
        if (value != null) onChanged(value);
      },
      dropdownMenuEntries: [
        for (final cost in liveBoostCosts)
          DropdownMenuEntry(
            value: cost,
            label: '$cost',
            enabled: cost == 0 || rows.contains(cost),
          ),
      ],
    );
  }

  List<Widget> _eventSection(BuildContext context) {
    final c = controller;
    final s = c.searchSettings;
    final catalog = c.catalog!;
    final events = catalog.events();
    if (events.isEmpty) {
      return [Text(c.tb('noEvents', "This server's data has no event yet."))];
    }
    final eventId = s.eventId ?? events.first.id;
    if (s.eventId == null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => c.updateSettings({'eventId': eventId}),
      );
    }
    final challengeSongs = catalog.challengeSongs(eventId);
    final challenge =
        s.goal == GoalKind.plan ||
        (s.goal == GoalKind.event ? s.route == 'challenge' : s.challengeRules);
    return [
      DropdownMenu<int>(
        key: ValueKey('event-$eventId'),
        expandedInsets: EdgeInsets.zero,
        label: Text(c.tb('event', 'Event')),
        initialSelection: eventId,
        enableFilter: true,
        requestFocusOnTap: true,
        menuHeight: 360,
        onSelected: (value) {
          if (value != null) c.updateSettings({'eventId': value});
        },
        dropdownMenuEntries: [
          for (final row in events)
            DropdownMenuEntry(
              value: row.id,
              label: row.name,
              leadingIcon: row.serverMark == null
                  ? null
                  : Tooltip(
                      message: row.serverMark!.$2,
                      child: SizedBox.square(
                        dimension: 18,
                        child: AppImage(candidates: [row.serverMark!.$1]),
                      ),
                    ),
            ),
        ],
      ),
      if (challenge && challengeSongs.isNotEmpty)
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: () {
                final songs = [
                  for (final row in challengeSongs)
                    if (catalog
                        .difficultyRows(row.liveMusicId)
                        .any((d) => d['difficulty'] == 3))
                      SongRef(row.liveMusicId, 3).toJson(),
                ];
                c.updateSettings(
                  s.goal == GoalKind.plan
                      ? {'planChallengeSongs': songs}
                      : {
                          'songs': s.goal == GoalKind.power
                              ? songs.take(1).toList()
                              : songs,
                        },
                );
              },
              icon: const Icon(Symbols.swords_rounded),
              label: Text(c.tb('useChallengeSongs', 'Use challenge songs')),
            ),
          ],
        ),
    ];
  }

  Widget _songList(
    BuildContext context,
    List<SongRef> songs,
    ValueChanged<List<SongRef>> onChanged, {
    bool single = false,
    bool challenge = false,
    List<int>? allowed,
  }) {
    final c = controller;
    final catalog = c.catalog!;
    final scroll = challenge ? _challengeSongsScroll : _songsScroll;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (songs.isNotEmpty)
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: (MediaQuery.sizeOf(context).height * 0.4).clamp(
                160,
                360,
              ),
            ),
            child: Scrollbar(
              controller: scroll,
              child: ListView.builder(
                controller: scroll,
                primary: false,
                shrinkWrap: true,
                itemCount: songs.length,
                itemBuilder: (context, index) => SongRow(
                  catalog: catalog,
                  song: songs[index],
                  trailing: IconButton(
                    tooltip: catalog.t('common.actions.remove', 'Remove'),
                    onPressed: () => onChanged([
                      for (final (i, other) in songs.indexed)
                        if (i != index) other,
                    ]),
                    icon: const Icon(Symbols.close_rounded),
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: () async {
              final picked = await pickSongs(
                context,
                catalog,
                songs,
                single: single,
                allowed: allowed,
                allowedCharts: c.arenaActive ? c.arena.charts : null,
              );
              if (picked != null) onChanged(picked);
            },
            icon: const Icon(Symbols.add_rounded),
            label: Text(
              songs.isEmpty
                  ? c.tb('addSongs', 'Choose songs')
                  : c.tb('editSongs', 'Change songs'),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _playSection(BuildContext context) {
    final c = controller;
    final s = c.searchSettings;
    Widget slider(String label, String key, int value, int max) => ToolField(
      label: label,
      value: '$value%',
      child: Slider(
        value: value.clamp(0, max).toDouble(),
        max: max.toDouble(),
        divisions: max,
        label: '$value%',
        onChanged: (v) => c.updateSettings({key: v.round()}),
      ),
    );
    return [
      Segmented<bool>(
        value: s.allPerfect,
        options: [
          Choice(
            true,
            c.tb('playAp', 'All Perfect'),
            Symbols.workspace_premium_rounded,
          ),
          Choice(
            false,
            c.tb('playCustom', 'My accuracy'),
            Symbols.tune_rounded,
          ),
        ],
        onSelected: (value) =>
            c.updateSettings({'playMode': value ? 'ap' : 'custom'}),
      ),
      if (s.goal == GoalKind.gekiso) ...[
        if (!s.allPerfect) ...[
          slider('GREAT', 'great', s.great, 40),
          _NumberField(
            label: c.tb('missEvery', 'Miss every N notes'),
            value: s.missEvery,
            onChanged: (value) => c.updateSettings({'missEvery': value}),
          ),
        ],
        if (c.hasMission(3, s.songs)) slider('JUST', 'just', s.just, 100),
      ] else if (!s.allPerfect) ...[
        slider('GREAT', 'great', s.great, 40),
        slider('GOOD', 'good', s.good, 20),
        slider('MISS', 'miss', s.miss, 20),
        _NumberField(
          label: c.tb('missEvery', 'Miss every N notes'),
          value: s.missEvery,
          onChanged: (value) => c.updateSettings({'missEvery': value}),
        ),
      ],
    ];
  }
}

class _NumberField extends StatefulWidget {
  const _NumberField({
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final _text = TextEditingController(
    text: widget.value == 0 ? '' : '${widget.value}',
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 180,
    child: TextField(
      controller: _text,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: '0',
        border: const OutlineInputBorder(),
      ),
      onSubmitted: (value) =>
          widget.onChanged((int.tryParse(value.trim()) ?? 0).clamp(0, 1 << 31)),
      onTapOutside: (_) => widget.onChanged(
        (int.tryParse(_text.text.trim()) ?? 0).clamp(0, 1 << 31),
      ),
    ),
  );
}

/// Cards and limits: scope, growth policy, candidate filters and
/// constraints, in an accordion (`candidates`).
class _Candidates extends StatelessWidget {
  const _Candidates({required this.controller});
  final TeamBuilderController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.searchSettings;
    final catalog = c.catalog!;
    final view = c.view!;
    final t = catalog.t;
    void set(Map<String, Object?> patch) => c.updateSettings(patch);
    List<int> toggle(List<int> list, int value) => list.contains(value)
        ? [...list.where((item) => item != value)]
        : [...list, value];
    final cards = c.engineCards();
    final required =
        view.members.values.where((row) => row.use && row.lock).length +
        view.snaps.values.where((row) => row.use && row.lock).length;
    final owned = [
      for (final row in view.members.values)
        if (row.use) row.cardId,
    ];
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: const Icon(Symbols.tune_rounded),
        title: Text(c.tb('candidates', 'Cards and limits')),
        subtitle: Text(
          '${c.tb('candidateSummary', '{members} members · {snaps} snaps', {'members': cards.members.length, 'snaps': cards.snaps.length})}'
          '${required > 0 ? ' · ${c.tb('requiredCount', '{count} required', {'count': required})}' : ''}',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Segmented<bool>(
            value: s.theoretical,
            options: [
              Choice(
                false,
                c.tb('scopeBox', 'My cards'),
                Symbols.style_rounded,
              ),
              Choice(
                true,
                c.tb('scopeAll', 'All cards, full growth'),
                Symbols.auto_awesome_motion_rounded,
              ),
            ],
            onSelected: (value) =>
                set({'scope': value ? 'theoretical' : 'box'}),
          ),
          if (!s.theoretical) ...[
            const SizedBox(height: 12),
            ToolField(
              label: c.tb('unknownPolicy', 'Growth not entered'),
              child: Segmented<String>(
                value: s.unknownPolicy,
                grow: false,
                options: [
                  Choice('max', c.tb('unknownMax', 'Count as max')),
                  Choice('min', c.tb('unknownMin', 'Count as minimum')),
                ],
                onSelected: (value) => set({'unknownPolicy': value}),
              ),
            ),
          ],
          const SizedBox(height: 12),
          ToolField(
            label: t('catalog.fields.attribute', 'Attribute'),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final id in [1, 2, 3, 4, 5])
                  FilterChip(
                    avatar: catalog.attributeIcon(id) == null
                        ? null
                        : AppImage(candidates: [catalog.attributeIcon(id)!]),
                    label: Text(catalog.attributeName(id)),
                    selected: s.attributes.contains(id),
                    onSelected: (_) =>
                        set({'attributes': toggle(s.attributes, id)}),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ToolField(
            label: t('catalog.fields.band', 'Band'),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final id in catalog.bandIds)
                  FilterChip(
                    avatar: catalog.bandIcon(id).isEmpty
                        ? null
                        : AppImage(candidates: [catalog.bandIcon(id)]),
                    label: Text(catalog.bandName(id)),
                    selected: s.bands.contains(id),
                    onSelected: (_) => set({'bands': toggle(s.bands, id)}),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ToolField(
            label: c.tb('minRarity', 'Minimum rarity'),
            child: Segmented<int>(
              value: s.minRarity,
              grow: false,
              options: [
                Choice(0, t('common.states.all', 'All')),
                for (final rarity in const [2, 3, 4])
                  Choice(rarity, '${cardRarityName(rarity)}+'),
              ],
              onSelected: (value) => set({'minRarity': value}),
            ),
          ),
          const SizedBox(height: 16),
          DropdownMenu<int>(
            expandedInsets: EdgeInsets.zero,
            label: Text(c.tb('leader', 'Leader')),
            initialSelection: s.leader ?? 0,
            enableFilter: true,
            requestFocusOnTap: true,
            menuHeight: 360,
            onSelected: (value) =>
                set({'leader': value == null || value == 0 ? null : value}),
            dropdownMenuEntries: [
              DropdownMenuEntry(
                value: 0,
                label: c.tb('leaderAuto', 'Best leader (automatic)'),
              ),
              for (final id in owned)
                DropdownMenuEntry(
                  value: id,
                  label:
                      '${catalog.cardName(true, id)} · ${catalog.cardSubtitle(true, id)}',
                ),
            ],
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: s.noSnaps,
            onChanged: (value) => set({'noSnaps': value == true}),
            title: Text(c.tb('noSnaps', 'No snaps')),
          ),
          if (s.goal == GoalKind.event || s.goal == GoalKind.plan) ...[
            TextFormField(
              key: ValueKey('min-bonus-${s.minBonus}'),
              initialValue: s.minBonus == null ? '' : '${s.minBonus!.round()}',
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: c.tb('minBonus', 'Minimum event bonus (%)'),
                border: const OutlineInputBorder(),
              ),
              onFieldSubmitted: (raw) => set({
                'minBonus': raw.trim().isEmpty
                    ? null
                    : (double.tryParse(raw) ?? 0).clamp(0, 100000),
              }),
            ),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              DropdownMenu<int>(
                width: 160,
                label: Text(c.tb('resultCount', 'Results')),
                initialSelection: s.k,
                onSelected: (value) {
                  if (value != null) set({'k': value});
                },
                dropdownMenuEntries: [
                  for (final k in const [1, 3, 5, 10, 15, 20])
                    DropdownMenuEntry(value: k, label: '$k'),
                ],
              ),
              DropdownMenu<int>(
                width: 200,
                label: Text(c.tb('timeLimit', 'Time limit')),
                initialSelection: s.timeLimit ?? 0,
                onSelected: (value) => set({
                  'timeLimit': value == null || value == 0 ? null : value,
                }),
                dropdownMenuEntries: [
                  for (final limit in const [0, 5, 15, 60])
                    DropdownMenuEntry(
                      value: limit,
                      label: limit == 0
                          ? c.tb('noLimit', 'Until proven')
                          : '$limit s',
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The goal choices as a grid of cards (`.tb-goals`).
class _GoalGrid extends StatelessWidget {
  const _GoalGrid({
    required this.goals,
    required this.selected,
    required this.onSelected,
  });
  final List<(GoalKind, IconData, String)> goals;
  final GoalKind selected;
  final ValueChanged<GoalKind> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 600;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth < 200 ? 1 : 2;
        final width = (constraints.maxWidth - 8 * (columns - 1)) / columns;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (goal, icon, label) in goals)
              SizedBox(
                width: width,
                child: Material(
                  color: goal == selected
                      ? scheme.secondaryContainer
                      : Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: goal == selected
                        ? BorderSide.none
                        : BorderSide(color: scheme.outlineVariant),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => onSelected(goal),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: compact ? 48 : 56),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(compact ? 8 : 8, 8, 12, 8),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: compact ? 14 : 18,
                              backgroundColor: goal == selected
                                  ? scheme.primary
                                  : scheme.surfaceContainerHighest,
                              foregroundColor: goal == selected
                                  ? scheme.onPrimary
                                  : scheme.onSurfaceVariant,
                              child: Icon(icon, size: compact ? 16 : 20),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                label,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: goal == selected
                                      ? scheme.onSecondaryContainer
                                      : scheme.onSurface,
                                ),
                              ),
                            ),
                          ],
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

/// A segmented choice whose labels wrap onto more lines rather than
/// ellipsizing (`segmented` with long options).
class _WrappingSegments<T> extends StatelessWidget {
  const _WrappingSegments({
    required this.value,
    required this.options,
    required this.onSelected,
  });
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(40),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (option, label) in options)
              Expanded(
                child: Material(
                  color: option == value
                      ? scheme.secondaryContainer
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(40),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => onSelected(option),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 56),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          child: Text(
                            label,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: option == value
                                  ? scheme.onSecondaryContainer
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Per-song rules of an Arena period: the attribute a song is treated as and
/// the three range types (`lit/team-builder/song-rules.ts`).
class SongRulesEditor extends StatelessWidget {
  const SongRulesEditor({
    super.key,
    required this.controller,
    required this.rules,
    required this.onChanged,
  });
  final TeamBuilderController controller;
  final ({int musicType, List<int> missions})? rules;
  final ValueChanged<Map<String, Object?>?> onChanged;

  void _write({int? musicType, int? mission, int? index}) {
    final current = rules;
    final nextMusic = musicType ?? current?.musicType ?? 0;
    final nextMissions = [
      for (var i = 0; i < 3; i++)
        index == i ? mission ?? 0 : (current?.missions[i] ?? 0),
    ];
    onChanged({'musicType': nextMusic, 'missions': nextMissions});
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final catalog = c.catalog!;
    const missionNames = ['—', 'COMBO', 'LUCK', 'JUST'];
    Widget field(String label, Widget child) => Padding(
      padding: const EdgeInsets.only(right: 8, bottom: 8),
      child: InputDecorator(
        decoration: InputDecoration(isDense: true, labelText: label),
        child: child,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field(
          c.tb('songRule.attribute', 'Song attribute'),
          DropdownButton<int>(
            value: rules?.musicType ?? -1,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            items: [
              DropdownMenuItem(
                value: -1,
                child: Text(c.tb('songRule.master', 'From data')),
              ),
              DropdownMenuItem(
                value: 0,
                child: Text(c.tb('arena.original', 'Original song')),
              ),
              for (final id in [1, 2, 3, 4, 5])
                DropdownMenuItem(
                  value: id,
                  child: Text(catalog.attributeName(id)),
                ),
              DropdownMenuItem(
                value: 99,
                child: Text(c.tb('arena.any', 'Any attribute')),
              ),
            ],
            onChanged: (value) => value == null || value < 0
                ? onChanged(null)
                : _write(musicType: value),
          ),
        ),
        Row(
          children: [
            for (var index = 0; index < 3; index++)
              Expanded(
                child: field(
                  c.tb('arena.range', 'Range {count}', {'count': index + 1}),
                  DropdownButton<int>(
                    value: rules?.missions[index] ?? 0,
                    isExpanded: true,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (var value = 0; value < 4; value++)
                        DropdownMenuItem(
                          value: value,
                          child: Text(
                            value == 0
                                ? c.tb('arena.original', 'Original song')
                                : missionNames[value],
                          ),
                        ),
                    ],
                    onChanged: (value) =>
                        _write(index: index, mission: value ?? 0),
                  ),
                ),
              ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: rules == null ? null : () => onChanged(null),
            icon: const Icon(Symbols.restart_alt_rounded, size: 18),
            label: Text(c.tb('songRule.clear', 'Use data values')),
          ),
        ),
      ],
    );
  }
}
