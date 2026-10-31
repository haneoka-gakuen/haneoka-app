import '../core/site_date.dart';
import '../core/catalog_source.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';
import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../core/i18n.dart';
import '../shell/links.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/shapes.dart';
import '../ui/theme.dart';
import '../ui/tile.dart';
import 'cross_server.dart';
import 'mission_groups.dart';

const _categoryLabels = [
  ('categoryOther', 'Other missions'),
  ('categoryDaily', 'Daily missions'),
  ('categoryPeriod', 'Limited missions'),
  ('categoryEvent', 'Event missions'),
  ('categoryNormal', 'Normal missions'),
  ('categoryBeginner', 'Beginner missions'),
  ('categoryComeback', 'Comeback missions'),
  ('categoryCharacter', 'Character missions'),
  ('categoryInvitation', 'Friend invitation missions'),
  ('categorySecret', 'Hidden missions'),
  ('categoryEventDaily', 'Daily event missions'),
  ('categoryCircle', 'Circle missions'),
  ('categoryCircleDaily', 'Daily circle missions'),
  ('categoryEventCircle', 'Circle event missions'),
  ('categoryEventCircleDaily', 'Daily circle event missions'),
  ('categoryUnlockMusic', 'Song unlock missions'),
  ('categoryUnlockHome', 'Scene unlock missions'),
];

String _label(
  SiteText t,
  String key,
  String fallback, [
  Map<String, Object?> values = const {},
]) => t.system(key, fallback, values);

String _categoryLabel(SiteText t, int category) {
  final entry =
      _categoryLabels[category >= 0 && category < _categoryLabels.length
          ? category
          : 0];
  return t('catalog.missions.${entry.$1}', entry.$2);
}

IconData _categoryIcon(int category) => switch (category) {
  1 || 10 || 12 || 14 => Symbols.event_repeat_rounded,
  2 || 3 || 13 => Symbols.schedule_rounded,
  15 || 16 => Symbols.lock_open_rounded,
  9 => Symbols.visibility_off_rounded,
  8 || 11 => Symbols.group_rounded,
  _ => Symbols.fact_check_rounded,
};

String _title(SiteText t, MissionGroup group) {
  final name = t.text(group.rows.first['group']);
  return name.isEmpty ? _categoryLabel(t, group.category) : name;
}

String _date(SiteText t, num value) => value <= 0
    ? ''
    : '${SiteDate.day(t.locale).withTime().format(DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true).add(const Duration(hours: 9)))} JST';

String _window(SiteText t, MissionGroup group) {
  if (const [1, 12].contains(group.category) && !group.timed) {
    return _label(t, 'missionDailyReset', 'Resets daily');
  }
  if (group.releaseDay > 0) {
    return t('catalog.missions.releaseDay', 'Day {day}', {
      'day': group.releaseDay,
    });
  }
  if (group.start == 0 && group.end == 0) {
    return _label(t, 'missionNoEnd', 'No end date');
  }
  return group.start > 0 && group.end > 0
      ? '${_date(t, group.start)} – ${_date(t, group.end)}'
      : _date(t, group.start > 0 ? group.start : group.end);
}

String _statusLabel(SiteText t, String status) =>
    _label(t, status, switch (status) {
      'ended' => 'Ended',
      'upcoming' => 'Upcoming',
      _ => 'Ongoing',
    });

