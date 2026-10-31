import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../catalog/profiles.dart';
import '../core/app_state.dart';
import '../save/account_store.dart';
import '../save/save_view.dart';
import '../shell/page.dart';
import '../shell/routes.dart';
import '../ui/app_image.dart';
import '../ui/detail.dart';
import '../ui/theme.dart';
import '../ui/tile.dart';

const _difficulties = ['easy', 'normal', 'hard', 'expert', 'special'];

class _Chart {
  _Chart(this.song, this.songId, this.difficulty, this.level, this.levelText);
  final Map<String, Object?> song;
  final int songId;
  final int difficulty;
  final num level;
  final String levelText;
  String get key => 'l.$songId.$difficulty';
}

/// Chart progress kept on this device per release (`l.<song>.<difficulty>`
/// → 1 cleared, 2 full combo, 3 all perfect), as the website's team box.
class _Store {
  _Store(this.server);
  final String server;
  Map<String, int> values = {};

  Future<File> _file() async {
    final root = await getApplicationSupportDirectory();
    return File(p.join(root.path, 'song-progress-$server.json'));
  }

  Future<bool> load() async {
    final file = await _file();
    if (!await file.exists()) return false;
    try {
      values = (jsonDecode(await file.readAsString()) as Map).map(
        (key, value) => MapEntry('$key', (value as num).toInt()),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> save() async =>
      (await _file()).writeAsString(jsonEncode(values));
}

/// The game's clear status (`_<difficulty>ClearedStatus`: 10 clear,
/// 20 full combo, 30 all perfect) as a progress mark.
int _mark(Object? status) {
  final value = status is num ? status : 0;
  return value >= 30
      ? 3
      : value >= 20
      ? 2
      : value >= 10
      ? 1
      : 0;
}

/// Song progress (`song-progress`): clear, full combo and all perfect per
/// chart, filled from an imported save and editable by hand.
class SongProgressScreen extends StatefulWidget {
  const SongProgressScreen({super.key});
  @override
  State<SongProgressScreen> createState() => _SongProgressScreenState();
}

class _SongProgressScreenState extends State<SongProgressScreen> {
  Future<List<_Chart>>? _charts;
  _Store? _store;
  int _difficulty = 3;
  String _filter = 'all';
  String _query = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    if (_store?.server != state.server) {
      _store = _Store(state.server);
      _charts = _load(state);
    }
  }

  Future<List<_Chart>> _load(AppState state) async {
    final store = _store!;
    final (songs, known, _) = await (
      state.api.catalog('songs'),
      store.load(),
      AccountStore.instance.load(),
    ).wait;
    if (!known) _fill(silent: true);
    final charts = <_Chart>[];
    for (final song in ((songs as Map?) ?? const {}).values.whereType<Map>()) {
      final songId = (song['musicId'] as num?)?.toInt() ?? 0;
      for (final (index, row)
          in (song['difficulty'] as List? ?? const [])
              .whereType<Map>()
              .indexed) {
        final difficulty = ((row['difficulty'] ?? index) as num).toInt();
        final level =
            (row['sortLevel'] ?? row['playLevel'] ?? row['displayLevel'] ?? 0)
                as num;
        if (songId == 0 || level == 0) continue;
        charts.add(
          _Chart(
            song.cast<String, Object?>(),
            songId,
            difficulty,
            level,
            '${row['displayLevel'] ?? row['playLevel'] ?? level}'.replaceAll(
              RegExp(r'\.0$'),
              '',
            ),
          ),
        );
      }
    }
    return charts;
  }

  /// Takes every chart's status from the newest imported save of this
  /// release; returns whether there was one.
  bool _fill({bool silent = false}) {
    final store = _store!;
    final save = AccountStore.instance.saves
        .where((s) => (s.server ?? '') == store.server)
        .firstOrNull;
    if (save == null) return false;
    final values = <String, int>{};
    for (final row in SaveView(save).rows(SaveSection.songs)) {
      final id = row['_mLiveMusicId'];
      for (final (index, name) in _difficulties.take(4).indexed) {
        final mark = _mark(row['_${name}ClearedStatus']);
        if (mark > 0) values['l.$id.$index'] = mark;
      }
    }
    store.values = values;
    store.save();
    if (!silent && mounted) {
      setState(() {});
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(save.name ?? save.profileId)));
    }
    return true;
  }

