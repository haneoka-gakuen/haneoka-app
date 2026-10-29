import '../core/catalog_source.dart';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../shell/links.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/detail.dart';
import '../ui/theme.dart';
import '../ui/tile.dart';
import '../ui/upgrade.dart';

/// The website's studio practice calculator (`studio-workspace`): choose a
/// band, its band rank and practice level, and read the practice figures,
/// the hourly rewards and the item lottery.
class StudioScreen extends StatefulWidget {
  const StudioScreen({super.key});
  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen> {
  Future<Object?>? _data;
  Object? _dataKey;
  int? _unit;
  int? _rank;
  int? _level;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final key = CatalogSourceScope.keyOf(context);
    if (_dataKey != key) {
      _dataKey = key;
      _data = CatalogSourceScope.apiOf(context).catalog('studio');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    String text(String key, String fallback) =>
        t('catalog.studio.$key', fallback);
    return ShellPage(
      title: text('title', 'Studio Practice'),
      body: FutureBuilder(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: FilledButton.tonal(
                onPressed: () => setState(
                  () =>
                      _data = CatalogSourceScope.apiOf(context)
                          .catalog('studio'),
                ),
                child: Text(t('common.actions.retry', 'Retry')),
              ),
            );
          }
          final studio = snapshot.data as Map?;
          if (studio == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final units = (studio['units'] as List? ?? const [])
              .whereType<Map>()
              .toList();
          if (units.isEmpty) return const SizedBox.shrink();
          final unit = units.firstWhere(
            (u) => u['id'] == _unit,
            orElse: () => units.first,
          );
          final levels = (unit['levels'] as List? ?? const [])
              .whereType<Map>()
              .toList();
          final factors = (studio['expFactors'] as List? ?? const [])
              .whereType<Map>()
              .toList();
          final ranks = factors.isNotEmpty
              ? [for (final f in factors) (f['bandRank'] as num).toInt()]
              : [
                  for (
                    var r = 1;
                    r <=
                        levels.fold<int>(
                          1,
                          (m, l) => ((l['bandRank'] as num?)?.toInt() ?? 1) > m
                              ? (l['bandRank'] as num).toInt()
                              : m,
                        );
                    r++
                  )
                    r,
                ];
          final rank = ranks.contains(_rank) ? _rank! : ranks.last;
          final range = [
            for (final l in levels)
              if (((l['bandRank'] as num?) ?? 0) <= rank)
                (l['level'] as num).toInt(),
          ];
          final levelValue = range.contains(_level)
              ? _level!
              : (range.isEmpty ? 0 : range.last);
          final level = levels.firstWhere(
            (l) => l['level'] == levelValue,
            orElse: () => levels.first,
          );
          final next = levels
              .where((l) => l['level'] == levelValue + 1)
              .firstOrNull;
          final factor =
              factors.where((f) => f['bandRank'] == rank).firstOrNull?['factor']
                  as num?;
          final number = NumberFormat.decimalPattern(t.locale);
          String hours(num seconds) => t('common.time.spanHours', '{count}h', {
            'count': NumberFormat('#,##0.##', t.locale).format(seconds / 3600),
          });
          final settings = Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(Corner.extraLarge),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (units.length > 1)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final entry in units)
                        ChoiceChip(
                          avatar: entry['icon'] is String
                              ? AppImage(
                                  candidates: [
                                    CatalogSourceScope.apiOf(context)
                                        .asset(entry['icon'] as String)
                                        .toString(),
                                  ],
                                )
                              : null,
                          label: Text(t.text(entry['name'])),
                          selected: entry == unit,
                          showCheckmark: false,
                          onSelected: (_) => setState(
                            () => _unit = (entry['id'] as num).toInt(),
                          ),
                        ),
                    ],
                  ),
                const SizedBox(height: 16),
                LevelSwitch(
                  label: text('bandRank', 'Band Rank'),
                  levels: ranks,
                  value: rank,
                  onChanged: (value) => setState(() => _rank = value),
                ),
                LevelSwitch(
                  label: text('level', 'Practice Lv.'),
                  levels: range,
                  value: levelValue,
                  onChanged: (value) => setState(() => _level = value),
                ),
                const SizedBox(height: 8),
                SpecList(
                  facts: [
                    Fact(
                      text('maxLevel', 'Max Practice Lv.'),
                      range.isEmpty ? '—' : '${range.last}',
                    ),
                    if (factor != null)
                      Fact(
                        text('expFactor', 'EXP Multiplier'),
                        '×${NumberFormat('#,##0.##', t.locale).format(factor / 10000)}',
                      ),
                    Fact(
                      text('requiredExp', 'Required Practice EXP'),
                      number.format(level['exp'] ?? 0),
                    ),
                    if (next != null)
                      Fact(
                        text('nextLevel', 'To next Lv.'),
                        number.format(
                          ((next['exp'] as num?) ?? 0) -
                              ((level['exp'] as num?) ?? 0),
                        ),
                      ),
                    Fact(
                      text('practiceTime', 'Practice Time'),
                      hours((level['efficiencyTime'] as num?) ?? 0),
                    ),
                    Fact(
                      text('timeLimit', 'Practice Time Limit'),
                      hours((level['limitTime'] as num?) ?? 0),
                    ),
                  ],
                ),
              ],
            ),
          );
          final content = [
            _rewards(context, studio, level, text, hours),
            _drops(context, unit, level, text),
            if ((studio['skipItems'] as List? ?? const []).isNotEmpty)
              DetailSection(
                icon: Symbols.inventory_2_rounded,
                title: text('item', 'Item'),
                child: Column(
                  children: [
                    for (final reward
                        in (studio['skipItems'] as List).whereType<Map>())
                      _rewardRow(context, reward, text('item', 'Item')),
                  ],
                ),
              ),
            _table(context, unit, text, number),
          ];
          return LayoutBuilder(
            builder: (context, constraints) {
              final padding = pagePadding(context);
              if (constraints.maxWidth >= 900) {
                return SingleChildScrollView(
                  padding: padding,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: content,
                        ),
                      ),
                      const SizedBox(width: 24),
                      SizedBox(width: 380, child: settings),
                    ],
                  ),
                );
              }
              return ListView(
                padding: padding,
                children: [settings, const SizedBox(height: 24), ...content],
              );
            },
          );
        },
      ),
    );
  }

  Widget _rewards(
    BuildContext context,
    Map studio,
    Map level,
    String Function(String, String) text,
    String Function(num) hours,
  ) {
    final state = AppScope.of(context);
    final art = (studio['rewards'] as Map?) ?? const {};
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final number = NumberFormat.decimalPattern(state.text.locale);
    final session = ((level['efficiencyTime'] as num?) ?? 0) / 3600;
    Widget metric(String label, num value, Widget media) => Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(Corner.large),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox.square(dimension: 40, child: Center(child: media)),
              const SizedBox(width: 12),
              Expanded(child: Text(label, style: theme.textTheme.titleSmall)),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            number.format(value),
            style: theme.textTheme.headlineMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            '${hours((level['efficiencyTime'] as num?) ?? 0)} · ${number.format((value * session).round())}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
    Widget image(Object? reward, IconData fallback) => switch ((reward
        as Map?)?['image']) {
      final String path => AppImage(
        candidates: [CatalogSourceScope.apiOf(context).asset(path).toString()],
      ),
      _ => Icon(fallback, color: scheme.primary),
    };
    final metrics = [
      metric(
        text('coin', 'Coin'),
        (level['coin'] as num?) ?? 0,
        image(art['coin'], Symbols.redeem_rounded),
      ),
      metric(
        text('memberExp', 'Member EXP'),
        (level['memberExp'] as num?) ?? 0,
        image(art['memberExp'], Symbols.person_rounded),
      ),
      metric(
        text('supportExp', 'Snapshot EXP'),
        (level['supportExp'] as num?) ?? 0,
        image(art['supportExp'], Symbols.collections_rounded),
      ),
      metric(
        text('practiceExp', 'Practice EXP'),
        (level['studioExp'] as num?) ?? 0,
        Icon(Symbols.trending_up_rounded, color: scheme.primary),
      ),
      metric(
        text('lotSlots', 'Item Lottery Slot'),
        (level['draws'] as num?) ?? 0,
        Icon(Symbols.casino_rounded, color: scheme.primary),
      ),
    ];
    return DetailSection(
      icon: Symbols.schedule_rounded,
      title: text('hourlyRewards', 'Hourly Rewards'),
      large: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth >= 600 ? 3 : 2;
          final width = (constraints.maxWidth - 8 * (columns - 1)) / columns;
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in metrics) SizedBox(width: width, child: m),
            ],
          );
        },
      ),
    );
  }

  Widget _rewardRow(BuildContext context, Map reward, String subtitle) {
    final state = AppScope.of(context);
    final t = state.text;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: SizedBox.square(
        dimension: 40,
        child: reward['image'] is String
            ? AppImage(
                candidates: [
                  CatalogSourceScope.apiOf(context)
                      .asset(reward['image'] as String)
                      .toString(),
                ],
              )
            : null,
      ),
      title: Text(
        t.text(reward['name']).isEmpty
            ? '#${reward['resourceId']}'
            : t.text(reward['name']),
      ),
      subtitle: Text(subtitle),
      trailing: reward['resourceType'] == 1
          ? const Icon(Symbols.chevron_right_rounded)
          : null,
      onTap: reward['resourceType'] == 1
          ? () => openLink(
              context,
              '/${CatalogSourceScope.serverOf(context)}/${t.locale}/items/${reward['resourceId']}/',
            )
          : null,
    );
  }

  Widget _drops(
    BuildContext context,
    Map unit,
    Map level,
    String Function(String, String) text,
  ) {
    final t = AppScope.of(context).text;
    final entries =
        ((unit['drops'] as Map?)?['${level['dropGroup']}'] as List? ?? const [])
            .whereType<Map>()
            .toList()
          ..sort(
            (a, b) => ((b['weight'] as num?) ?? 0).compareTo(
              (a['weight'] as num?) ?? 0,
            ),
          );
    final total = entries.fold<num>(
      0,
      (sum, e) => sum + ((e['weight'] as num?) ?? 0),
    );
    final percent = NumberFormat.percentPattern(t.locale)
      ..maximumFractionDigits = 2;
    return DetailSection(
      icon: Symbols.casino_rounded,
      title: text('lotSlots', 'Item Lottery Slot'),
      count: entries.length,
      large: true,
      child: Column(
        children: [
          for (final entry in entries)
            _rewardRow(
              context,
              (entry['reward'] as Map?) ?? const {},
              percent.format(
                ((entry['weight'] as num?) ?? 0) / (total == 0 ? 1 : total),
              ),
            ),
        ],
      ),
    );
  }

  Widget _table(
    BuildContext context,
    Map unit,
    String Function(String, String) text,
    NumberFormat number,
  ) {
    final levels = (unit['levels'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final theme = Theme.of(context);
    final headers = [
      text('level', 'Practice Lv.'),
      text('requiredExp', 'Required Practice EXP'),
      text('bandRank', 'Band Rank'),
      text('coin', 'Coin'),
      text('memberExp', 'Member EXP'),
      text('supportExp', 'Snapshot EXP'),
      text('practiceExp', 'Practice EXP'),
      text('lotSlots', 'Item Lottery Slot'),
    ];
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: ExpansionTile(
        leading: const Icon(Symbols.table_rows_rounded),
        title: Text(text('allLevels', 'All Practice Lv.')),
        trailing: Text('${levels.length}', style: theme.textTheme.labelLarge),
        shape: const Border(),
        collapsedShape: const Border(),
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: [
                for (final h in headers)
                  DataColumn(label: Text(h), numeric: true),
              ],
              rows: [
                for (final l in levels)
                  DataRow(
                    cells: [
                      for (final key in [
                        'level',
                        'exp',
                        'bandRank',
                        'coin',
                        'memberExp',
                        'supportExp',
                        'studioExp',
                        'draws',
                      ])
                        DataCell(
                          Text(l[key] is num ? number.format(l[key]) : '—'),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
