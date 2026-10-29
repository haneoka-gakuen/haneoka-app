import 'dart:math' as math;

import 'package:game_data_exporter/gacha_history_analysis.dart'
    show summarizeGachaHistoryMoney;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';

import 'package:material_new_shapes/material_new_shapes.dart';

import '../ui/detail.dart';
import '../ui/shapes.dart';
import '../ui/theme.dart';
import '../ui/gacha_prize_card.dart';
import 'history_view.dart';
import 'history_report.dart';
import 'history_chart.dart';

/// The gacha history page (`lit/gacha-history.ts`): the game account and its
/// headline figures, then overview, pools, collection, records, trends and
/// settings tabs.
class GachaHistoryScreen extends StatefulWidget {
  const GachaHistoryScreen({
    super.key,
    this.cloudSignedIn = false,
    this.cloudBusy = false,
    this.cloudLinked = false,
    this.cloudRefreshPending = false,
    this.cloudErrorCode = "",
    this.onCloudLink,
    this.onCloudSync,
    this.onCloudRefresh,
    this.accounts = const [],
    this.historyKinds = const [],
    this.selectedHistoryKind = '',
    this.onHistoryKindChanged,
    this.pools = const [],
    this.batches = const [],
    this.selectedAccountKey = '',
    this.busy = false,
    this.historyLoaded = false,
    this.catalogLoading = false,
    this.catalogError,
    this.onCatalogRetry,
    this.error,
    this.onAccountChanged,
    this.onImport,
    this.onRefresh,
    this.onExport,
    this.onOpenCard,
    this.currencyConversion,
    this.onConversionChanged,
    this.onExportImage,
    this.initialTab,
  });
  final bool cloudSignedIn, cloudBusy, cloudLinked, cloudRefreshPending;
  final String? cloudErrorCode;
  final ValueChanged<bool>? onCloudLink;
  final VoidCallback? onCloudSync, onCloudRefresh;
  final List<GachaHistoryAccount> accounts;
  final List<GachaHistoryPool> pools;
  final List<GachaHistoryBatch> batches;
  final String selectedAccountKey;
  final bool busy, historyLoaded, catalogLoading;
  final String? catalogError;
  final VoidCallback? onCatalogRetry;
  final String? error;
  final ValueChanged<String>? onAccountChanged,
      onRefresh,
      onOpenCard,
      onHistoryKindChanged;
  final List<String> historyKinds;
  final String selectedHistoryKind;
  final VoidCallback? onImport;
  final ValueChanged<GachaHistoryExport>? onExport;
  final GachaHistoryConversion? currencyConversion;
  final ValueChanged<GachaHistoryConversion>? onConversionChanged;
  final GachaHistoryImageExporter? onExportImage;

  /// `overview`, `pools`, `collection`, `records`, `trends` or `settings`,
  /// as the site's `#fragment`.
  final String? initialTab;

  @override
  State<GachaHistoryScreen> createState() => _GachaHistoryScreenState();
}

const _tabs = [
  'overview',
  'pools',
  'collection',
  'records',
  'trends',
  'settings',
];
const _high = {4, 10, 20};
bool _isHigh(GachaHistoryPrize prize) =>
    (prize.kind == 'member' || prize.kind == 'support') &&
    _high.contains(int.tryParse('${prize.rarity}'));
int _rarityRank(Object rarity) =>
    const {20: 5, 10: 4, 4: 3, 3: 2, 2: 1}[int.tryParse('$rarity')] ?? 0;

class _Collected {
  _Collected(this.key, this.prize);
  final String key;
  final GachaHistoryPrize prize;
  int count = 0, pickup = 0, converted = 0;
  final pools = <String>{};
  DateTime? last;
}

class _GachaHistoryScreenState extends State<GachaHistoryScreen> {
  late String _tab = _tabs.contains(widget.initialTab)
      ? widget.initialTab!
      : 'overview';

  final _filters = <String, Set<String>>{
    'category': {},
    'pool': {},
    'kind': {},
    'rarity': {},
    'pickup': {},
  };
  final _expanded = <String>{};
  bool _expansionReady = false;
  List<GachaHistoryPool>? _indexedPools;
  Map<String, GachaHistoryPool> _poolIndex = {};
  String _query = '', _view = 'grid', _albumKind = 'all';
  bool _oldest = false, _onlyPickup = false, _allCards = false;
  DateTime? _from, _to;
  String _t(String key, [Map<String, Object?> values = const {}]) =>
      AppScope.of(context).text('catalog.gachaHistory.$key', '', values);
  String get _locale => AppScope.of(context).text.locale;
  String _percent(num value, num total) =>
      total == 0 ? "—" : NumberFormat("0.##%", _locale).format(value / total);
  String _number(num value) =>
      NumberFormat.decimalPattern(_locale).format(value);
  int get _offsetMinutes {
    final account = widget.accounts
        .where((row) => row.key == widget.selectedAccountKey)
        .firstOrNull;
    return account?.offsetMinutes ??
        ({
              'jp': 540,
              'global-hmt': 480,
              'global-en': 0,
              'global-kr': 540,
            }[account?.server] ??
            480);
  }

  DateTime _inServerTime(DateTime date) =>
      date.toUtc().add(Duration(minutes: _offsetMinutes));
  String _filterDay(DateTime date) => DateFormat('yyyy-MM-dd').format(date);
  Map<String, Object?> _analysisData(List<GachaHistoryBatch> batches) =>
      historyAnalysis(batches, _offsetMinutes);
  String _day(DateTime? date) => date == null
      ? "unknown"
      : DateFormat('yyyy-MM-dd').format(_inServerTime(date));
  Map<String, GachaHistoryPool> get _pools {
    if (!identical(_indexedPools, widget.pools)) {
      _indexedPools = widget.pools;
      _poolIndex = {for (final pool in widget.pools) pool.id: pool};
    }
    return _poolIndex;
  }

  List<GachaHistoryBatch> get _accountBatches => widget.batches
      .where((batch) => batch.accountKey == widget.selectedAccountKey)
      .toList();
  bool _matches(String axis, String value) =>
      _filters[axis]!.isEmpty || _filters[axis]!.contains(value);
  List<GachaHistoryPrize> _prizes(GachaHistoryBatch batch) {
    final query = _query.trim().toLowerCase();
    final poolMatches = (_pools[batch.poolId]?.name ?? '')
        .toLowerCase()
        .contains(query);
    return batch.prizes
        .where(
          (prize) =>
              _matches(
                'pickup',
                prize.pickup == null
                    ? 'unknown'
                    : prize.pickup!
                    ? 'yes'
                    : 'no',
              ) &&
              _matches('kind', prize.kind) &&
              _matches('rarity', '${prize.rarity}') &&
              (query.isEmpty ||
                  poolMatches ||
                  prize.name.toLowerCase().contains(query)),
        )
        .toList();
  }

  List<GachaHistoryBatch> get _scoped => _accountBatches.where((batch) {
    final day = _day(batch.pulledAt);
    return _matches('pool', batch.poolId) &&
        _matches('category', _pools[batch.poolId]?.category ?? '') &&
        (_from == null ||
            (batch.pulledAt != null &&
                day.compareTo(_filterDay(_from!)) >= 0)) &&
        (_to == null ||
            (batch.pulledAt != null && day.compareTo(_filterDay(_to!)) <= 0));
  }).toList();
  List<GachaHistoryBatch> get _filtered {
    final result = _scoped
        .where(
          (batch) =>
              (_query.trim().isEmpty &&
                  _filters['kind']!.isEmpty &&
                  _filters['rarity']!.isEmpty &&
                  _filters['pickup']!.isEmpty) ||
              _prizes(batch).isNotEmpty,
        )
        .toList();
    final order = {for (var i = 0; i < result.length; i++) result[i]: i};
    result.sort((a, b) {
      if (a.pulledAt == null) {
        return b.pulledAt == null ? order[a]! - order[b]! : 1;
      }
      if (b.pulledAt == null) return -1;
      final timeOrder = a.pulledAt!.compareTo(b.pulledAt!);
      return timeOrder == 0
          ? order[a]! - order[b]!
          : timeOrder * (_oldest ? 1 : -1);
    });
    return result;
  }

  int get _filterCount =>
      _filters.values.fold(0, (sum, values) => sum + values.length) +
      (_from == null ? 0 : 1) +
      (_to == null ? 0 : 1);
  void _reset() {
    for (final values in _filters.values) {
      values.clear();
    }
    _from = null;
    _to = null;
  }

