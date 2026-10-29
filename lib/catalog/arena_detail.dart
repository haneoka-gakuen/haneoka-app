import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../shell/links.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/tile.dart' show pagePadding;
import '../ui/detail.dart';
import '../team_builder/engine/num.dart';

String arenaTime(int value, String locale) {
  final date = DateTime.fromMillisecondsSinceEpoch(value),
      offset = DateTime.fromMillisecondsSinceEpoch(value)
          .timeZoneOffset
          .inMinutes;
  return '${DateFormat.yMd(locale).add_Hm().format(date)} UTC${offset >= 0 ? '+' : '−'}${(offset.abs() ~/ 60).toString().padLeft(2, '0')}:${(offset.abs() % 60).toString().padLeft(2, '0')}';
}

bool _contains(Doc row, int now) =>
    intOf(row['startAt']) <= now && now < intOf(row['endAt']) + 1000;
Doc? _rule(Doc season, Doc league, int now) => !_contains(season, now)
    ? null
    : dataRows(league['rules']).reversed
          .where((r) => _contains(r, now))
          .firstOrNull;
List<({int start, int end, List<Doc?> rules})> arenaPeriods(Doc season) {
  final leagues = dataRows(season['leagues']);
  final times = {
    for (final league in leagues)
      for (final rule in dataRows(league['rules'])) ...[
        intOf(rule['startAt']),
        intOf(rule['endAt']) + 1000,
      ],
  }.toList()..sort();
  return [
    for (var i = 0; i + 1 < times.length; i++)
      if (leagues.any((l) => _rule(season, l, times[i]) != null))
        (
          start: times[i],
          end: times[i + 1],
          rules: [for (final l in leagues) _rule(season, l, times[i])],
        ),
  ];
}

class ArenaScreen extends StatefulWidget {
  const ArenaScreen({super.key, this.server, this.seasonId, this.anchor = ''});
  final String? server, seasonId;
  final String anchor;
  @override
  State<ArenaScreen> createState() => _ArenaScreenState();
}

class _ArenaScreenState extends State<ArenaScreen> with WidgetsBindingObserver {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _schedule(List<Doc> seasons) {
    _timer?.cancel();
    final now = DateTime.now().millisecondsSinceEpoch;
    final times = [
      for (final season in seasons) ...[
        intOf(season['startAt']),
        intOf(season['endAt']) + 1000,
        for (final period in arenaPeriods(season)) ...[
          period.start,
          period.end,
        ],
      ],
    ].where((v) => v > now).toList()..sort();
    if (times.isNotEmpty) {
      _timer = Timer(
        Duration(milliseconds: (times.first - now + 20).clamp(1, 2147483647)),
        () {
          if (mounted) setState(() {});
        },
      );
    }
  }