  int _status(_Chart chart) => _store?.values[chart.key] ?? 0;

  void _set(_Chart chart, int value) {
    setState(() {
      if (value == 0) {
        _store!.values.remove(chart.key);
      } else {
        _store!.values[chart.key] = value;
      }
    });
    _store!.save();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    String text(String key, String fallback) =>
        t('catalog.songProgress.$key', fallback);
    String status(int value) => text(
      const ['notCleared', 'cleared', 'fullCombo', 'allPerfect'][value],
      const ['Not cleared', 'Cleared', 'FULL COMBO', 'ALL PERFECT'][value],
    );
    final hasSave = AccountStore.instance.saves.any(
      (s) => s.server == state.server,
    );
    return ShellPage(
      title: text('title', 'Song progress'),
      search: ShellSearch(
        label: t('common.actions.search', 'Search'),
        onChanged: (value) =>
            setState(() => _query = value.trim().toLowerCase()),
      ),
      actions: [
        if (hasSave)
          BarAction(
            icon: Symbols.sync_rounded,
            label: AppScope.of(context).text('navigation.account', 'Account'),
            onPressed: _fill,
          ),
      ],
      body: FutureBuilder(
        future: _charts,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: FilledButton.tonal(
                onPressed: () => setState(() => _charts = _load(state)),
                child: Text(t('common.actions.retry', 'Retry')),
              ),
            );
          }
          final all = snapshot.data;
          if (all == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final present = [
            for (final (index, name) in _difficulties.indexed)
              if (all.any((c) => c.difficulty == (index == 4 ? 5 : index)))
                (index == 4 ? 5 : index, name),
          ];
          final charts = all.where((c) => c.difficulty == _difficulty).toList();
          final shown =
              charts
                  .where(
                    (c) => _filter == 'all' || _status(c) == int.parse(_filter),
                  )
                  .where(
                    (c) =>
                        _query.isEmpty ||
                        state
                            .songTitle(c.song['musicTitle'])
                            .toLowerCase()
                            .contains(_query) ||
                        t
                            .text(c.song['bandName'])
                            .toLowerCase()
                            .contains(_query),
                  )
                  .toList()
                ..sort((a, b) {
                  final level = b.level.compareTo(a.level);
                  return level != 0
                      ? level
                      : state
                            .songTitle(a.song['musicTitle'])
                            .compareTo(state.songTitle(b.song['musicTitle']));
                });
          int reached(List<_Chart> list, int value) =>
              list.where((c) => _status(c) >= value).length;
          final percent = NumberFormat.percentPattern(t.locale);
          final levels = {for (final c in charts) c.levelText}.toList()
            ..sort(
              (a, b) => (num.tryParse(b) ?? 0).compareTo(num.tryParse(a) ?? 0),
            );

          final side = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<int>(
                showSelectedIcon: false,
                segments: [
                  for (final (value, name) in present)
                    ButtonSegment(
                      value: value,
                      label: Text(name.toUpperCase()),
                    ),
                ],
                selected: {_difficulty},
                onSelectionChanged: (value) =>
                    setState(() => _difficulty = value.single),
              ),
              const SizedBox(height: 24),
              DetailSection(
                icon: Symbols.monitoring_rounded,
                title: text('summary', 'Summary'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SpecList(
                      facts: [
                        for (final value in [1, 2, 3])
                          Fact(
                            status(value),
                            '${reached(charts, value)} / ${charts.length}  ${percent.format(reached(charts, value) / (charts.isEmpty ? 1 : charts.length))}',
                          ),
                      ],
                    ),
                    DetailFold(
                      title: text('byLevel', 'By level'),
                      meta: '${levels.length}',
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          headingRowHeight: 40,
                          dataRowMinHeight: 36,
                          dataRowMaxHeight: 36,
                          columns: [
                            DataColumn(
                              label: Text(t('common.fields.level', 'Level')),
                              numeric: true,
                            ),
                            DataColumn(
                              label: Text(text('charts', 'Charts')),
                              numeric: true,
                            ),
                            for (final value in [1, 2, 3])
                              DataColumn(
                                label: Text(status(value)),
                                numeric: true,
                              ),
                          ],
                          rows: [
                            for (final level in levels)
                              () {
                                final row = charts
                                    .where((c) => c.levelText == level)
                                    .toList();
                                return DataRow(
                                  cells: [
                                    DataCell(Text(level)),
                                    DataCell(Text('${row.length}')),
                                    for (final value in [1, 2, 3])
                                      DataCell(Text('${reached(row, value)}')),
                                  ],
                                );
                              }(),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
          final songsProfile = catalogProfiles.firstWhere(
            (p) => p.resource == 'songs',
          );
          final list = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final value in ['all', '0', '1', '2', '3'])
                    FilterChip(
                      showCheckmark: false,
                      selected: _filter == value,
                      label: Text(
                        '${value == 'all' ? t('common.states.all', 'All') : status(int.parse(value))}  ${value == 'all' ? charts.length : charts.where((c) => _status(c) == int.parse(value)).length}',
                      ),
                      onSelected: (_) => setState(() => _filter = value),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              for (final chart in shown)
                _Row(
                  chart: chart,
                  status: _status(chart),
                  label: status,
                  onSet: (value) => _set(chart, value),
                  onOpen: () => openEntity(context, songsProfile, chart.song),
                ),
              if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    t('common.states.empty', 'Nothing here'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          );
          return LayoutBuilder(
            builder: (context, constraints) {
              final padding = pagePadding(context);
              if (constraints.maxWidth < 840) {
                return ListView(
                  padding: padding,
                  children: [side, const SizedBox(height: 24), list],
                );
              }
              return SingleChildScrollView(
                padding: padding,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 360, child: side),
                    const SizedBox(width: 24),
                    Expanded(child: list),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.chart,
    required this.status,
    required this.label,
    required this.onSet,
    required this.onOpen,
  });
  final _Chart chart;
  final int status;
  final String Function(int) label;
  final ValueChanged<int> onSet;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 600;
    final jacket = chart.song['jacketUrl'] ?? chart.song['jacketThumbUrl'];
    final color = difficultyColors[chart.difficulty.clamp(0, 4)];
    final song = InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(Corner.small),
              child: SizedBox.square(
                dimension: 48,
                child: jacket is String
                    ? AppImage(
                        candidates: [state.api.asset(jacket).toString()],
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    state.songTitle(chart.song['musicTitle']),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge,
                  ),
                  Text(
                    state.text.text(chart.song['bandName']),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    final level = Container(
      width: compact ? 36 : 40,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(Corner.small),
      ),
      child: Text(
        chart.levelText,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    final marks = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final value in [1, 2, 3])
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Tooltip(
              message: label(value),
              child: Material(
                color: status == value
                    ? switch (value) {
                        1 => scheme.secondaryContainer,
                        2 => scheme.tertiaryContainer,
                        _ => scheme.primary,
                      }
                    : Colors.transparent,
                shape: RoundedRectangleBorder(
                  side: status == value
                      ? BorderSide.none
                      : BorderSide(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(Corner.small),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(Corner.small),
                  onTap: () => onSet(status == value ? 0 : value),
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 48),
                    height: 32,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      const ['', 'CLEAR', 'FC', 'AP'][value],
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.24,
                        color: status == value
                            ? switch (value) {
                                1 => scheme.onSecondaryContainer,
                                2 => scheme.onTertiaryContainer,
                                _ => scheme.onPrimary,
                              }
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: compact
          ? Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    children: [
                      Expanded(child: song),
                      const SizedBox(width: 12),
                      level,
                    ],
                  ),
                  marks,
                ],
              ),
            )
          : ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 64),
              child: Row(
                children: [
                  Expanded(child: song),
                  const SizedBox(width: 12),
                  level,
                  const SizedBox(width: 12),
                  marks,
                ],
              ),
            ),
    );
  }
}