  @override
  void didUpdateWidget(covariant GachaHistoryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedAccountKey != widget.selectedAccountKey) {
      _expanded.clear();
      _expansionReady = false;
      _reset();
    }
  }

  List<(String, String, int)> _options(String axis) {
    final entries = <String, (String, int)>{};
    for (final batch in _accountBatches) {
      final pool = _pools[batch.poolId];
      if (axis == 'pool' || axis == 'category') {
        final value = axis == 'pool' ? batch.poolId : pool?.category;
        if (value != null && value.isNotEmpty) {
          entries[value] = (
            axis == 'pool' ? pool?.name ?? value : value,
            (entries[value]?.$2 ?? 0) + 1,
          );
        }
      } else {
        for (final prize in batch.prizes) {
          if (axis == 'pickup' && prize.pickup == null) continue;
          final value = axis == 'pickup'
              ? (prize.pickup == null
                    ? 'unknown'
                    : prize.pickup!
                    ? 'yes'
                    : 'no')
              : axis == 'kind'
              ? prize.kind
              : '${prize.rarity}';
          final label = axis == 'pickup'
              ? _t(prize.pickup == true ? 'pickup' : 'nonPickup')
              : axis == 'kind'
              ? _t(prize.kind)
              : prize.rarityLabel;
          if (label.isNotEmpty) {
            entries[value] = (
              label,
              (entries[value]?.$2 ?? 0) + prize.quantity,
            );
          }
        }
      }
    }
    return entries.entries
        .map((entry) => (entry.key, entry.value.$1, entry.value.$2))
        .toList();
  }

  Future<void> _showFilters() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) => StatefulBuilder(
      builder: (context, update) {
        void change(VoidCallback action) {
          setState(action);
          update(() {});
        }

        return SizedBox(
          height: MediaQuery.sizeOf(context).height * .8,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _t('filter'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    TextButton(
                      onPressed: () => change(_reset),
                      child: Text(_t('reset')),
                    ),
                    IconButton(
                      tooltip: _t('close'),
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Symbols.close_rounded),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (final axis in _filters.keys)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _t(axis),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                for (final option in _options(axis))
                                  FilterChip(
                                    label: Text(
                                      '${option.$2} · ${_number(option.$3)}',
                                    ),
                                    selected: _filters[axis]!.contains(
                                      option.$1,
                                    ),
                                    onSelected: (selected) => change(() {
                                      if (selected) {
                                        _filters[axis]!.add(option.$1);
                                      } else {
                                        _filters[axis]!.remove(option.$1);
                                      }
                                    }),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    for (final start in [true, false])
                      ListTile(
                        enabled: _accountBatches.any(
                          (batch) => batch.pulledAt != null,
                        ),
                        title: Text(_t(start ? 'from' : 'to')),
                        subtitle: Text(
                          (start ? _from : _to) == null
                              ? '—'
                              : DateFormat.yMMMd(_locale)
                                    .format((start ? _from : _to)!),
                        ),
                        trailing: const Icon(Symbols.calendar_month_rounded),
                        onTap: () async {
                          final dates =
                              _accountBatches
                                  .map(
                                    (batch) => batch.pulledAt == null
                                        ? null
                                        : _inServerTime(batch.pulledAt!),
                                  )
                                  .whereType<DateTime>()
                                  .toList()
                                ..sort();
                          final first = dates.isEmpty
                                  ? DateTime.now()
                                  : dates.first,
                              last = dates.isEmpty
                                  ? DateTime.now()
                                  : dates.last;
                          final value = await showDatePicker(
                            context: context,
                            initialDate:
                                (start ? _from : _to) ?? (start ? first : last),
                            firstDate: start ? first : _from ?? first,
                            lastDate: start ? _to ?? last : last,
                          );
                          if (value != null && mounted && context.mounted) {
                            change(() {
                              if (start) {
                                _from = value;
                              } else {
                                _to = value;
                              }
                            });
                          }
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
  String _pct(num value, {int digits = 2}) =>
      (NumberFormat.percentPattern(_locale)
            ..minimumFractionDigits = 0
            ..maximumFractionDigits = digits)
          .format(value);
  String _fixed(num value, [int digits = 0]) =>
      (NumberFormat.decimalPattern(_locale)
            ..minimumFractionDigits = 0
            ..maximumFractionDigits = digits)
          .format(value);
  String _interval(Object? range) {
    if (range is! Map) return '—';
    final min = range['min'] as num, max = range['max'] as num;
    return min == max ? _fixed(min, 2) : '${_fixed(min, 2)}–${_fixed(max, 2)}';
  }

  String _date(DateTime value) =>
      DateFormat.yMMMd(_locale).format(_inServerTime(value));
  String _dateTime(DateTime value) =>
      DateFormat.yMMMd(_locale).add_Hm().format(_inServerTime(value));
  String _poolName(String? id) =>
      _pools[id ?? '']?.name ?? ((id ?? '').isEmpty ? _t('unknown') : id!);

  List<_Collected> _collected(List<GachaHistoryBatch> batches) {
    final cards = <String, _Collected>{};
    for (final batch in batches) {
      for (final prize in batch.prizes) {
        if (prize.kind != 'member' && prize.kind != 'support') continue;
        final key = '${prize.kind}:${prize.id}';
        final card = cards.putIfAbsent(key, () => _Collected(key, prize));
        card.count++;
        if (prize.pickup == true) card.pickup++;
        if (prize.converted) card.converted++;
        card.pools.add(batch.poolId);
        if (batch.pulledAt case final at?
            when card.last == null || at.isAfter(card.last!)) {
          card.last = at;
        }
      }
    }
    return cards.values.toList();
  }

  /// Draw-weighted official rate across the pools that publish one.
  double? _officialRate(Map stats, num Function(Map rates) rate) {
    var draws = 0, sum = 0.0;
    for (final pool in (stats['pools'] as List).cast<Map>()) {
      final rates = _pools['${pool['poolId']}']?.rates;
      if (rates == null) continue;
      final total = pool['total'] as int;
      draws += total;
      sum += rate(rates) * total;
    }
    return draws == 0 ? null : sum / draws;
  }

  int _luckTier(Map luck) {
    final p = luck['percentile'] as num;
    return p >= 0.9
        ? 1
        : p >= 0.65
        ? 2
        : p > 0.35
        ? 3
        : p > 0.1
        ? 4
        : 5;
  }

  String _share(num value) =>
      value < 0.001 ? '< ${_pct(0.001, digits: 1)}' : _pct(value, digits: 1);
  String _luckValue(Map luck) {
    final p = luck['percentile'] as num;
    return p >= 0.5
        ? _t('luckTop', {'value': _share(1 - p)})
        : _t('luckBottom', {'value': _share(p)});
  }

  void _selectTab(String tab) => setState(() => _tab = tab);

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered, scoped = _scoped;
    final stats = scoped.isEmpty ? null : _analysisData(scoped);
    final viewTab = _tab == 'records' || _tab == 'collection';
    return ShellPage(
      title: _t('title'),
      status: Text(_t('batches', {'count': filtered.length})),
      search: ShellSearch(
        label: _t('search'),
        onChanged: (value) => setState(() => _query = value),
      ),
      marks: _filterCount == 0
          ? null
          : Wrap(
              spacing: 4,
              children: [
                for (final axis in _filters.keys)
                  for (final value in _filters[axis]!)
                    InputChip(
                      label: Text(
                        _options(axis)
                                .where((option) => option.$1 == value)
                                .firstOrNull
                                ?.$2 ??
                            value,
                      ),
                      onDeleted: () =>
                          setState(() => _filters[axis]!.remove(value)),
                    ),
                if (_from != null)
                  InputChip(
                    label: Text('${_t('from')} · ${_filterDay(_from!)}'),
                    onDeleted: () => setState(() => _from = null),
                  ),
                if (_to != null)
                  InputChip(
                    label: Text('${_t('to')} · ${_filterDay(_to!)}'),
                    onDeleted: () => setState(() => _to = null),
                  ),
              ],
            ),
      marksExtent: _filterCount == 0 ? 0 : 160,
      actions: [
        BarAction(
          icon: Symbols.image_rounded,
          label: _t('exportImage'),
          onPressed: scoped.isEmpty
              ? null
              : () => showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (context) => GachaHistoryImagePreview(
                    report: _report(scoped),
                    onExport: widget.onExportImage,
                  ),
                ),
        ),
        if (widget.onExport != null)
          BarAction(
            icon: Symbols.file_download_rounded,
            label: _t('export'),
            onPressed: filtered.isEmpty
                ? null
                : () => widget.onExport!(
                    GachaHistoryExport(
                      accountKey: widget.selectedAccountKey,
                      historyKind: widget.selectedHistoryKind,
                      batches: filtered,
                    ),
                  ),
          ),
        if (_tab == 'records')
          BarAction(
            icon: Symbols.swap_vert_rounded,
            label: _t(_oldest ? 'oldest' : 'newest'),
            selected: _oldest,
            onPressed: () => setState(() => _oldest = !_oldest),
          ),
        BarAction(
          icon: Symbols.filter_list_rounded,
          label: _t('filter'),
          badge: _filterCount,
          onPressed: _showFilters,
        ),
        if (viewTab)
          BarAction.choice(
            label: AppScope.of(context).text('common.actions.view'),
            options: [
              for (final view in [
                ('grid', Symbols.grid_view_rounded),
                ('list', Symbols.table_rows_rounded),
                ('table', Symbols.view_list_rounded),
              ])
                BarChoice(
                  icon: view.$2,
                  label: AppScope.of(context).text('common.layout.${view.$1}'),
                  selected: _view == view.$1,
                  onSelected: () => setState(() => _view = view.$1),
                ),
            ],
          ),
      ],
      body: LayoutBuilder(
        builder: (context, box) {
          final pad = box.maxWidth < 600 ? 16.0 : 24.0;
          return ListView(
            padding: EdgeInsets.fromLTRB(pad, 16, pad, 32),
            children: [
              _hero(scoped, stats, box.maxWidth - pad * 2),
              SizedBox(
                height: 4,
                child: widget.busy
                    ? LinearProgressIndicator(semanticsLabel: _t('loading'))
                    : null,
              ),
              if (stats != null) ...[
                const SizedBox(height: 16),
                _tabBar(),
                const SizedBox(height: 16),
                switch (_tab) {
                  'pools' => _poolsPanel(scoped, stats, box.maxWidth - pad * 2),
                  'collection' => _collectionPanel(scoped),
                  'records' => _recordsPanel(filtered),
                  'trends' => _trendsPanel(
                    scoped,
                    stats,
                    box.maxWidth - pad * 2,
                  ),
                  'settings' => _settingsPanel(box.maxWidth - pad * 2),
                  _ => _overviewPanel(scoped, stats, box.maxWidth - pad * 2),
                },
              ] else ...[
                _empty(
                  _t(
                    widget.selectedAccountKey.isEmpty
                        ? 'emptyAccount'
                        : _accountBatches.isEmpty
                        ? (widget.historyLoaded ? 'empty' : 'historyNotLoaded')
                        : 'noResults',
                  ),
                  Symbols.history_rounded,
                ),
                if (widget.selectedAccountKey.isNotEmpty)
                  _settingsPanel(box.maxWidth - pad * 2),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _empty(String title, IconData icon) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Column(
      children: [
        Icon(icon, size: 40, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );

  /// The site's `.surface` card.
  Widget _surface(List<Widget> children, {Color? color}) => Material(
    color: color ?? Theme.of(context).colorScheme.surfaceContainerLow,
    borderRadius: BorderRadius.circular(Corner.extraLarge),
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );

  /// The site's `renderDetailSectionHeading` at level 3.
  Widget _heading(String title, IconData icon, {int? count}) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          ShapedIcon(
            shape: MaterialShapes.cookie9Sided,
            size: 36,
            child: Icon(icon, size: 20),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Corner.full),
              ),
              child: Text(_number(count), style: theme.textTheme.labelSmall),
            ),
          ],
        ],
      ),
    );
  }

  /// Two columns from 840 dp, with `wide` children across both.
  Widget _grid(double width, List<(Widget, bool)> children) {
    final two = width >= 840;
    final half = two ? (width - 16) / 2 : width;
    return Wrap(
      spacing: 16,
      runSpacing: 16,
      children: [
        for (final (child, wide) in children)
          SizedBox(width: wide ? width : half, child: child),
      ],
    );
  }

  Widget _stat({
    required IconData icon,
    required String label,
    required String value,
    String supporting = '',
    String tone = 'neutral',
    Color? container,
  }) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    final (accent, accentContainer) = switch (tone) {
      'primary' => (scheme.onPrimaryContainer, scheme.primaryContainer),
      'secondary' => (scheme.onSecondaryContainer, scheme.secondaryContainer),
      'tertiary' ||
      'luck-1' ||
      'luck-2' => (scheme.onTertiaryContainer, scheme.tertiaryContainer),
      'luck-4' || 'luck-5' => (scheme.onErrorContainer, scheme.errorContainer),
      _ => (scheme.onSurfaceVariant, scheme.surfaceContainerHighest),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: container ?? scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(Corner.large),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: accentContainer,
                  borderRadius: BorderRadius.circular(Corner.medium),
                ),
                child: Icon(icon, size: 22, color: accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w500,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          SizedBox(
            height: 20,
            child: Text(
              supporting,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The hero's six figures: 6 / 3 / 2 columns; a pool's four: 4 / 2.
  Widget _stats(double width, List<Widget> tiles, {int columns = 6}) {
    final count = columns == 4
        ? (width >= 760 ? 4 : 2)
        : width >= 1060
        ? 6
        : width >= 560
        ? 3
        : 2;
    final tile = (width - (count - 1) * 8) / count;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final child in tiles) SizedBox(width: tile, child: child),
      ],
    );
  }

  Widget _hero(
    List<GachaHistoryBatch> scoped,
    Map<String, Object?>? stats,
    double width,
  ) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    final account = widget.accounts
        .where((row) => row.key == widget.selectedAccountKey)
        .firstOrNull;
    final dates =
        scoped.map((batch) => batch.pulledAt).whereType<DateTime>().toList()
          ..sort();
    final luck = stats == null ? null : historyLuck(scoped, 'high');
    final official = stats == null
        ? null
        : _officialRate(stats, (rates) => rates['high'] as num);
    final latest = scoped
        .where((batch) => batch.pulledAt != null)
        .fold<GachaHistoryBatch?>(
          null,
          (best, batch) =>
              best == null || batch.pulledAt!.isAfter(best.pulledAt!)
              ? batch
              : best,
        );
    final streak = latest == null
        ? null
        : historyHits(
            scoped.where((batch) => batch.poolId == latest.poolId).toList(),
            'high',
          ).firstOrNull?['trailing'];
    final cost = stats == null ? null : stats['cost'] as Map;
    num? costValue(String key) => (cost?[key] as Map?)?['value'] as num?;
    final gems = costValue('freeGems') == null && costValue('paidGems') == null
        ? null
        : (costValue('freeGems') ?? 0) + (costValue('paidGems') ?? 0);
    final conversion = widget.currencyConversion;
    final money = cost == null || conversion == null
        ? null
        : summarizeGachaHistoryMoney(
            cost.cast<String, Object?>(),
            freeUnitGemPrice: conversion.freeUnitGemPrice,
            paidUnitGemPrice: conversion.paidUnitGemPrice,
          )['sum'];
    final status =
        widget.error ??
        (widget.catalogLoading ? _t('catalogLoading') : widget.catalogError);
    final narrow = width < 600;
    final select = DropdownMenu<String>(
      key: ValueKey(widget.selectedAccountKey),
      initialSelection: account?.key,
      expandedInsets: EdgeInsets.zero,
      label: Text(_t('account')),
      hintText: _t('selectAccount'),
      enabled: !widget.busy && widget.onAccountChanged != null,
      requestFocusOnTap: false,
      dropdownMenuEntries: [
        for (final row in widget.accounts)
          DropdownMenuEntry(
            value: row.key,
            label: [
              row.serverLabel,
              row.label,
            ].where((value) => value.isNotEmpty).join(' · '),
          ),
      ],
      onSelected: (value) {
        if (value != null) widget.onAccountChanged?.call(value);
      },
    );
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (widget.onRefresh != null)
          FilledButton.icon(
            onPressed: widget.busy || widget.selectedAccountKey.isEmpty
                ? null
                : () => widget.onRefresh!(widget.selectedAccountKey),
            icon: const Icon(Symbols.history_rounded),
            label: Text(_t('readHistory')),
          ),
        if (widget.onImport != null)
          FilledButton.tonalIcon(
            onPressed: widget.busy ? null : widget.onImport,
            icon: const Icon(Symbols.person_add_rounded),
            label: Text(_t('import')),
          ),
      ],
    );
    Widget meta(IconData icon, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(
          text,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(Corner.extraLarge),
      child: Padding(
        padding: EdgeInsets.all(narrow ? 16 : 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (narrow) ...[
              select,
              const SizedBox(height: 12),
              actions,
            ] else
              Row(
                children: [
                  Expanded(child: select),
                  const SizedBox(width: 12),
                  actions,
                ],
              ),
            if (dates.isNotEmpty || stats != null) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                runSpacing: 4,
                children: [
                  if (dates.isNotEmpty)
                    meta(
                      Symbols.date_range_rounded,
                      '${_date(dates.first)} – ${_date(dates.last)}',
                    ),
                  if (stats != null)
                    meta(
                      Symbols.receipt_long_rounded,
                      _t('batches', {'count': stats['batches']}),
                    ),
                  if (widget.historyKinds.length > 1)
                    meta(
                      Symbols.history_rounded,
                      _t(
                        widget.selectedHistoryKind == 'legacy'
                            ? 'historyLegacy'
                            : 'historyExecution',
                      ),
                    ),
                ],
              ),
            ],
            Semantics(
              liveRegion: true,
              child: SizedBox(
                height: 28,
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        status ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: widget.error != null
                              ? scheme.error
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (widget.catalogError != null &&
                        !widget.catalogLoading &&
                        widget.onCatalogRetry != null)
                      TextButton(
                        onPressed: widget.onCatalogRetry,
                        child: Text(_t('retryCatalog')),
                      ),
                  ],
                ),
              ),
            ),
            if (stats != null)
              _stats(width - (narrow ? 32 : 40), [
                _stat(
                  icon: Symbols.casino_rounded,
                  label: _t('total'),
                  value: _number(stats['total'] as num),
                  supporting:
                      '${_t('member')} ${_number(stats['member'] as num)} · ${_t('support')} ${_number(stats['support'] as num)}',
                  tone: 'primary',
                ),
                _stat(
                  icon: Symbols.star_rounded,
                  label: 'SSR+',
                  value: _number(stats['high'] as num),
                  supporting: [
                    _percent(stats['high'] as num, stats['total'] as num),
                    if (official != null)
                      '${_t('officialRate')} ${_pct(official)}',
                  ].join(' · '),
                  tone: 'tertiary',
                ),
                _stat(
                  icon: Symbols.trending_up_rounded,
                  label: _t('pickup'),
                  value: _number(stats['pickup'] as num),
                  supporting: (stats['pickup'] as num) > 0
                      ? _t('pullsEach', {
                          'count': _fixed(
                            (stats['total'] as num) / (stats['pickup'] as num),
                            1,
                          ),
                        })
                      : (stats['pickupUnknown'] as num) > 0
                      ? '${_t('unknown')} ${_number(stats['pickupUnknown'] as num)}'
                      : '',
                  tone: 'secondary',
                ),
                _stat(
                  icon: Symbols.hourglass_bottom_rounded,
                  label: _t('sinceLastHigh'),
                  value: _interval(streak),
                  supporting: latest == null ? '' : _poolName(latest.poolId),
                ),
                _stat(
                  icon: Symbols.auto_awesome_rounded,
                  label: _t('luck'),
                  value: luck == null ? '—' : _t('luckTier${_luckTier(luck)}'),
                  supporting: luck == null ? '' : _luckValue(luck),
                  tone: luck == null ? 'neutral' : 'luck-${_luckTier(luck)}',
                ),
                _stat(
                  icon: Symbols.diamond_rounded,
                  label: _t('gemsSpent'),
                  value: gems == null ? '—' : _number(gems),
                  supporting: money is num
                      ? NumberFormat.simpleCurrency(
                          locale: _locale,
                          name: conversion!.currencyCode,
                        ).format(money)
                      : (costValue('tickets') ?? 0) > 0
                      ? '${_t('tickets')} ${_number(costValue('tickets')!)}'
                      : '',
                ),
              ]),
          ],
        ),
      ),
    );
  }

  Widget _tabBar() {
    final scheme = Theme.of(context).colorScheme;
    const icons = {
      'overview': Symbols.insights_rounded,
      'pools': Symbols.layers_rounded,
      'collection': Symbols.collections_bookmark_rounded,
      'records': Symbols.receipt_long_rounded,
      'trends': Symbols.show_chart_rounded,
      'settings': Symbols.tune_rounded,
    };
    const labels = {
      'overview': 'tabOverview',
      'pools': 'tabPools',
      'collection': 'tabCollection',
      'records': 'tabRecords',
      'trends': 'tabTrends',
      'settings': 'tabSettings',
    };
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(Corner.large),
          ),
          child: Row(
            children: [
              for (final tab in _tabs)
                Padding(
                  padding: const EdgeInsets.only(right: 2),
                  child: Semantics(
                    selected: _tab == tab,
                    button: true,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 40),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        foregroundColor: _tab == tab
                            ? scheme.onSecondaryContainer
                            : scheme.onSurfaceVariant,
                        backgroundColor: _tab == tab
                            ? scheme.secondaryContainer
                            : null,
                      ),
                      onPressed: () => _selectTab(tab),
                      icon: Icon(
                        icons[tab],
                        size: 18,
                        fill: _tab == tab ? 1 : 0,
                      ),
                      label: Text(_t(labels[tab]!)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _luckMeter(String label, Map<String, Object?>? luck) {
    if (luck == null) return const SizedBox.shrink();
    final theme = Theme.of(context), scheme = theme.colorScheme;
    final tier = _luckTier(luck), p = (luck['percentile'] as num).toDouble();
    final (fg, bg) = tier <= 2
        ? (scheme.onTertiaryContainer, scheme.tertiaryContainer)
        : tier >= 4
        ? (scheme.onErrorContainer, scheme.errorContainer)
        : (scheme.onSecondaryContainer, scheme.secondaryContainer);
    final atLeast = (luck['atLeast'] as num).toDouble();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: theme.textTheme.titleSmall)),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(Corner.full),
                ),
                child: Text(
                  _t('luckTier$tier'),
                  style: theme.textTheme.labelLarge?.copyWith(color: fg),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Semantics(
            label: label,
            value: _luckValue(luck),
            child: SizedBox(
              height: 20,
              child: LayoutBuilder(
                builder: (context, box) => Stack(
                  alignment: AlignmentDirectional.centerStart,
                  children: [
                    Container(
                      height: 12,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(Corner.full),
                      ),
                    ),
                    Container(
                      height: 12,
                      width: box.maxWidth * p,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(Corner.full),
                      ),
                    ),
                    PositionedDirectional(
                      start: (box.maxWidth * p - 2).clamp(0, box.maxWidth - 4),
                      child: Container(
                        width: 4,
                        height: 20,
                        decoration: BoxDecoration(
                          color: scheme.onSurface,
                          borderRadius: BorderRadius.circular(Corner.full),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          _factGrid([
            (_t('observed'), _number(luck['observed'] as num)),
            (_t('expected'), _fixed(luck['expected'] as num, 2)),
            (_t('luck'), _luckValue(luck)),
            (
              _t('atLeastChance'),
              atLeast < 0.001
                  ? '< ${_pct(0.001, digits: 1)}'
                  : _pct(atLeast, digits: 1),
            ),
          ]),
        ],
      ),
    );
  }

  /// The site's `.spec-list--split`: two label/value pairs per row.
  Widget _factGrid(List<(String, String)> facts) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, box) => Wrap(
        runSpacing: 12,
        children: [
          for (final (label, value) in facts)
            SizedBox(
              width: box.maxWidth / 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(value, style: theme.textTheme.titleMedium),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _table(List<String> headers, List<List<String>> rows) =>
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columnSpacing: 24,
          horizontalMargin: 12,
          columns: [
            for (final (index, header) in headers.indexed)
              DataColumn(label: Text(header), numeric: index > 0),
          ],
          rows: [
            for (final row in rows)
              DataRow(
                cells: [
                  for (final (index, cell) in row.indexed)
                    DataCell(
                      Text(
                        cell,
                        style: index == 0
                            ? const TextStyle(fontWeight: FontWeight.w600)
                            : null,
                      ),
                    ),
                ],
              ),
          ],
        ),
      );

  Widget _overviewPanel(
    List<GachaHistoryBatch> scoped,
    Map<String, Object?> stats,
    double width,
  ) {
    List<Map> rows(Object? value) => (value as List).cast<Map>();
    int rarity(String key) =>
        rows(stats['distribution'])
                .firstWhere((row) => row['rarity'] == key)['count']
            as int;
    int kindHigh(String kind) =>
        rows(stats['kinds']).firstWhere((row) => row['kind'] == kind)['high']
            as int;
    num rare(Map rates, String key) => (rates['rarities'] as Map)[key] as num;
    final rates = <(String, int, double?)>[
      (
        'SSR+',
        stats['high'] as int,
        _officialRate(stats, (r) => r['high'] as num),
      ),
      (
        '${_t('member')} SSR+',
        kindHigh('member'),
        _officialRate(stats, (r) => r['memberHigh'] as num),
      ),
      (
        '${_t('support')} SSR+',
        kindHigh('support'),
        _officialRate(stats, (r) => r['supportHigh'] as num),
      ),
      ('BD', rarity('BD'), _officialRate(stats, (r) => rare(r, 'BD'))),
      ('EX', rarity('EX'), _officialRate(stats, (r) => rare(r, 'EX'))),
      ('SR', rarity('SR'), _officialRate(stats, (r) => rare(r, 'SR'))),
      ('R', rarity('R'), _officialRate(stats, (r) => rare(r, 'R'))),
      (
        _t('pickup'),
        stats['pickup'] as int,
        _officialRate(stats, (r) => r['pickup'] as num),
      ),
    ];
    final total = stats['total'] as num;
    final hits =
        [
          for (final pool in historyHits(scoped, 'high'))
            for (final hit in pool['hits'] as List)
              {...hit as Map<String, Object?>, 'poolId': pool['poolId']},
        ]..sort(
          (a, b) =>
              (b['pulledAt'] as String).compareTo(a['pulledAt'] as String),
        );
    final highLuck = historyLuck(scoped, 'high');
    return _grid(width, [
      (
        _surface([
          _heading(_t('luck'), Symbols.monitoring_rounded),
          _luckMeter('SSR+', highLuck),
          _luckMeter(_t('pickup'), historyLuck(scoped, 'pickup')),
          if (highLuck == null) const Text('—'),
        ]),
        false,
      ),
      (
        _surface([
          _heading(_t('rateComparison'), Symbols.bar_chart_rounded),
          _table(
            [
              _t('resultType'),
              _t('quantity'),
              _t('observedRate'),
              _t('officialRate'),
            ],
            [
              for (final (index, (label, count, official)) in rates.indexed)
                if (index < 3 || count > 0 || (official ?? 0) > 0)
                  [
                    label,
                    _number(count),
                    _percent(count, total),
                    official == null ? '—' : _pct(official),
                  ],
            ],
          ),
        ]),
        false,
      ),
      (
        _surface([
          _heading(
            _t('recentHits'),
            Symbols.photo_library_rounded,
            count: hits.length,
          ),
          if (hits.isEmpty)
            const Text('—')
          else
            _hitList(hits.take(12).toList(), true),
          if (hits.length > 12)
            Align(
              child: TextButton.icon(
                onPressed: () => _selectTab('pools'),
                icon: const Icon(Symbols.chevron_right_rounded),
                label: Text(_t('allHits')),
              ),
            ),
        ]),
        true,
      ),
      for (final chart in _distributionCharts(stats)) (chart, false),
      (
        _surface([
          _heading(_t('cost'), Symbols.payments_rounded),
          _factGrid(_costMetrics(scoped)),
        ]),
        true,
      ),
      if (_highlights(scoped) case final highlights?) (highlights, true),
    ]);
  }

  List<Widget> _distributionCharts(Map<String, Object?> stats) => [
    for (final kind in (stats['kinds'] as List).cast<Map>().where(
      (kind) =>
          (kind['kind'] == 'member' || kind['kind'] == 'support') &&
          (kind['total'] as num) > 0,
    ))
      GachaHistoryChart(
        title: '${_t(kind['kind'] as String)} · ${_t('rarityDistribution')}',
        caption:
            '${_t(kind['kind'] as String)} ${_number(kind['total'] as num)} · SSR+ ${_percent(kind['high'] as num, kind['total'] as num)}',
        labels: [_t('nonPickup'), _t('pickup')],
        rows: [
          for (final row in (kind['distribution'] as List).cast<Map>().where(
            (row) =>
                ['SSR', 'SR', 'R'].contains(row['rarity']) ||
                ((row['count'] as num) > 0 &&
                    row['rarity'] != 'item' &&
                    row['rarity'] != 'unknown'),
          ))
            (
              '${row['rarity']} · ${_percent(row['count'] as num, kind['total'] as num)}',
              [row['nonPickup'] as num, row['pickup'] as num],
            ),
        ],
      ),
  ];

  Widget _hitList(List<Map<String, Object?>> hits, bool showPool) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    final largest = math.max(
      1,
      hits.fold<num>(
        0,
        (m, hit) => math.max(m, (hit['since'] as Map)['max'] as num),
      ),
    );
    return Column(
      children: [
        for (final hit in hits)
          Builder(
            builder: (context) {
              final prize = hit['prize'] as GachaHistoryPrize;
              final since = hit['since'] as Map;
              final middle =
                  ((since['min'] as num) + (since['max'] as num)) / 2;
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Material(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(Corner.medium),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: _open(prize),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 48,
                            child: GachaPrizeCard(
                              label: prize.name,
                              rarityValue: int.tryParse('${prize.rarity}') ?? 0,
                              image: prize.imageUrl,
                              attribute: prize.attributeImageUrl,
                              rarity: prize.rarityImageUrl,
                              pickup: prize.pickup == true,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  prize.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall,
                                ),
                                Text(
                                  [
                                    if (showPool)
                                      _poolName(hit['poolId'] as String?),
                                    _dateTime(
                                      DateTime.parse(hit['pulledAt'] as String),
                                    ),
                                    '#${_interval(hit['position'])}',
                                  ].join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 96,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  _t('draws', {'count': _interval(since)}),
                                  style: theme.textTheme.labelLarge,
                                ),
                                const SizedBox(height: 4),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(
                                    Corner.full,
                                  ),
                                  child: LinearProgressIndicator(
                                    value: math.max(0.02, middle / largest),
                                    minHeight: 6,
                                    color: prize.pickup == true
                                        ? scheme.tertiary
                                        : scheme.primary,
                                    backgroundColor:
                                        scheme.surfaceContainerHighest,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _cardGrid(List<Widget> cards, {required String kind, double? min}) =>
      LayoutBuilder(
        builder: (context, box) {
          final minWidth = min ?? (kind == 'support' ? 148.0 : 84.0);
          final columns = math.max(
            1,
            ((box.maxWidth + 8) / (minWidth + 8)).floor(),
          );
          final width = (box.maxWidth - (columns - 1) * 8) / columns;
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final card in cards) SizedBox(width: width, child: card),
            ],
          );
        },
      );

  Widget _collectedCard(_Collected card, {bool showPickup = true}) =>
      GachaPrizeCard(
        label: '${card.prize.name} · ×${card.count}',
        rarityValue: int.tryParse('${card.prize.rarity}') ?? 0,
        image: card.prize.imageUrl,
        attribute: card.prize.attributeImageUrl,
        rarity: card.prize.rarityImageUrl,
        count: card.count,
        pickupCount: showPickup ? card.pickup : 0,
        pickup: showPickup && card.pickup > 0,
        aspectRatio: card.prize.kind == 'support' ? 16 / 9 : 3 / 4,
        onTap: _open(card.prize),
      );

  Widget? _highlights(List<GachaHistoryBatch> scoped) {
    final cards =
        _collected(scoped).where((card) => _isHigh(card.prize)).toList()..sort(
          (a, b) => b.pickup != a.pickup
              ? b.pickup - a.pickup
              : _rarityRank(b.prize.rarity) != _rarityRank(a.prize.rarity)
              ? _rarityRank(b.prize.rarity) - _rarityRank(a.prize.rarity)
              : b.count - a.count,
        );
    if (cards.isEmpty) return null;
    return _surface([
      _heading(_t('highlights'), Symbols.photo_library_rounded),
      _cardGrid([
        for (final card in cards.take(12))
          GachaPrizeCard(
            label: '${card.prize.name} · ×${card.count}',
            rarityValue: int.tryParse('${card.prize.rarity}') ?? 0,
            image: card.prize.imageUrl,
            attribute: card.prize.attributeImageUrl,
            rarity: card.prize.rarityImageUrl,
            count: card.count,
            pickupCount: card.pickup,
            pickup: card.pickup > 0,
            onTap: _open(card.prize),
          ),
      ], kind: 'member'),
      Align(
        child: TextButton.icon(
          onPressed: () => _selectTab('collection'),
          icon: const Icon(Symbols.chevron_right_rounded),
          label: Text(_t('tabCollection')),
        ),
      ),
    ]);
  }

  Widget _poolsPanel(
    List<GachaHistoryBatch> scoped,
    Map<String, Object?> stats,
    double width,
  ) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    final highHits = {
      for (final row in historyHits(scoped, 'high')) row['poolId']: row,
    };
    final pickupHits = {
      for (final row in historyHits(scoped, 'pickup')) row['poolId']: row,
    };
    return Column(
      children: [
        for (final pool in (stats['pools'] as List).cast<Map>())
          Builder(
            builder: (context) {
              final id = pool['poolId'] as String?;
              final view = _pools[id ?? ''];
              final batches = scoped
                  .where(
                    (batch) =>
                        (batch.poolId.isEmpty ? null : batch.poolId) == id,
                  )
                  .toList();
              final high = highHits[id], pickup = pickupHits[id];
              final owned = {
                for (final card in _collected(batches)) card.key: card,
              };
              final rates = view?.rates;
              final total = pool['total'] as num;
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: _surface([
                  Row(
                    children: [
                      SizedBox(
                        width: 96,
                        height: 48,
                        child: view?.imageUrl == null
                            ? Icon(
                                Symbols.casino_rounded,
                                color: scheme.onSurfaceVariant,
                              )
                            : AppImage(
                                candidates: [view!.imageUrl!],
                                fit: BoxFit.contain,
                                placeholder: const SizedBox.shrink(),
                              ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _poolName(id),
                              style: theme.textTheme.titleMedium,
                            ),
                            Text(
                              [
                                if (view != null) view.category,
                                if (view?.startAt != null &&
                                    view?.endAt != null)
                                  '${_date(view!.startAt!)} – ${_date(view.endAt!)}',
                              ].join(' · '),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(Corner.full),
                        ),
                        child: Text(
                          _t('draws', {'count': _number(total)}),
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _stats(width - 32, columns: 4, [
                    _stat(
                      icon: Symbols.star_rounded,
                      label: 'SSR+',
                      value: _number(pool['high'] as num),
                      supporting: [
                        _percent(pool['high'] as num, total),
                        if (rates != null)
                          '${_t('officialRate')} ${_pct(rates['high'] as num)}',
                      ].join(' · '),
                      tone: 'tertiary',
                      container: scheme.surfaceContainer,
                    ),
                    _stat(
                      icon: Symbols.trending_up_rounded,
                      label: _t('pickup'),
                      value: _number(pool['pickup'] as num),
                      supporting: [
                        _percent(pool['pickup'] as num, total),
                        if (rates != null && (rates['pickup'] as num) > 0)
                          '${_t('officialRate')} ${_pct(rates['pickup'] as num)}',
                      ].join(' · '),
                      tone: 'secondary',
                      container: scheme.surfaceContainer,
                    ),
                    _stat(
                      icon: Symbols.hourglass_bottom_rounded,
                      label: _t('sinceLastHigh'),
                      value: _interval(high?['trailing']),
                      supporting: pickup?['trailing'] == null
                          ? ''
                          : '${_t('sinceLastPickup')} ${_interval(pickup!['trailing'])}',
                      container: scheme.surfaceContainer,
                    ),
                    _stat(
                      icon: Symbols.functions_rounded,
                      label: _t('pullsPerHigh'),
                      value: pool['pullsPerHigh'] == null
                          ? '—'
                          : _fixed(pool['pullsPerHigh'] as num, 1),
                      supporting: pool['expectedHigh'] == null
                          ? ''
                          : '${_t('expected')} ${_fixed(pool['expectedHigh'] as num, 2)} · ${_t('difference')} ${NumberFormat('+0.##;-0.##', _locale).format(pool['delta'] ?? 0)}',
                      container: scheme.surfaceContainer,
                    ),
                  ]),
                  const SizedBox(height: 12),
                  _luckMeter(_t('luck'), historyLuck(batches, 'high')),
                  if (view != null && view.featured.isNotEmpty) ...[
                    Row(
                      children: [
                        Text(
                          _t('pickupCollected'),
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(Corner.full),
                          ),
                          child: Text(
                            '${view.featured.where((card) => owned.containsKey(card.key)).length} / ${view.featured.length}',
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    for (final kind in ['member', 'support'])
                      if (view.featured.any((card) => card.kind == kind))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _cardGrid(kind: kind, [
                            for (final card in view.featured.where(
                              (card) => card.kind == kind,
                            ))
                              Opacity(
                                opacity: owned.containsKey(card.key) ? 1 : 0.45,
                                child: ColorFiltered(
                                  colorFilter: owned.containsKey(card.key)
                                      ? const ColorFilter.mode(
                                          Colors.transparent,
                                          BlendMode.dst,
                                        )
                                      : const ColorFilter.matrix([
                                          0.2126,
                                          0.7152,
                                          0.0722,
                                          0,
                                          0,
                                          0.2126,
                                          0.7152,
                                          0.0722,
                                          0,
                                          0,
                                          0.2126,
                                          0.7152,
                                          0.0722,
                                          0,
                                          0,
                                          0,
                                          0,
                                          0,
                                          1,
                                          0,
                                        ]),
                                  child: GachaPrizeCard(
                                    label:
                                        '${card.name} · ${owned[card.key] == null ? _t('notObtained') : '×${owned[card.key]!.count}'}',
                                    rarityValue:
                                        int.tryParse('${card.rarity}') ?? 0,
                                    image: card.imageUrl,
                                    attribute: card.attributeImageUrl,
                                    rarity: card.rarityImageUrl,
                                    count: owned[card.key]?.count ?? 0,
                                    aspectRatio: kind == 'support'
                                        ? 16 / 9
                                        : 3 / 4,
                                    onTap:
                                        card.href == null ||
                                            widget.onOpenCard == null
                                        ? null
                                        : () => widget.onOpenCard!(card.href!),
                                  ),
                                ),
                              ),
                          ]),
                        ),
                  ],
                  _exchangeProgress(view),
                  if ((high?['hits'] as List?)?.isNotEmpty ?? false)
                    DetailFold(
                      title: _t('highHistory'),
                      meta: _number((high!['hits'] as List).length),
                      child: _hitList(
                        (high['hits'] as List).reversed
                            .cast<Map<String, Object?>>()
                            .toList(),
                        false,
                      ),
                    ),
                  if ((pickup?['hits'] as List?)?.isNotEmpty ?? false)
                    DetailFold(
                      title: _t('pickupHistory'),
                      meta: _number((pickup!['hits'] as List).length),
                      child: _hitList(
                        (pickup['hits'] as List).reversed
                            .cast<Map<String, Object?>>()
                            .toList(),
                        false,
                      ),
                    ),
                ]),
              );
            },
          ),
      ],
    );
  }

  Widget _collectionPanel(List<GachaHistoryBatch> scoped) {
    final all = _collected(scoped);
    final cards =
        all
            .where(
              (card) =>
                  (_albumKind == 'all' || card.prize.kind == _albumKind) &&
                  (_allCards || _isHigh(card.prize) || card.pickup > 0) &&
                  (!_onlyPickup || card.pickup > 0),
            )
            .toList()
          ..sort(
            (a, b) => _rarityRank(b.prize.rarity) != _rarityRank(a.prize.rarity)
                ? _rarityRank(b.prize.rarity) - _rarityRank(a.prize.rarity)
                : b.count != a.count
                ? b.count - a.count
                : a.key.compareTo(b.key),
          );
    final copies = all.fold<int>(0, (sum, card) => sum + card.count);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _surface([
          _factGrid([
            (_t('distinctCards'), _number(all.length)),
            (
              _t('distinctHigh'),
              _number(all.where((card) => _isHigh(card.prize)).length),
            ),
            (_t('duplicates'), _number(copies - all.length)),
            (
              _t('converted'),
              _number(all.fold<int>(0, (sum, card) => sum + card.converted)),
            ),
          ]),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: 'all', label: Text(_t('allKinds'))),
                  ButtonSegment(value: 'member', label: Text(_t('member'))),
                  ButtonSegment(value: 'support', label: Text(_t('support'))),
                ],
                selected: {_albumKind},
                onSelectionChanged: (value) =>
                    setState(() => _albumKind = value.single),
              ),
              FilterChip(
                label: Text(_t('allCards')),
                selected: _allCards,
                onSelected: (value) => setState(() => _allCards = value),
              ),
              FilterChip(
                label: Text(_t('onlyPickup')),
                selected: _onlyPickup,
                onSelected: (value) => setState(() => _onlyPickup = value),
              ),
            ],
          ),
        ]),
        const SizedBox(height: 16),
        if (cards.isEmpty)
          _empty(_t('noResults'), Symbols.collections_bookmark_rounded)
        else if (_view == 'table')
          _table(
            [
              _t('card'),
              _t('kind'),
              _t('rarity'),
              _t('quantity'),
              _t('pickup'),
              _t('converted'),
              _t('pool'),
            ],
            [
              for (final card in cards)
                [
                  card.prize.name,
                  _t(card.prize.kind),
                  card.prize.rarityLabel.isEmpty ? '—' : card.prize.rarityLabel,
                  _number(card.count),
                  _number(card.pickup),
                  _number(card.converted),
                  card.pools.map(_poolName).join(' / '),
                ],
            ],
          )
        else if (_view == 'list')
          Column(
            children: [
              for (final card in cards)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: SizedBox.square(
                    dimension: 56,
                    child: AppImage(
                      candidates: [
                        if (card.prize.imageUrl != null) card.prize.imageUrl!,
                      ],
                      placeholder: const Icon(Symbols.image_rounded),
                    ),
                  ),
                  title: Text(card.prize.name),
                  subtitle: Text(
                    [
                      _t(card.prize.kind),
                      if (card.prize.rarityLabel.isNotEmpty)
                        card.prize.rarityLabel,
                      '×${card.count}',
                      if (card.pickup > 0) '${_t('pickup')} ×${card.pickup}',
                      if (card.last != null) _date(card.last!),
                    ].join(' · '),
                  ),
                  onTap: _open(card.prize),
                ),
            ],
          )
        else
          for (final kind in ['member', 'support'])
            if (cards.any((card) => card.prize.kind == kind)) ...[
              _heading(
                _t(kind),
                kind == 'member'
                    ? Symbols.person_rounded
                    : Symbols.photo_library_rounded,
                count: cards.where((card) => card.prize.kind == kind).length,
              ),
              _cardGrid(kind: kind, [
                for (final card in cards.where(
                  (card) => card.prize.kind == kind,
                ))
                  _collectedCard(card),
              ]),
              const SizedBox(height: 16),
            ],
      ],
    );
  }

  Widget _recordsPanel(List<GachaHistoryBatch> filtered) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    if (filtered.isEmpty) {
      return _empty(_t('noResults'), Symbols.receipt_long_rounded);
    }
    final groups = <String, List<GachaHistoryBatch>>{};
    for (final batch in filtered) {
      groups.putIfAbsent(_day(batch.pulledAt), () => []).add(batch);
    }
    final days = groups.keys.toList();
    if (!_expansionReady && days.isNotEmpty) {
      if (days.first != 'unknown') _expanded.add(days.first);
      _expansionReady = true;
    }
    Widget chip(IconData icon, String text, {bool tone = false}) => Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: tone ? scheme.tertiaryContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Corner.small),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: tone ? scheme.onTertiaryContainer : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Text(
            text,
            style: theme.textTheme.labelMedium?.copyWith(
              color: tone
                  ? scheme.onTertiaryContainer
                  : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
    return Column(
      children: [
        for (final day in days)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              child: ExpansionTile(
                key: ValueKey('${widget.selectedAccountKey}:$day'),
                initiallyExpanded: _expanded.contains(day),
                onExpansionChanged: (expanded) => setState(() {
                  if (expanded) {
                    _expanded.add(day);
                  } else {
                    _expanded.remove(day);
                  }
                }),
                title: Text(
                  day == 'unknown'
                      ? _t('unknownTime')
                      : DateFormat.yMMMMEEEEd(_locale)
                            .format(DateTime.parse(day)),
                ),
                subtitle: Text(_drawSummary(groups[day]!)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Corner.medium),
                ),
                collapsedShape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Corner.medium),
                ),
                childrenPadding: const EdgeInsets.all(16),
                children: _expanded.contains(day)
                    ? [
                        for (final batch in groups[day]!)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Wrap(
                                  spacing: 12,
                                  runSpacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    if (_pools[batch.poolId]?.imageUrl
                                        case final image?)
                                      SizedBox(
                                        width: 96,
                                        height: 48,
                                        child: AppImage(
                                          candidates: [image],
                                          fit: BoxFit.contain,
                                          placeholder: const SizedBox.shrink(),
                                        ),
                                      ),
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _poolName(batch.poolId),
                                          style: theme.textTheme.titleSmall,
                                        ),
                                        Text(
                                          '${batch.pulledAt == null ? _t('unknownTime') : DateFormat.Hm(_locale).format(_inServerTime(batch.pulledAt!))} · ${batch.drawCount == null ? _t('unknownCount') : _t('draws', {'count': batch.drawCount})}',
                                          style: theme.textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                    if (batch.prizes.where(_isHigh).length
                                        case final high when high > 0)
                                      chip(
                                        Symbols.star_rounded,
                                        'SSR+ $high',
                                        tone: true,
                                      ),
                                    if (((batch.cost?.freeGems ?? 0) +
                                            (batch.cost?.paidGems ?? 0))
                                        case final gems when gems > 0)
                                      chip(
                                        Symbols.diamond_rounded,
                                        _number(gems),
                                      ),
                                    if (batch.cost?.tickets case final tickets?
                                        when tickets > 0)
                                      chip(
                                        Symbols.confirmation_number_rounded,
                                        _number(tickets),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                _renderPrizes(_prizes(batch)),
                              ],
                            ),
                          ),
                      ]
                    : const [],
              ),
            ),
          ),
      ],
    );
  }

  Widget _trendsPanel(
    List<GachaHistoryBatch> scoped,
    Map<String, Object?> stats,
    double width,
  ) {
    final months = historyMonths(scoped, _offsetMinutes);
    String monthLabel(String month) =>
        DateFormat.yMMM(_locale).format(DateTime.parse('$month-01'));
    List<num> values(Map row) => [
      row['member'] as num,
      row['support'] as num,
      row['other'] as num,
    ];
    final composition = [_t('member'), _t('support'), _t('item')];
    String cost(Map row, String key) {
      final value = ((row['cost'] as Map)[key] as Map)['value'];
      return value == null ? '—' : _number(value as num);
    }

    return _grid(width, [
      (
        GachaHistoryChart(
          title: _t('monthlyTrend'),
          labels: composition,
          details: [
            for (final row in months)
              'SSR+ ${row['high']} · ${_t('pickup')} ${row['pickup']}',
          ],
          rows: [
            for (final row in months)
              (monthLabel(row['month'] as String), values(row)),
          ],
        ),
        false,
      ),
      (
        GachaHistoryChart(
          title: 'SSR+ · ${_t('monthlyTrend')}',
          labels: [_t('nonPickup'), _t('pickup')],
          rows: [
            for (final row in months)
              (
                monthLabel(row['month'] as String),
                [
                  (row['high'] as num) -
                      math.min(row['high'] as num, row['pickup'] as num),
                  math.min(row['high'] as num, row['pickup'] as num),
                ],
              ),
          ],
        ),
        false,
      ),
      (
        GachaHistoryChart(
          title: _t('dailyTrend'),
          labels: composition,
          details: [
            for (final day in (stats['days'] as List).cast<Map>())
              'SSR+ ${day['high']} · ${_t('pickup')} ${day['pickup']}',
          ],
          rows: [
            for (final day in (stats['days'] as List).cast<Map>())
              ('${day['day'] ?? _t('unknownTime')}', values(day)),
          ],
        ),
        true,
      ),
      (
        GachaHistoryChart(
          title: _t('poolComposition'),
          labels: composition,
          rows: [
            for (final pool in (stats['pools'] as List).cast<Map>())
              (_poolName(pool['poolId'] as String?), values(pool)),
          ],
        ),
        true,
      ),
      (
        _surface([
          _heading(_t('monthlyTrend'), Symbols.monitoring_rounded),
          _table(
            [
              _t('month'),
              _t('total'),
              'SSR+',
              _t('pickup'),
              _t('observedRate'),
              _t('freeGems'),
              _t('paidGems'),
              _t('tickets'),
            ],
            [
              for (final row in months.reversed)
                [
                  monthLabel(row['month'] as String),
                  _number(row['total'] as num),
                  _number(row['high'] as num),
                  _number(row['pickup'] as num),
                  _percent(row['high'] as num, row['total'] as num),
                  cost(row, 'freeGems'),
                  cost(row, 'paidGems'),
                  cost(row, 'tickets'),
                ],
            ],
          ),
        ]),
        true,
      ),
    ]);
  }

  Widget _settingsPanel(double width) => _grid(width, [
    (
      _surface([
        _heading(_t('account'), Symbols.account_circle_rounded),
        if (widget.historyKinds.length > 1) ...[
          DropdownMenu<String>(
            key: ValueKey(widget.selectedHistoryKind),
            initialSelection: widget.selectedHistoryKind,
            label: Text(_t('historyKind')),
            expandedInsets: EdgeInsets.zero,
            requestFocusOnTap: false,
            dropdownMenuEntries: [
              for (final kind in widget.historyKinds)
                DropdownMenuEntry(
                  value: kind,
                  label: _t(
                    kind == 'legacy' ? 'historyLegacy' : 'historyExecution',
                  ),
                ),
            ],
            onSelected: (kind) {
              if (kind != null) widget.onHistoryKindChanged?.call(kind);
            },
          ),
          const SizedBox(height: 16),
        ],
        _cloudControls(),
      ]),
      false,
    ),
    if (widget.currencyConversion case final conversion?)
      (
        _surface([
          _heading(_t('conversion'), Symbols.payments_rounded),
          _GachaConversionEditor(
            key: ValueKey(widget.selectedAccountKey),
            conversion: conversion,
            onChanged: widget.onConversionChanged,
            currencyLabel: _t('currency'),
            freePriceLabel: _t('freeUnitGemPrice'),
            paidPriceLabel: _t('paidUnitGemPrice'),
            applyLabel: _t('applyPrice'),
          ),
        ]),
        false,
      ),
  ]);

  List<(String, String)> _costMetrics(List<GachaHistoryBatch> batches) {
    final stats = _analysisData(batches);
    final costs = (stats['cost'] as Map).cast<String, Object?>();
    final high = stats['high'] as num, pickup = stats['pickup'] as num;
    String number(Map value) => value['value'] == null
        ? '—'
        : '${value['partial'] == true ? "≥ " : ""}${_number(value['value'] as num)}';
    final metrics = [
      for (final key in ['freeGems', 'paidGems', 'tickets'])
        (_t(key), number(costs[key] as Map)),
    ];
    final conversion = widget.currencyConversion;
    if (conversion != null) {
      final amounts = summarizeGachaHistoryMoney(
        costs,
        freeUnitGemPrice: conversion.freeUnitGemPrice,
        paidUnitGemPrice: conversion.paidUnitGemPrice,
      );
      String money(Map value) => value['value'] == null
          ? '—'
          : '${value['partial'] == true ? "≥ " : ""}${NumberFormat.simpleCurrency(locale: _locale, name: conversion.currencyCode).format(value['value'])}';
      metrics.addAll([
        (_t('freeValue'), money(amounts['freeGems'] as Map)),
        (_t('paidValue'), money(amounts['paidGems'] as Map)),
      ]);
      if (amounts['sum'] case final num sum when high > 0) {
        metrics.add((
          _t('moneyPerHigh'),
          money({'value': sum / high, 'partial': false}),
        ));
      }
    }
    final free = (costs['freeGems'] as Map)['value'] as num?,
        paid = (costs['paidGems'] as Map)['value'] as num?;
    if (free != null || paid != null) {
      final gems = (free ?? 0) + (paid ?? 0);
      if (high > 0) metrics.add((_t('gemsPerHigh'), _fixed(gems / high)));
      if (pickup > 0) {
        metrics.add((_t('gemsPerPickup'), _fixed(gems / pickup)));
      }
    }
    return metrics;
  }

  GachaHistoryReportData _report(List<GachaHistoryBatch> batches) {
    final summary = _analysisData(batches);
    final luck = historyLuck(batches, 'high');
    final metrics = <(String, String)>[
      (_t('total'), _number(summary['total'] as num)),
      (
        'SSR+',
        '${_number(summary['high'] as num)} · ${_percent(summary['high'] as num, summary['total'] as num)}',
      ),
      (_t('pickup'), _number(summary['pickup'] as num)),
      (
        _t('luck'),
        luck == null
            ? '—'
            : '${_t('luckTier${_luckTier(luck)}')} · ${_luckValue(luck)}',
      ),
    ];
    final stats = _analysisData(batches);
    List<Map> rows(Object? value) => (value as List).cast<Map>();
    final groups = <GachaHistoryReportGroup>[];
    for (final pool in rows(stats['pools'])) {
      final selected = batches
          .where((batch) => batch.poolId == pool['poolId'])
          .toList();
      final cardMap = {
        for (final batch in selected)
          for (final prize in batch.prizes) '${prize.kind}:${prize.id}': prize,
      };
      final poolCards = rows(_analysisData(selected)['cards']);
      for (final kind in ['member', 'support']) {
        groups.add(
          GachaHistoryReportGroup(
            label:
                '${_pools[pool['poolId']]?.name ?? pool['poolId']} · ${_t(kind)}',
            imageUrl: _pools[pool['poolId']]?.imageUrl,
            cards: [
              for (final card in poolCards.where(
                (card) =>
                    card['kind'] == kind &&
                    ([4, 10, 20].contains(
                          int.tryParse('${cardMap[card['key']]!.rarity}'),
                        ) ||
                        (card['pickup'] as num) > 0),
              ))
                GachaHistoryReportCard(
                  name: cardMap[card['key']]!.name,
                  kindLabel: _t(kind),
                  quantity: (card['count'] as num).toInt(),
                  imageUrl: cardMap[card['key']]!.imageUrl,
                  attributeImageUrl: cardMap[card['key']]!.attributeImageUrl,
                  rarityImageUrl: cardMap[card['key']]!.rarityImageUrl,
                  rarity: int.tryParse('${cardMap[card['key']]!.rarity}') ?? 0,
                  pickup: (card['pickup'] as num).toInt(),
                ),
            ],
          ),
        );
      }
    }
    final charts = [
      for (final kind in rows(
        stats['kinds'],
      ).where((kind) => kind['kind'] == 'member' || kind['kind'] == 'support'))
        GachaHistoryChart(
          title: '${_t(kind['kind'] as String)} · ${_t('rarityDistribution')}',
          caption:
              '${_t(kind['kind'] as String)} ${_number(kind['total'] as num)} · SSR+ ${_percent(kind['high'] as num, kind['total'] as num)}',
          labels: [_t('nonPickup'), _t('pickup')],
          rows: [
            for (final row in rows(kind['distribution']).where(
              (row) =>
                  ['SSR', 'SR', 'R'].contains(row['rarity']) ||
                  ((row['count'] as num) > 0 &&
                      row['rarity'] != 'item' &&
                      row['rarity'] != 'unknown'),
            ))
              (
                '${row['rarity']} · ${_percent(row['count'] as num, kind['total'] as num)}',
                [row['nonPickup'] as num, row['pickup'] as num],
              ),
          ],
        ),
    ];
    final dates =
        batches
            .map(
              (batch) => batch.pulledAt == null
                  ? null
                  : _inServerTime(batch.pulledAt!),
            )
            .whereType<DateTime>()
            .toList()
          ..sort();
    final scope = [
      dates.isEmpty
          ? _t('unknownTime')
          : '${DateFormat.yMMMd(_locale).format(dates.first)} – ${DateFormat.yMMMd(_locale).format(dates.last)}',
      if (dates.isNotEmpty && dates.length != batches.length) _t('unknownTime'),
    ];
    return GachaHistoryReportData(
      title: _t('title'),
      scope: scope,
      metrics: metrics,
      groups: groups,
      charts: charts,
    );
  }

  Widget _cloudControls() {
    final disabled =
        widget.busy || widget.cloudBusy || widget.selectedAccountKey.isEmpty;
    const errors = <String, String>{
      'authentication_required': 'cloudSignIn',
      'email_verification_required': 'cloudVerifyEmail',
      'account_restricted': 'cloudAccountRestricted',
      'history_too_large': 'cloudTooLarge',
      'history_account_limit': 'cloudAccountLimit',
      'history_account_mismatch': 'cloudAccountMismatch',
      'history_server_mismatch': 'cloudServerMismatch',
      'history_session_expired': 'errorSessionExpired',
      'history_network_error': 'cloudNetworkError',
      'history_cloud_unavailable': 'cloudUnavailable',
    };
    final error = errors[widget.cloudErrorCode];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_t('cloudTitle'), style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!widget.cloudSignedIn ||
                [
                  'authentication_required',
                  'email_verification_required',
                  'account_restricted',
                ].contains(widget.cloudErrorCode))
              FilledButton.tonal(
                onPressed: () => ShellScope.of(context)?.navigate('/account'),
                child: Text(
                  _t(widget.cloudSignedIn ? 'cloudAccount' : 'cloudSignIn'),
                ),
              ),
            if (widget.cloudSignedIn)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: disabled || widget.onCloudLink == null
                        ? null
                        : () => widget.onCloudLink!(!widget.cloudLinked),
                    child: Text(
                      _t(widget.cloudLinked ? 'cloudUnlink' : 'cloudLink'),
                    ),
                  ),
                  FilledButton.tonal(
                    onPressed: disabled || !widget.cloudLinked
                        ? null
                        : widget.onCloudSync,
                    child: Text(
                      _t(widget.cloudBusy ? 'cloudSyncing' : 'cloudSync'),
                    ),
                  ),
                  FilledButton.tonal(
                    onPressed:
                        disabled ||
                            !widget.cloudLinked ||
                            widget.cloudRefreshPending
                        ? null
                        : widget.onCloudRefresh,
                    child: Text(
                      _t(
                        widget.cloudRefreshPending
                            ? 'cloudRefreshPending'
                            : 'cloudRefresh',
                      ),
                    ),
                  ),
                ],
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _t(error),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _exchangeProgress(GachaHistoryPool? pool) {
    final targets = pool?.exchangeTargets ?? const <Map<String, Object?>>[];
    if (targets.isEmpty) return const SizedBox.shrink();
    final groups = <String, List<Map<String, Object?>>>{};
    for (final target in targets) {
      final reward = target['reward'] as Map;
      final key = [
        reward['resourceType'],
        target['pointCost'],
        target['basePointCost'],
        target['pointBalance'],
        target['pointsNeeded'],
        target['additionalDrawsNeeded'],
        target['remainingExchangeLimit'],
        target['resetType'],
      ].join('|');
      groups.putIfAbsent(key, () => []).add(target);
    }
    return DetailFold(
      title: _t('exchangeProgress'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final group in groups.values)
            Builder(
              builder: (context) {
                final target = group.first;
                final reward = target['reward'] as Map;
                final cost = target['pointCost'] as num?,
                    balance = target['pointBalance'] as num?;
                final facts = <String, num>{
                  cost == null ? 'basePointCost' : 'pointCost':
                      cost ?? target['basePointCost'] as num,
                  'pointBalance': ?balance,
                  if (target['pointsNeeded'] != null)
                    'pointsNeeded': target['pointsNeeded'] as num,
                  if (target['additionalDrawsNeeded'] != null)
                    'additionalDrawsNeeded':
                        target['additionalDrawsNeeded'] as num,
                  if (target['remainingExchangeLimit'] != null)
                    'remainingExchangeLimit':
                        target['remainingExchangeLimit'] as num,
                };
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _t(reward['resourceType'] == 2 ? 'member' : 'support'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      for (final fact in facts.entries)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _t(fact.key),
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelMedium,
                                ),
                              ),
                              Text(_number(fact.value)),
                            ],
                          ),
                        ),
                      if (balance != null && cost != null)
                        LinearProgressIndicator(
                          value: cost == 0
                              ? 1
                              : (balance / cost).clamp(0, 1).toDouble(),
                          semanticsLabel:
                              '${_t('pointBalance')} ${_number(balance)} / ${_t('pointCost')} ${_number(cost)}',
                        ),
                      DetailFold(
                        title:
                            '${_t('exchangeTargets')} · ${_number(group.length)}',
                        child: Column(
                          children: [
                            for (final entry in group)
                              Builder(
                                builder: (context) {
                                  final card = entry['reward'] as Map;
                                  final name =
                                      '${card['name'] ?? card['resourceId'] ?? ''}';
                                  final href = card['href'] as String?;
                                  final details = [
                                    '${_t(entry['pointCost'] == null ? 'basePointCost' : 'pointCost')} ${_number((entry['pointCost'] ?? entry['basePointCost']) as num)}',
                                    if (entry['redeemedCount'] != null)
                                      '${_t('redeemedCount')} ${_number(entry['redeemedCount'] as num)}',
                                    if (entry['remainingExchangeLimit'] != null)
                                      '${_t('remainingExchangeLimit')} ${_number(entry['remainingExchangeLimit'] as num)}',
                                    if (entry['resetType'] != null)
                                      _t(
                                        {
                                          1: 'resetNever',
                                          2: 'resetDaily',
                                          3: 'resetWeekly',
                                          4: 'resetMonthly',
                                        }[entry['resetType']]!,
                                      ),
                                  ];
                                  return ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    isThreeLine: details.length > 2,
                                    leading: SizedBox.square(
                                      dimension: 56,
                                      child: GachaPrizeCard(
                                        label: name,
                                        rarityValue:
                                            int.tryParse('${card['rarity']}') ??
                                            0,
                                        image: card['image'] as String?,
                                        attribute:
                                            card['attributeImageUrl']
                                                as String?,
                                        rarity:
                                            card['rarityImageUrl'] as String?,
                                        count: (card['count'] as num? ?? 1)
                                            .toInt(),
                                      ),
                                    ),
                                    title: Text(name),
                                    subtitle: Text(details.join(' · ')),
                                    onTap:
                                        href == null ||
                                            widget.onOpenCard == null
                                        ? null
                                        : () => widget.onOpenCard!(href),
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  String _drawSummary(List<GachaHistoryBatch> batches) {
    final known = batches.where((batch) => batch.drawCount != null).toList();
    final unknown = batches.length - known.length;
    return [
      if (known.isNotEmpty)
        _t('draws', {
          'count': known.fold<int>(0, (sum, batch) => sum + batch.drawCount!),
        }),
      if (unknown > 0) _t('unknownDraws', {'count': unknown}),
    ].join(' · ');
  }

  VoidCallback? _open(GachaHistoryPrize prize) =>
      prize.href == null || widget.onOpenCard == null
      ? null
      : () => widget.onOpenCard!(prize.href!);
  Widget _renderPrizes(List<GachaHistoryPrize> prizes) {
    String subtitle(GachaHistoryPrize prize) => [
      _t(prize.kind),
      if (prize.rarityLabel.isNotEmpty) prize.rarityLabel,
      '×${prize.quantity}',
      if (prize.pickup == true) _t('pickup'),
      if (prize.converted) _t('converted'),
    ].join(' · ');
    if (_view == 'table') {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: [
            for (final key in [
              'card',
              'kind',
              'rarity',
              'quantity',
              'pickup',
              'converted',
            ])
              DataColumn(label: Text(_t(key))),
          ],
          rows: [
            for (final prize in prizes)
              DataRow(
                cells: [
                  DataCell(Text(prize.name), onTap: _open(prize)),
                  DataCell(Text(_t(prize.kind))),
                  DataCell(
                    Text(prize.rarityLabel.isEmpty ? '—' : prize.rarityLabel),
                  ),
                  DataCell(Text(_number(prize.quantity))),
                  DataCell(
                    Text(
                      prize.pickup == null
                          ? '—'
                          : _t(prize.pickup! ? 'yes' : 'no'),
                    ),
                  ),
                  DataCell(Text(_t(prize.converted ? 'yes' : 'no'))),
                ],
              ),
          ],
        ),
      );
    }
    if (_view == 'list') {
      return Column(
        children: [
          for (final prize in prizes)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: SizedBox.square(
                dimension: 56,
                child: AppImage(
                  candidates: [if (prize.imageUrl != null) prize.imageUrl!],
                  placeholder: const Icon(Symbols.image_rounded),
                ),
              ),
              title: Text(prize.name),
              subtitle: Text(subtitle(prize)),
              onTap: _open(prize),
            ),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth < 600 ? 5 : 10;
        return Wrap(
          spacing: 8,
          runSpacing: 12,
          children: [
            for (final prize in prizes)
              SizedBox(
                width: (constraints.maxWidth - (columns - 1) * 8) / columns,
                child: GachaPrizeCard(
                  label: '${prize.name} · ${subtitle(prize)}',
                  rarityValue: int.tryParse('${prize.rarity}') ?? 0,
                  image: prize.imageUrl,
                  attribute: prize.attributeImageUrl,
                  rarity: prize.rarityImageUrl,
                  pickup: prize.pickup == true,
                  count: prize.quantity,
                  onTap: _open(prize),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _GachaConversionEditor extends StatefulWidget {
  const _GachaConversionEditor({
    super.key,
    required this.conversion,
    required this.onChanged,
    required this.currencyLabel,
    required this.freePriceLabel,
    required this.paidPriceLabel,
    required this.applyLabel,
  });
  final GachaHistoryConversion conversion;
  final ValueChanged<GachaHistoryConversion>? onChanged;
  final String currencyLabel, freePriceLabel, paidPriceLabel, applyLabel;
  @override
  State<_GachaConversionEditor> createState() => _GachaConversionEditorState();
}

class _GachaConversionEditorState extends State<_GachaConversionEditor> {
  final _form = GlobalKey<FormState>();
  late final _free = TextEditingController(
    text: widget.conversion.freeUnitGemPrice?.toString() ?? '',
  );
  late final _paid = TextEditingController(
    text: widget.conversion.paidUnitGemPrice?.toString() ?? '',
  );
  @override
  void didUpdateWidget(covariant _GachaConversionEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversion != widget.conversion) {
      _free.text = widget.conversion.freeUnitGemPrice?.toString() ?? '';
      _paid.text = widget.conversion.paidUnitGemPrice?.toString() ?? '';
    }
  }

  @override
  void dispose() {
    _free.dispose();
    _paid.dispose();
    super.dispose();
  }

  void _submit() {
    if (_form.currentState!.validate()) {
      widget.onChanged?.call(
        GachaHistoryConversion(
          currencyCode: widget.conversion.currencyCode,
          freeUnitGemPrice: double.tryParse(_free.text),
          paidUnitGemPrice: double.tryParse(_paid.text),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownMenu<String>(
          key: ValueKey(widget.conversion.currencyCode),
          initialSelection: widget.conversion.currencyCode,
          expandedInsets: EdgeInsets.zero,
          label: Text(widget.currencyLabel),
          enabled: widget.onChanged != null,
          requestFocusOnTap: false,
          dropdownMenuEntries: [
            for (final code in [
              'JPY',
              'TWD',
              'HKD',
              'MOP',
              'USD',
              'KRW',
              'CNY',
            ])
              DropdownMenuEntry(value: code, label: code),
          ],
          onSelected: (code) {
            if (code != null && code != widget.conversion.currencyCode) {
              widget.onChanged?.call(
                GachaHistoryConversion(
                  currencyCode: code,
                  freeUnitGemPrice: 0,
                  paidUnitGemPrice: null,
                ),
              );
            }
          },
        ),
        for (final field in [
          (_free, widget.freePriceLabel),
          (_paid, widget.paidPriceLabel),
        ]) ...[
          const SizedBox(height: 16),
          TextFormField(
            controller: field.$1,
            enabled: widget.onChanged != null,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: '${field.$2} · ${widget.conversion.currencyCode}',
            ),
            validator: (value) {
              if (value == null || value.trim().isEmpty) return null;
              final number = double.tryParse(value);
              return number == null || !number.isFinite || number < 0
                  ? field.$2
                  : null;
            },
            onFieldSubmitted: (_) => _submit(),
          ),
        ],
        const SizedBox(height: 12),
        FilledButton.tonal(
          onPressed: widget.onChanged == null ? null : _submit,
          child: Text(widget.applyLabel),
        ),
      ],
    ),
  );
}