  Future<Object?>? _data;
  Object? _key;
  String? _selected;
  late String _anchor = widget.anchor;
  void _load() {
    final state = AppScope.of(context);
    _data = state
        .apiFor(widget.server ?? state.server)
        .json(
          '/api/v1/servers/${widget.server ?? state.server}/arena?projection=2',
        );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final key = (AppScope.of(context).publicDataKey, widget.server);
    if (key != _key) {
      _key = key;
      _selected = null;
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context), text = state.text;
    return FutureBuilder(
      future: _data,
      builder: (context, snapshot) {
        final data = objectRow(snapshot.data),
            seasons = dataRows(data['entries'])
              ..sort(
                (a, b) => intOf(a['startAt']).compareTo(intOf(b['startAt'])),
              );
        _schedule(seasons);
        final now = DateTime.now().millisecondsSinceEpoch;
        final id = _selected ?? widget.seasonId ?? widget.anchor;
        final periodId = int.tryParse(
          widget.anchor.replaceFirst('arena-period-', ''),
        );
        final selected =
            seasons
                .where(
                  (s) =>
                      s['id'] == id ||
                      _selected == null &&
                          periodId != null &&
                          arenaPeriods(s).any((p) => p.start == periodId),
                )
                .firstOrNull ??
            seasons.where((s) => _contains(s, now)).firstOrNull ??
            seasons.firstOrNull;
        final index = selected == null ? -1 : seasons.indexOf(selected);
        void choose(Doc season, {String anchor = ''}) => setState(() {
          _selected = '${season['id']}';
          _anchor = anchor;
        });
        final current = seasons.where((s) => _contains(s, now)).firstOrNull;
        final period = current == null
            ? null
            : arenaPeriods(current)
                  .where((p) => p.start <= now && now < p.end)
                  .firstOrNull;
        return ShellPage(
          title: text('navigation.arena'),
          actions: [
            if (current != null && period != null)
              BarAction(
                icon: Symbols.today_rounded,
                label: text('catalog.arena.currentRule'),
                onPressed: () =>
                    choose(current, anchor: 'arena-period-${period.start}'),
              ),
            BarAction(
              icon: Symbols.calendar_month_rounded,
              label: text('tools.calendar.title'),
              onPressed: () => openLink(
                context,
                Uri(
                  path:
                      '/${widget.server ?? state.server}/${text.locale}/calendar/',
                  queryParameters: {
                    'kinds': 'arena,arena-rotation,event',
                    'view': 'agenda',
                  },
                ).toString(),
              ),
            ),
            BarAction(
              icon: Symbols.refresh_rounded,
              label: text('common.actions.refresh'),
              onPressed: () => setState(_load),
            ),
          ],
          body: selected == null
              ? Center(
                  child: snapshot.connectionState == ConnectionState.waiting
                      ? const CircularProgressIndicator()
                      : Text(text('common.states.unavailable')),
                )
              : ListView(
                  padding: pagePadding(context),
                  children: [
                    Row(
                      children: [
                        IconButton(
                          tooltip: text('catalog.arena.previousSeason'),
                          onPressed: index > 0
                              ? () => choose(seasons[index - 1])
                              : null,
                          icon: const Icon(Symbols.chevron_left_rounded),
                        ),
                        Expanded(
                          child: Text(
                            text.text(selected['title']),
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          tooltip: text('catalog.arena.nextSeason'),
                          onPressed: index + 1 < seasons.length
                              ? () => choose(seasons[index + 1])
                              : null,
                          icon: const Icon(Symbols.chevron_right_rounded),
                        ),
                      ],
                    ),
                    ArenaDetail(
                      key: ValueKey((selected['id'], _anchor)),
                      season: selected,
                      server:
                          '${objectRow(data['identity'])['server'] ?? state.server}',
                      images: objectRow(data['images']),
                      anchor: _anchor,
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class ArenaDetail extends StatefulWidget {
  const ArenaDetail({
    super.key,
    required this.season,
    this.server,
    this.images = const {},
    this.anchor = '',
  });
  final Doc season, images;
  final String? server;
  final String anchor;
  @override
  State<ArenaDetail> createState() => _ArenaDetailState();
}

class _ArenaDetailState extends State<ArenaDetail> with WidgetsBindingObserver {
  Timer? _timer;
  final _anchors = <int, GlobalKey>{};
  bool _positioned = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _schedule();
  }

  @override
  void didUpdateWidget(ArenaDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(() {});
      _schedule();
    }
  }

  void _schedule() {
    _timer?.cancel();
    final now = DateTime.now().millisecondsSinceEpoch;
    final times = [
      intOf(widget.season['startAt']),
      intOf(widget.season['endAt']) + 1000,
      for (final league in dataRows(widget.season['leagues'])) ...[
        for (final rule in dataRows(league['rules'])) ...[
          intOf(rule['startAt']),
          intOf(rule['endAt']) + 1000,
        ],
        for (final song in dataRows(league['songs']))
          intOf(song['arenaPublishedAt']),
      ],
    ].where((v) => v > now).toList()..sort();
    if (times.isNotEmpty) {
      _timer = Timer(
        Duration(milliseconds: (times.first - now + 20).clamp(1, 2147483647)),
        () {
          if (mounted) {
            setState(() {});
            _schedule();
          }
        },
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context),
        text = state.text,
        theme = Theme.of(context),
        season = widget.season;
    final server = widget.server ?? state.server,
        leagues = dataRows(season['leagues']),
        now = DateTime.now().millisecondsSinceEpoch;
    String t(String key) => text('catalog.arena.$key');
    String href(String kind, Object? id) =>
        '/$server/${text.locale}/$kind/$id/';
    Widget art(Object? source, {double size = 24}) => SizedBox(
      width: size,
      height: size,
      child: AppImage(candidates: [state.api.asset('$source').toString()]),
    );
    String mission(int id) =>
        ['', 'COMBO', 'LUCK', 'JUST'].elementAtOrNull(id) ?? t('originalRule');
    String missionText(List<int> ids) {
      final names = ids
          .map((id) => id == 0 ? t('originalRule') : mission(id))
          .toList();
      return names.toSet().length == 1
          ? '${names.first} ×${names.length}'
          : names.join(' / ');
    }

    String attribute(int id) => id == 0
        ? t('originalRule')
        : id == 99
        ? text('tools.teamBuilder.arena.any')
        : text(
            'catalog.songs.liveTypes.${['', 'red', 'blue', 'green', 'yellow', 'purple'].elementAtOrNull(id)}',
          );
    Widget ruleView(Doc? rule) => rule == null
        ? const Text('—')
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                attribute(intOf(rule['musicType'])),
                style: theme.textTheme.labelMedium,
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final id in intListOf(rule['missions']).toSet()) ...[
                    if (objectRow(widget.images['missions'])['$id']
                        case final source?)
                      art(source),
                    Text(
                      '${id == 0 ? t('originalRule') : mission(id)}${intListOf(rule['missions']).toSet().length == 1 ? ' ×3' : ''}',
                      style: theme.textTheme.labelSmall,
                    ),
                  ],
                ],
              ),
            ],
          );
    Widget link(Doc row, {String? target, String? subtitle}) {
      final source = row['image'] ?? row['jacketThumbUrl'] ?? row['jacketUrl'];
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: source == null ? null : art(source, size: 48),
        title: Text(
          text.text(row['name'] ?? row['title'] ?? row['musicTitle']),
        ),
        subtitle: subtitle == null ? null : Text(subtitle),
        trailing: row['count'] is num
            ? Text(
                '×${NumberFormat.decimalPattern(text.locale).format(row['count'])}',
              )
            : null,
        onTap: target == null ? null : () => openLink(context, target),
      );
    }

    Widget rewards(List<Doc> rows) => Column(
      children: [
        for (final row in rows)
          link(
            row,
            target: intOf(row['resourceType']) == 1
                ? href('items', row['resourceId'])
                : null,
          ),
      ],
    );
    final periods = arenaPeriods(season);
    if (!_positioned && widget.anchor.startsWith('arena-period-')) {
      _positioned = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final key =
            _anchors[int.tryParse(
              widget.anchor.replaceFirst('arena-period-', ''),
            )];
        if (key?.currentContext case final context?) {
          Scrollable.ensureVisible(context, alignment: .5);
        }
      });
    }
    final rewardGroups = <String, List<Doc>>{};
    for (final row in dataRows(season['seasonRewards'])) {
      final range = '${row['from']}–${row['to']}';
      (rewardGroups[range] ??= []).add(row);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailSection(
          icon: Symbols.event_rounded,
          title: t('period'),
          child: SpecList(
            facts: [
              Fact(
                text('catalog.systems.common.starts'),
                arenaTime(intOf(season['startAt']), text.locale),
              ),
              Fact(
                text('catalog.systems.common.ends'),
                arenaTime(intOf(season['endAt']), text.locale),
              ),
            ],
          ),
        ),
        DetailSection(
          icon: Symbols.schedule_rounded,
          title: t('schedule'),
          count: periods.length,
          child: periods.isEmpty
              ? Text(t('noSchedule'))
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columnSpacing: 16,
                    dataRowMinHeight: 88,
                    dataRowMaxHeight: 112,
                    columns: [
                      DataColumn(label: Text(t('period'))),
                      for (final league in leagues)
                        DataColumn(
                          label: SizedBox(
                            width: 112,
                            child: Row(
                              children: [
                                art(league['image']),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(text.text(league['name'])),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                    rows: [
                      for (final p in periods)
                        DataRow(
                          color: p.start <= now && now < p.end
                              ? WidgetStatePropertyAll(
                                  theme.colorScheme.secondaryContainer,
                                )
                              : null,
                          cells: [
                            DataCell(
                              SizedBox(
                                key: _anchors.putIfAbsent(
                                  p.start,
                                  () => GlobalKey(),
                                ),
                                width: 184,
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(arenaTime(p.start, text.locale)),
                                    Text('– ${arenaTime(p.end, text.locale)}'),
                                    if (p.start <= now && now < p.end)
                                      Text(
                                        t('currentRule'),
                                        style: theme.textTheme.labelSmall,
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            for (final rule in p.rules)
                              DataCell(
                                SizedBox(width: 112, child: ruleView(rule)),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
        ),
        DetailSection(
          icon: Symbols.library_music_rounded,
          title: t('songs'),
          child: Column(
            children: [
              for (final league in leagues)
                DetailSection(
                  key: ValueKey('songs-${league['id']}'),
                  icon: Symbols.music_note_rounded,
                  title: text.text(league['name']),
                  count: dataRows(league['songs'])
                      .where((s) => intOf(s['arenaPublishedAt']) <= now)
                      .length,
                  folded: true,
                  child: Column(
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: () => openLink(
                          context,
                          Uri(
                            path: '/team-builder',
                            queryParameters: {
                              'tab': 'arena',
                              'league': '${league['id']}',
                              'server': server,
                            },
                          ).toString(),
                        ),
                        icon: const Icon(Symbols.groups_rounded),
                        label: Text(text('tools.teamBuilder.title')),
                      ),
                      for (final song in dataRows(league['songs']))
                        if (intOf(song['arenaPublishedAt']) <= now)
                          link(
                            song,
                            target: href('songs', song['musicId']),
                            subtitle: () {
                              final r = _rule(season, league, now);
                              if (r == null) return null;
                              final original = intListOf(song['arenaMissions']);
                              return missionText([
                                for (final (i, id) in intListOf(
                                  r['missions'],
                                ).indexed)
                                  id == 0 ? original[i] : id,
                              ]);
                            }(),
                          ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        DetailSection(
          icon: Symbols.redeem_rounded,
          title: t('dailyRewards'),
          count: dataRows(season['dailyRewards']).length,
          folded: true,
          child: rewards(dataRows(season['dailyRewards'])),
        ),
        DetailSection(
          icon: Symbols.leaderboard_rounded,
          title: t('promotionRewards'),
          folded: true,
          child: Column(
            children: [
              for (final league in leagues)
                DetailSection(
                  key: ValueKey('ranks-${league['id']}'),
                  icon: Symbols.leaderboard_rounded,
                  title: text.text(league['name']),
                  count: dataRows(league['ranks']).length,
                  folded: true,
                  child: Column(
                    children: [
                      for (final rank in dataRows(league['ranks']))
                        DetailSection(
                          key: ValueKey('rank-${league['id']}-${rank['id']}'),
                          icon: Symbols.military_tech_rounded,
                          title:
                              '${text.text(rank['name'])} · ${rank['points']} ${t('points')}',
                          folded: true,
                          child: rewards(
                            dataRows(league['promotionRewards'])
                                .where((r) => r['rankId'] == rank['id'])
                                .toList(),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        DetailSection(
          icon: Symbols.redeem_rounded,
          title: t('seasonRewards'),
          folded: true,
          child: Column(
            children: [
              for (final group in rewardGroups.entries)
                DetailSection(
                  icon: Symbols.redeem_rounded,
                  title: '${group.key} ${t('points')}',
                  folded: true,
                  child: rewards(group.value),
                ),
            ],
          ),
        ),
        DetailSection(
          icon: Symbols.event_rounded,
          title: t('events'),
          count: dataRows(season['events']).length,
          folded: true,
          child: Column(
            children: [
              for (final row in dataRows(season['events']))
                link(row, target: href('events', row['id'])),
            ],
          ),
        ),
        DetailSection(
          icon: Symbols.swap_horiz_rounded,
          title: t('exchange'),
          count: dataRows(season['exchanges']).length,
          folded: true,
          child: Column(
            children: [
              for (final row in dataRows(season['exchanges']))
                link(row, target: href('exchange', row['id'])),
            ],
          ),
        ),
      ],
    );
  }
}