Widget _goal(SiteText t, Map mission) {
  final goal = num.tryParse('${mission['goal']}') ?? 0;
  if (goal <= 0) return const SizedBox.shrink();
  return Text.rich(
    TextSpan(
      children: [
        TextSpan(text: '${t('catalog.missions.goal', 'Goal')} · '),
        TextSpan(
          text: NumberFormat.decimalPattern(t.locale).format(goal),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

Widget _serverMark(SiteText t, Map mission) {
  final mark = serverMark(mission, (key, fallback) => t(key, fallback));
  return mark == null
      ? const SizedBox.shrink()
      : Tooltip(
          message: mark.$2,
          child: SvgPicture.asset(
            mark.$1,
            width: 18,
            height: 18,
            semanticsLabel: mark.$2,
          ),
        );
}

/// One reward as the website's `.mission-chip`: emblem, name, quantity.
class RewardChip extends StatelessWidget {
  const RewardChip(this.reward, {super.key, this.color});
  final Map reward;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = t.text(reward['name']);
    if (title.isEmpty) return const SizedBox.shrink();
    final count = (reward['count'] as num?) ?? 0;
    final image = reward['image'];
    final href = reward['href'];
    return Material(
      color: color ?? scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(Corner.small),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: href is String && href.isNotEmpty
            ? () => openLink(context, href)
            : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 10, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 24,
                child: image is String && image.isNotEmpty
                    ? AppImage(
                        candidates: [
                          CatalogSourceScope.apiOf(context)
                              .asset(image)
                              .toString(),
                        ],
                      )
                    : Icon(
                        Symbols.redeem_rounded,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge,
                ),
              ),
              if (count > 1)
                Text(
                  ' ×${NumberFormat.decimalPattern(t.locale).format(count)}',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Formal mission categories and effective windows, shared with the web view.
class MissionsScreen extends StatefulWidget {
  const MissionsScreen({super.key});
  @override
  State<MissionsScreen> createState() => _MissionsScreenState();
}

class _MissionsScreenState extends State<MissionsScreen> {
  Future<List<Map<String, Object?>>>? _data;
  Object? _dataKey;
  String _mode = 'all';
  late final Timer _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  Future<List<Map<String, Object?>>> _load(AppState state) =>
      crossServerCollection(
        resource: 'missions',
        selected: CatalogSourceScope.serverOf(context),
        apis: CatalogSourceScope.apisOf(context),
        rowsPath: 'entries',
      );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    if (_dataKey != state.publicDataKey) {
      _dataKey = state.publicDataKey;
      _data = _load(state);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context), t = state.text;
    return ShellPage(
      title: t('navigation.missions', 'Missions'),
      actions: [
        BarAction.choice(
          label: t('navigation.missions', 'Missions'),
          options: [
            for (final entry in [
              ('all', Symbols.apps_rounded, t('common.states.all', 'All')),
              (
                'regular',
                Symbols.fact_check_rounded,
                t('catalog.missions.permanent', 'Permanent missions'),
              ),
              (
                'limited',
                Symbols.schedule_rounded,
                _label(t, 'limitedMission', 'Limited missions'),
              ),
            ])
              BarChoice(
                icon: entry.$2,
                label: entry.$3,
                selected: _mode == entry.$1,
                onSelected: () => setState(() => _mode = entry.$1),
              ),
          ],
        ),
      ],
      body: FutureBuilder(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: FilledButton.tonal(
                onPressed: () => setState(() => _data = _load(state)),
                child: Text(t('common.actions.retry', 'Retry')),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final now = DateTime.now().millisecondsSinceEpoch;
          final groups =
              groupMissions(
                    snapshot.data!,
                    SiteText.tupleOrder.indexOf(t.locale),
                  )
                  .where(
                    (g) =>
                        _mode == 'all' ||
                        (_mode == 'limited' ? g.timed : !g.timed),
                  )
                  .toList();
          List<MissionGroup> timed(String status) =>
              groups
                  .where((g) => g.timed && missionGroupStatus(g, now) == status)
                  .toList()
                ..sort(
                  (a, b) => status == 'upcoming'
                      ? a.start.compareTo(b.start)
                      : b.start.compareTo(a.start),
                );
          final sections = [
            (
              _label(t, 'missionDaily', 'Daily missions'),
              groups.where((g) => g.category == 1 && !g.timed).toList(),
            ),
            (
              '${_label(t, 'limitedMission', 'Limited missions')} · ${_statusLabel(t, 'ongoing')}',
              timed('ongoing'),
            ),
            (
              '${_label(t, 'limitedMission', 'Limited missions')} · ${_statusLabel(t, 'upcoming')}',
              timed('upcoming'),
            ),
            (
              t('catalog.missions.permanent', 'Permanent missions'),
              groups.where((g) => !g.timed && g.category != 1).toList(),
            ),
            (
              '${_label(t, 'limitedMission', 'Limited missions')} · ${_statusLabel(t, 'ended')}',
              timed('ended'),
            ),
          ].where((s) => s.$2.isNotEmpty);
          return LayoutBuilder(
            builder: (context, constraints) {
              final padding = pagePadding(context);
              final width = constraints.maxWidth - padding.horizontal;
              final columns = ((width + 12) / 332).floor().clamp(1, 6);
              final card = (width - 12 * (columns - 1)) / columns;
              return ListView(
                padding: padding,
                children: [
                  for (final section in sections) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 16),
                      child: Text(
                        section.$1,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final group in section.$2)
                          SizedBox(width: card, child: _GroupCard(group)),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ],
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// Rewards summed across a group's missions, in first-seen order.
List<Map> _rewardTotals(SiteText t, List<Map> rows) {
  final totals = <String, Map>{};
  for (final mission in rows) {
    for (final reward
        in (mission['rewards'] as List? ?? const []).whereType<Map>()) {
      final name = t.text(reward['name']);
      if (name.isEmpty) continue;
      final key =
          '${reward['kind'] ?? ''}:${reward['resourceType'] ?? ''}:${reward['resourceId'] ?? name}';
      final count = (reward['count'] as num?) ?? 1;
      final entry = totals[key];
      if (entry != null) {
        entry['count'] = (entry['count'] as num) + count;
      } else {
        totals[key] = {...reward, 'count': count, 'href': ''};
      }
    }
  }
  return totals.values.toList();
}

class _GroupCard extends StatelessWidget {
  const _GroupCard(this.group);
  final MissionGroup group;

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final totals = _rewardTotals(t, group.rows);
    final limited = group.timed;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(Corner.extraLarge),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => _GroupScreen(group))),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  ShapedIcon(
                    shape: MaterialShapes.cookie9Sided,
                    size: 48,
                    color: limited ? scheme.tertiaryContainer : null,
                    foreground: limited ? scheme.onTertiaryContainer : null,
                    child: Icon(_categoryIcon(group.category), size: 24),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(Corner.full),
                    ),
                    child: Text(
                      _label(t, 'missionCount', '{count} missions', {
                        'count': NumberFormat.decimalPattern(t.locale)
                            .format(group.rows.length),
                      }),
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _title(t, group),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (group.timed)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _statusLabel(
                      t,
                      missionGroupStatus(
                        group,
                        DateTime.now().millisecondsSinceEpoch,
                      ),
                    ),
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.tertiary,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Symbols.schedule_rounded,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _window(t, group),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              if (totals.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final reward in totals.take(4))
                        RewardChip(reward, color: scheme.surfaceContainerHigh),
                      if (totals.length > 4)
                        Text(
                          '+${totals.length - 4}',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One group's missions: each condition on a line with its rewards.
class _GroupScreen extends StatelessWidget {
  const _GroupScreen(this.group);
  final MissionGroup group;

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ShellPage(
      title: _title(t, group),
      showBack: true,
      status: Text('${group.rows.length}'),
      body: ListView(
        padding: pagePadding(context),
        children: [
          Material(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(Corner.extraLarge),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 56),
                    child: Row(
                      children: [
                        ShapedIcon(
                          shape: MaterialShapes.cookie9Sided,
                          size: 40,
                          child: Icon(_categoryIcon(group.category), size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _title(t, group),
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                _window(t, group),
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (final (index, mission) in group.rows.indexed) ...[
                    if (index > 0)
                      Divider(height: 1, color: scheme.outlineVariant),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 8,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(
                                    Corner.small,
                                  ),
                                  onTap: () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => MissionDetailScreen(
                                        id: '${mission['id']}',
                                        server:
                                            '${mission[serverKey] ?? CatalogSourceScope.serverOf(context)}',
                                      ),
                                    ),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 4,
                                    ),
                                    child: Text(
                                      t.text(mission['title']).isEmpty
                                          ? '—'
                                          : t.text(mission['title']),
                                      style: theme.textTheme.bodyLarge
                                          ?.copyWith(color: scheme.primary),
                                    ),
                                  ),
                                ),
                              ),
                              _serverMark(t, mission),
                            ],
                          ),
                          const SizedBox(height: 4),
                          _goal(t, mission),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final reward
                                  in (mission['rewards'] as List? ?? const [])
                                      .whereType<Map>())
                                RewardChip(reward),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mission links and the group's condition list open this same detail view.
class MissionDetailScreen extends StatefulWidget {
  const MissionDetailScreen({super.key, required this.id, this.server});
  final String id;
  final String? server;
  @override
  State<MissionDetailScreen> createState() => _MissionDetailScreenState();
}

class _MissionDetailScreenState extends State<MissionDetailScreen> {
  Future<Object?>? _data;
  String? _server;
  Object? _dataKey;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context),
        server = widget.server ?? CatalogSourceScope.serverOf(context);
    if (_dataKey != (state.publicDataKey, server)) {
      _dataKey = (state.publicDataKey, server);
      _server = server;
      _data = state.apiFor(server).catalog('missions', widget.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context),
        t = state.text,
        theme = Theme.of(context);
    return FutureBuilder(
      future: _data,
      builder: (context, snapshot) {
        final mission = snapshot.data is Map ? snapshot.data as Map : null;
        final title = mission == null ? '' : t.text(mission['title']);
        return ShellPage(
          title: title.isEmpty ? t('navigation.missions', 'Missions') : title,
          showBack: true,
          body: snapshot.hasError
              ? Center(
                  child: FilledButton.tonal(
                    onPressed: () => setState(() {
                      _data = state
                          .apiFor(_server!)
                          .catalog('missions', widget.id);
                    }),
                    child: Text(t('common.actions.retry', 'Retry')),
                  ),
                )
              : mission == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: pagePadding(context),
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _categoryLabel(t, missionCategory(mission)),
                              style: theme.textTheme.labelLarge,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              title.isEmpty ? '—' : title,
                              style: theme.textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _window(
                                t,
                                groupMissions(
                                  [mission],
                                  SiteText.tupleOrder.indexOf(t.locale),
                                ).single,
                              ),
                            ),
                            if (t.text(mission['description']).isNotEmpty) ...[
                              const SizedBox(height: 16),
                              Text(t.text(mission['description'])),
                            ],
                            const SizedBox(height: 16),
                            _goal(t, mission),
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final reward
                                    in (mission['rewards'] as List? ?? const [])
                                        .whereType<Map>())
                                  RewardChip(reward),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}
