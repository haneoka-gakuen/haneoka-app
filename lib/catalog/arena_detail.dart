import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../shell/links.dart';
import '../ui/app_image.dart';
import '../ui/detail.dart';
import '../team_builder/engine/num.dart';

class ArenaDetail extends StatefulWidget {
  const ArenaDetail({super.key, required this.season});
  final Doc season;
  @override
  State<ArenaDetail> createState() => _ArenaDetailState();
}

class _ArenaDetailState extends State<ArenaDetail> {
  Timer? _timer;
  int _league = 1;
  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(ArenaDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    final now = DateTime.now().millisecondsSinceEpoch;
    final times = [
      intOf(widget.season['startAt']),
      intOf(widget.season['endAt']) + 1000,
      for (final league in dataRows(widget.season['leagues']))
        for (final row in dataRows(league['rules'])) ...[
          intOf(row['startAt']),
          intOf(row['endAt']) + 1000,
        ],
    ].where((time) => time > now).toList()..sort();
    if (times.isNotEmpty) {
      _timer = Timer(
        Duration(milliseconds: (times.first - now + 50).clamp(1, 2147483647)),
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
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context), text = AppScope.of(context).text;
    String t(String key) => text('catalog.arena.$key', key);
    final season = widget.season, leagues = dataRows(widget.season['leagues']);
    final league =
        leagues.where((row) => row['id'] == _league).firstOrNull ??
        leagues.firstOrNull;
    final now = DateTime.now().millisecondsSinceEpoch;
    bool active(Doc row) =>
        intOf(row['startAt']) <= now && now < intOf(row['endAt']) + 1000;
    final rules = dataRows(league?['rules']);
    final current = active(season)
        ? rules.reversed.where(active).firstOrNull
        : null;
    String time(Object? value) =>
        '${DateFormat.yMd(text.locale).add_Hm().format(DateTime.fromMillisecondsSinceEpoch(intOf(value), isUtc: true).add(const Duration(hours: 9)))} JST';
    String missions(Object? value) => intListOf(value)
        .map((id) => ['', 'COMBO', 'LUCK', 'JUST'].elementAtOrNull(id) ?? '')
        .join(' · ');
    Widget link(Doc row, {String? href}) => ListTile(
      leading: '${row['image'] ?? row['jacket'] ?? ''}'.isEmpty
          ? null
          : SizedBox(
              width: 48,
              height: 48,
              child: AppImage(
                candidates: [
                  state.api
                      .asset('${row['image'] ?? row['jacket']}')
                      .toString(),
                ],
              ),
            ),
      title: Text(text.text(row['name'] ?? row['title'] ?? row['musicTitle'])),
      subtitle: row['count'] is num ? Text('×${row['count']}') : null,
      onTap: (href ?? row['href']) is String
          ? () => openLink(context, '${href ?? row['href']}')
          : null,
    );
    Widget rewards(String title, List<Doc> rows) => DetailSection(
      icon: Symbols.redeem_rounded,
      title: title,
      count: rows.length,
      folded: true,
      child: Column(
        children: [
          for (final row in rows)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (row['rankId'] != null)
                  Text(
                    '${text.label('rank')} ${row['rankId']}${intOf(row['from']) > 0 ? ' · ${row['from']}–${row['to']}' : ''}',
                  ),
                link(row),
              ],
            ),
        ],
      ),
    );
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
                time(season['startAt']),
              ),
              Fact(text('catalog.systems.common.ends'), time(season['endAt'])),
            ],
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final row in leagues)
              ChoiceChip(
                label: Text(text.text(row['name'])),
                selected: identical(row, league),
                onSelected: (_) => setState(() => _league = intOf(row['id'])),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (league != null) ...[
          DetailSection(
            icon: Symbols.swords_rounded,
            title: t('currentRule'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  current == null
                      ? t('noSchedule')
                      : '${text('tools.teamBuilder.arena.attribute', 'Song Type')}: ${intOf(current['musicType']) == 0
                            ? text('tools.teamBuilder.arena.original', 'Original song')
                            : intOf(current['musicType']) == 99
                            ? text('tools.teamBuilder.arena.any')
                            : text('catalog.songs.liveTypes.${['', 'red', 'blue', 'green', 'yellow', 'purple'][intOf(current['musicType'])]}')} · ${missions(current['missions'])}',
                ),
                FilledButton.icon(
                  onPressed: () => openLink(
                    context,
                    Uri(
                      path: '/team-builder',
                      queryParameters: {
                        'tab': 'arena',
                        'league': '${league['id']}',
                      },
                    ).toString(),
                  ),
                  icon: const Icon(Symbols.groups_rounded),
                  label: Text(text('tools.teamBuilder.title', 'Team builder')),
                ),
              ],
            ),
          ),
          DetailSection(
            icon: Symbols.schedule_rounded,
            title: t('schedule'),
            count: rules.length,
            folded: true,
            child: Column(
              children: [
                for (final row in rules)
                  ListTile(
                    selected: identical(row, current),
                    title: Text(
                      '${time(row['startAt'])} – ${time(row['endAt'])}',
                    ),
                    subtitle: Text(
                      '${row['musicType'] == 0 ? text('tools.teamBuilder.arena.original', 'Original song') : row['musicType']} · ${missions(row['missions'])}',
                    ),
                  ),
              ],
            ),
          ),
          DetailSection(
            icon: Symbols.library_music_rounded,
            title: t('songs'),
            count: dataRows(league['songs']).length,
            folded: true,
            child: Column(
              children: [
                for (final row in dataRows(league['songs']))
                  if (intOf(row['arenaPublishedAt']) <= now)
                    link(
                      row,
                      href:
                          '/${state.server}/${text.locale}/songs/${row['musicId'] ?? row['id']}/',
                    ),
              ],
            ),
          ),
          DetailSection(
            icon: Symbols.leaderboard_rounded,
            title: t('points'),
            folded: true,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: [
                  DataColumn(label: Text(text.label('rank'))),
                  DataColumn(label: Text(t('points')), numeric: true),
                ],
                rows: [
                  for (final row in dataRows(league['ranks']))
                    DataRow(
                      cells: [
                        DataCell(
                          Text(
                            '${text.text(row['name'])} ${row['division'] ?? ''}',
                          ),
                        ),
                        DataCell(Text('${row['points']}')),
                      ],
                    ),
                ],
              ),
            ),
          ),
          rewards(t('promotionRewards'), dataRows(league['promotionRewards'])),
        ],
        rewards(t('dailyRewards'), dataRows(season['dailyRewards'])),
        rewards(t('seasonRewards'), dataRows(season['seasonRewards'])),
        DetailSection(
          icon: Symbols.event_rounded,
          title: t('events'),
          folded: true,
          child: Column(
            children: [for (final row in dataRows(season['events'])) link(row)],
          ),
        ),
        DetailSection(
          icon: Symbols.swap_horiz_rounded,
          title: t('exchange'),
          folded: true,
          child: Column(
            children: [
              for (final row in dataRows(season['exchanges'])) link(row),
            ],
          ),
        ),
      ],
    );
  }
}
