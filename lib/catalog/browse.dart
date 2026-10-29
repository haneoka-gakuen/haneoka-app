import 'package:flutter/material.dart';

import 'source_picker.dart';
import 'sort_control.dart';

import 'package:material_symbols_icons/symbols.dart';
import 'package:intl/intl.dart';

import '../core/app_state.dart';
import '../core/i18n.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/theme.dart';
import '../ui/tile.dart';
import 'visuals.dart';
import 'catalog_query.dart';

/// One value of a facet, as the filter sheet lists it.
class FacetOption {
  const FacetOption(this.label, {this.image, this.imageOnly = false});
  final String label;
  final String? image;
  final bool imageOnly;
}

/// A filter axis (`filter-facet`): values an entry carries, OR within the
/// facet, AND across facets.
class FacetSpec {
  const FacetSpec({
    required this.key,
    required this.label,
    required this.values,
    required this.option,
  });
  final String key;
  final String label;
  final Iterable<String> Function(Entry item) values;
  final FacetOption Function(String value) option;
}

class SortSpec {
  const SortSpec(
    this.key,
    this.label,
    this.value, {
    this.missingLast = false,
    this.hidden = false,
  });
  final String key;
  final String label;
  final Object? Function(Entry item) value;

  /// Song metrics: entries without the value go last in either order.
  final bool missingLast;

  /// A default order the sort menu does not offer.
  final bool hidden;
}

/// JavaScript's `Number(value)` (an array reads its first entry).
double jsNumber(Object? value) => switch (value) {
  null => 0,
  final num n => n.toDouble(),
  final bool b => b ? 1 : 0,
  final List list => list.isEmpty ? 0 : jsNumber(list.first),
  final String text when text.trim().isEmpty => 0,
  final String text => double.tryParse(text.trim()) ?? double.nan,
  _ => double.nan,
};

final _chunks = RegExp(r'\d+|\D+');

/// `localeCompare(…, { numeric: true, sensitivity: "base" })` for the
/// scripts the catalogue uses: digit runs compare as numbers, letters
/// without case or accents.
int naturalCompare(String a, String b) {
  String fold(String value) => value
      .toLowerCase()
      .replaceAll(RegExp('[àáâãäå]'), 'a')
      .replaceAll(RegExp('[èéêë]'), 'e')
      .replaceAll(RegExp('[ìíîï]'), 'i')
      .replaceAll(RegExp('[òóôõö]'), 'o')
      .replaceAll(RegExp('[ùúûü]'), 'u');
  final x = _chunks.allMatches(fold(a)).map((m) => m[0]!).toList();
  final y = _chunks.allMatches(fold(b)).map((m) => m[0]!).toList();
  for (var i = 0; i < x.length && i < y.length; i++) {
    final p = int.tryParse(x[i]), q = int.tryParse(y[i]);
    final d = p != null && q != null ? p.compareTo(q) : x[i].compareTo(y[i]);
    if (d != 0) return d;
  }
  return x.length.compareTo(y.length);
}

/// The website's collection order (`results` in `catalog-screen.ts`):
/// numbers when both values are numbers, otherwise their text, ties by id;
/// the whole comparison follows the chosen direction.
int compareEntries(
  Entry a,
  Entry b,
  SortSpec sort,
  Object? x,
  Object? y,
  String Function(Entry) id,
  bool descending,
) {
  final direction = descending ? -1 : 1;
  final p = jsNumber(x), q = jsNumber(y);
  if (sort.missingLast && p.isFinite != q.isFinite) return p.isFinite ? -1 : 1;
  if (sort.missingLast && !p.isFinite && !q.isFinite) {
    return naturalCompare(id(a), id(b)) * direction;
  }
  String text(Object? value) => switch (value) {
    null => '',
    final List list => list.join(', '),
    _ => '$value',
  };
  final comparison = p.isFinite && q.isFinite
      ? p.compareTo(q)
      : naturalCompare(text(x), text(y));
  return (comparison != 0 ? comparison : naturalCompare(id(a), id(b))) *
      direction;
}

enum BrowseView { grid, list, table }

class TableColumn {
  const TableColumn(this.label, this.cell, {this.numeric = false});
  final String label;
  final String Function(Entry item) cell;
  final bool numeric;
}

/// The grid's tile size: a resource's `--tile-min` and artwork ratio.
class GridSpec {
  const GridSpec({
    required this.minWidth,
    this.aspectRatio = 1,
    this.small = false,
  });
  final double minWidth;
  final double aspectRatio;
  final bool small;
}

/// A switch at the end of the filter sheet ("include skills without cards").
class BrowseSwitch {
  const BrowseSwitch(this.label, this.value, this.onChanged);
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
}

/// One destination in the pane rail: a band, a chapter.
class RailItem {
  const RailItem(this.value, this.label, {this.image, this.meta});
  final String value;
  final String label;
  final String? image;
  final String? meta;
}

/// The pane rail (`BrowseRail`): the axis a collection is organised by, as
/// artwork beside the results; across the top on narrow windows.
class BrowseRail {
  const BrowseRail({
    required this.items,
    required this.value,
    required this.onSelect,
  });
  final List<RailItem> items;
  final String value;
  final ValueChanged<String> onSelect;
}

/// The browse screen (`renderBrowse`): search, count, view switch and the
/// filter toggle in the title bar; applied filters as removable chips after
/// the title; results in the pane; facets, sort and order in a modal side
/// sheet at every size.
class BrowseScreen extends StatefulWidget {
  const BrowseScreen({
    super.key,
    required this.title,
    required this.items,
    required this.searchText,
    required this.grid,
    required this.tile,
    required this.listRow,
    required this.columns,
    this.onOpen,
    this.facets = const [],
    this.sorts = const [],
    this.defaultSort,
    this.descending = true,
    this.itemId,
    this.actions = _noActions,
    this.error,
    this.onRetry,
    this.rail,
    this.heading,
    this.marks,
    this.switches = const [],
    this.queryEngine,
    this.sourcePath,
    this.search,
  });
  final String title;
  final ShellSearch? search;
  final String? sourcePath;
  final CatalogQueryEngine? queryEngine;
  final void Function(BuildContext context, Entry item)? onOpen;

  /// Switches in the filter sheet; a switch that is on counts as a filter.
  final List<BrowseSwitch> switches;

  /// The collection's primary axis; the caller passes [items] already narrowed to it.
  final BrowseRail? rail;

  /// What the rail has selected, named (`BrowseHeading`).
  final Widget? heading;
  final Widget? marks;

  /// Null while the collection loads.
  final List<Entry>? items;
  final String Function(Entry item) searchText;
  final GridSpec grid;
  final Widget Function(BuildContext context, Entry item) tile;
  final Widget Function(BuildContext context, Entry item) listRow;
  final List<TableColumn> columns;
  final List<FacetSpec> facets;
  final List<SortSpec> sorts;
  final String? defaultSort;
  final bool descending;

  /// Breaks ties between equal sort values, as the website does.
  final String Function(Entry item)? itemId;

  /// Page actions before the filter toggle (Play all).
  final List<BarAction> Function(List<Entry> visible) actions;
  final Object? error;
  final VoidCallback? onRetry;

  static List<BarAction> _noActions(List<Entry> _) => const [];

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  String _query = '';
  BrowseView _view = BrowseView.grid;
  final Map<String, Set<String>> _selected = {};
  late String? _sort = widget.defaultSort ?? widget.sorts.firstOrNull?.key;
  late bool _descending = widget.descending;

  List<Entry>? _source;
  final Map<String, Map<Entry, List<String>>> _facetValues = {};
  final Map<Entry, String> _search = {};
  List<Entry> _visible = const [];
  Object? _visibleKey;
  Object? _indexKey;

  /// Facet values and search text are read once per entry, not per frame.
  void _index(List<Entry> items) {
    final state = AppScope.of(context);
    final key = (
      items,
      state.text.locale,
      state.japaneseTitles,
      state.difficultyEstimates,
    );
    if (key == _indexKey) return;
    _indexKey = key;
    _source = items;
    _facetValues.clear();
    _search.clear();
    for (final facet in widget.facets) {
      _facetValues[facet.key] = {
        for (final item in items) item: facet.values(item).toSet().toList(),
      };
    }
    for (final item in items) {
      _search[item] = widget.searchText(item).toLowerCase();
    }
    _visibleKey = null;
  }

  bool _matches(Entry item, [String? except]) {
    final plan = widget.queryEngine?.parse(_query);
    final text = plan?.text ?? _query;
    if (plan != null && !widget.queryEngine!.matches(item, plan)) return false;
    if (text.isNotEmpty && !(_search[item] ?? '').contains(text)) {
      return false;
    }
    for (final MapEntry(:key, :value) in _selected.entries) {
      if (key == except || value.isEmpty) continue;
      if (!(_facetValues[key]?[item] ?? const []).any(value.contains)) {
        return false;
      }
    }
    return true;
  }

  List<Entry> _results(List<Entry> items) {
    final key = (
      items,
      _query,
      _sort,
      _descending,
      [for (final e in _selected.entries) '${e.key}=${e.value.join(',')}']
          .join(';'),
    );
    if (key == _visibleKey) return _visible;
    final sort = widget.sorts.where((s) => s.key == _sort).firstOrNull;
    final list = items.where(_matches).toList();
    if (sort != null) {
      final values = {for (final item in list) item: sort.value(item)};
      final id = widget.itemId ?? (Entry item) => '${item['id'] ?? ''}';
      list.sort(
        (a, b) =>
            compareEntries(a, b, sort, values[a], values[b], id, _descending),
      );
    }
    _visibleKey = key;
    return _visible = list;
  }

  final Map<String, bool> _switchValues = {};
  bool _switchValue(BrowseSwitch s) => _switchValues[s.label] ?? s.value;

  int get _appliedCount =>
      _selected.values.fold(0, (sum, values) => sum + values.length) +
      widget.switches.where((s) => s.value).length;

  void _toggle(String facet, String value) => setState(() {
    final values = _selected.putIfAbsent(facet, () => {});
    if (!values.remove(value)) values.add(value);
  });

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    final items = widget.items;
    if (items != null) _index(items);
    final visible = items == null ? const <Entry>[] : _results(items);
    final number = NumberFormat.decimalPattern(t.locale);
    final theme = Theme.of(context);
    return BrowseSiblings(
      items: visible,
      child: _page(context, t, items, visible, number, theme),
    );
  }

  Widget _page(
    BuildContext context,
    SiteText t,
    List<Entry>? items,
    List<Entry> visible,
    NumberFormat number,
    ThemeData theme,
  ) {
    return ShellPage(
      title: widget.title,
      marks: widget.marks == null
          ? (_appliedCount == 0 ? null : _crumbs(context))
          : Row(
              children: [
                Flexible(child: widget.marks!),
                if (_appliedCount > 0) Flexible(child: _crumbs(context)),
              ],
            ),
      search:
          widget.search ??
          ShellSearch(
            label: t('common.actions.search', 'Search'),
            onChanged: (value) =>
                setState(() => _query = value.trim().toLowerCase()),
          ),
      status: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            items == null
                ? ''
                : '${number.format(visible.length)}${visible.length == items.length ? '' : ' / ${number.format(items.length)}'}',
            style: theme.textTheme.titleSmall,
          ),
        ),
      ),
      actions: [
        ...widget.actions(visible),
        if (widget.sourcePath != null)
          catalogSourceAction(context, widget.sourcePath!),
        if (widget.facets.isNotEmpty || widget.sorts.any((s) => !s.hidden))
          BarAction(
            icon: Symbols.filter_alt_rounded,
            label: t('common.actions.filter', 'Filter'),
            badge: _appliedCount,
            onPressed: () => _openFilters(context),
          ),
        BarAction.choice(
          label: t('common.actions.view', 'View'),
          options: [
            for (final (view, icon, label) in [
              (
                BrowseView.grid,
                Symbols.grid_view_rounded,
                t('common.layout.grid', 'Grid'),
              ),
              (
                BrowseView.list,
                Symbols.view_agenda_rounded,
                t('common.layout.list', 'List'),
              ),
              (
                BrowseView.table,
                Symbols.table_rows_rounded,
                t('common.layout.table', 'Table'),
              ),
            ])
              BarChoice(
                icon: icon,
                label: label,
                selected: _view == view,
                onSelected: () => setState(() => _view = view),
              ),
          ],
        ),
      ],
      body: widget.error != null && items == null
          ? Center(
              child: FilledButton.tonalIcon(
                icon: const Icon(Symbols.refresh_rounded),
                label: Text(t('common.actions.retry', 'Retry')),
                onPressed: widget.onRetry,
              ),
            )
          : items == null
          ? _skeleton(context)
          : _layout(context, visible),
    );
  }

  Widget _crumbs(BuildContext context) {
    final chips = <Widget>[
      const Icon(Symbols.chevron_right_rounded, size: 20),
      for (final facet in widget.facets)
        for (final value in _selected[facet.key] ?? const <String>{})
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: InputChip(
              label: Text(facet.option(value).label),
              visualDensity: VisualDensity.compact,
              onDeleted: () => _toggle(facet.key, value),
            ),
          ),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: chips),
    );
  }

  Widget _skeleton(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final padding = pagePadding(context);
      final scheme = Theme.of(context).colorScheme;
      return GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: padding,
        gridDelegate: collectionGrid(
          context,
          constraints.maxWidth - padding.horizontal,
          minWidth: widget.grid.minWidth,
          aspectRatio: widget.grid.aspectRatio,
          small: widget.grid.small,
        ),
        itemCount: 12,
        itemBuilder: (_, _) => DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(Corner.medium),
          ),
        ),
      );
    },
  );

  Widget _layout(BuildContext context, List<Entry> items) => LayoutBuilder(
    builder: (context, constraints) {
      final side =
          widget.rail != null && MediaQuery.sizeOf(context).width >= 1200;
      final results = switch (_view) {
        BrowseView.grid => _grid(context, items),
        BrowseView.list => _list(context, items),
        BrowseView.table => _table(context, items),
      };
      if (!side) return results;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 208,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                border: Border(
                  right: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
              child: ListView(
                padding: EdgeInsets.fromLTRB(8, 8, 8, 8),
                children: [
                  for (final item in widget.rail!.items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: _railTile(context, item, width: 192),
                    ),
                ],
              ),
            ),
          ),
          Expanded(child: results),
        ],
      );
    },
  );

  Widget _grid(BuildContext context, List<Entry> items) => LayoutBuilder(
    builder: (context, constraints) {
      final padding = pagePadding(context);
      return Scrollbar(
        child: CustomScrollView(
          slivers: [
            ..._header(
              context,
              padding,
              widget.rail != null && MediaQuery.sizeOf(context).width >= 1200,
            ),
            SliverPadding(
              padding: padding.copyWith(
                top: widget.heading == null ? padding.top : 8,
              ),
              sliver: SliverGrid.builder(
                gridDelegate: collectionGrid(
                  context,
                  constraints.maxWidth - padding.horizontal,
                  minWidth: widget.grid.minWidth,
                  aspectRatio: widget.grid.aspectRatio,
                  small: widget.grid.small,
                ),
                itemCount: items.length,
                itemBuilder: (context, index) =>
                    RepaintBoundary(child: widget.tile(context, items[index])),
              ),
            ),
          ],
        ),
      );
    },
  );

  List<Widget> _header(BuildContext context, EdgeInsets padding, bool side) => [
    if (widget.rail != null && !side)
      SliverToBoxAdapter(
        child: SizedBox(
          height: 102,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            itemCount: widget.rail!.items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) =>
                _railTile(context, widget.rail!.items[index], width: 148),
          ),
        ),
      ),
    if (widget.heading != null)
      SliverPadding(
        padding: EdgeInsets.fromLTRB(
          padding.left,
          MediaQuery.sizeOf(context).width < 600 ? 12 : 16,
          padding.right,
          4,
        ),
        sliver: SliverToBoxAdapter(child: widget.heading),
      ),
  ];

  Widget _railTile(
    BuildContext context,
    RailItem item, {
    required double width,
  }) {
    final rail = widget.rail!;
    final selected = item.value == rail.value;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: width,
      child: Material(
        color: selected
            ? scheme.secondaryContainer
            : MediaQuery.sizeOf(context).width < 1200
            ? scheme.surfaceContainer
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Corner.medium),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => rail.onSelect(item.value),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 48,
                  width: double.infinity,
                  child: item.image == null
                      ? const SizedBox()
                      : AppImage(candidates: [item.image!]),
                ),
                const SizedBox(height: 8),
                Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: selected
                        ? scheme.onSecondaryContainer
                        : scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _list(BuildContext context, List<Entry> items) {
    final padding = pagePadding(context);
    return Scrollbar(
      child: CustomScrollView(
        slivers: [
          ..._header(
            context,
            padding,
            widget.rail != null && MediaQuery.sizeOf(context).width >= 1200,
          ),
          SliverPadding(
            padding: padding.copyWith(
              top: widget.heading == null ? padding.top : 8,
            ),
            sliver: SliverFixedExtentList(
              itemExtent: 72,
              delegate: SliverChildBuilderDelegate(
                (context, index) => widget.listRow(context, items[index]),
                childCount: items.length,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _table(BuildContext context, List<Entry> items) {
    final theme = Theme.of(context);
    final columns = widget.columns;
    Widget row(List<String> cells, {bool header = false}) => SizedBox(
      height: header ? 48 : 52,
      child: Row(
        children: [
          for (final (index, cell) in cells.indexed)
            SizedBox(
              width: index == 0 ? 240 : 140,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  cell,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: columns[index].numeric
                      ? TextAlign.end
                      : TextAlign.start,
                  style: header
                      ? theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        )
                      : theme.textTheme.bodyMedium,
                ),
              ),
            ),
        ],
      ),
    );
    final width = 240.0 + 140 * (columns.length - 1);
    final table = Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: pagePadding(context).left),
        child: SizedBox(
          width: width,
          child: Column(
            children: [
              row([for (final c in columns) c.label], header: true),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  primary: false,
                  itemExtent: 52,
                  itemCount: items.length,
                  itemBuilder: (context, index) => InkWell(
                    onTap: widget.onOpen == null
                        ? null
                        : () => widget.onOpen!(context, items[index]),
                    child: row([for (final c in columns) c.cell(items[index])]),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final padding = pagePadding(context);
    return CustomScrollView(
      slivers: [
        ..._header(
          context,
          padding,
          widget.rail != null && MediaQuery.sizeOf(context).width >= 1200,
        ),
        SliverFillRemaining(child: table),
      ],
    );
  }

  void _openFilters(BuildContext context) {
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.32),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, _, _) => Align(
        alignment: AlignmentDirectional.centerEnd,
        child: StatefulBuilder(
          builder: (context, setSheet) => BrowseFilterPanel(
            switches: [
              for (final s in widget.switches)
                BrowseSwitch(s.label, _switchValue(s), (value) {
                  _switchValues[s.label] = value;
                  s.onChanged(value);
                  setSheet(() {});
                }),
            ],
            facets: widget.facets,
            sorts: [
              for (final sort in widget.sorts)
                if (!sort.hidden) sort,
            ],
            sort: _sort,
            descending: _descending,
            selected: _selected,
            counts: _counts,
            onToggle: (facet, value) {
              _toggle(facet, value);
              setSheet(() {});
            },
            onSort: (sort) {
              setState(() => _sort = sort);
              setSheet(() {});
            },
            onOrder: () {
              setState(() => _descending = !_descending);
              setSheet(() {});
            },
            onReset: () {
              setState(_selected.clear);
              setSheet(() {});
            },
          ),
        ),
      ),
      transitionBuilder: (context, animation, _, child) => SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(
          CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
        ),
        child: child,
      ),
    );
  }

  /// How many entries each value would leave, given every other facet.
  Map<String, int> _counts(String facet) {
    final counts = <String, int>{
      for (final values
          in _facetValues[facet]?.values ?? const <List<String>>[])
        for (final value in values) value: 0,
    };
    for (final item in _source ?? const <Entry>[]) {
      if (!_matches(item, facet)) continue;
      for (final value in _facetValues[facet]?[item] ?? const <String>[]) {
        counts[value] = (counts[value] ?? 0) + 1;
      }
    }
    return counts;
  }
}

class BrowseFilterPanel extends StatelessWidget {
  const BrowseFilterPanel({
    super.key,
    required this.switches,
    required this.facets,
    required this.sorts,
    required this.sort,
    required this.descending,
    required this.selected,
    required this.counts,
    required this.onToggle,
    required this.onSort,
    required this.onOrder,
    required this.onReset,
    this.fields = const [],
  });
  final List<BrowseSwitch> switches;
  final List<FacetSpec> facets;
  final List<SortSpec> sorts;
  final String? sort;
  final bool descending;
  final Map<String, Set<String>> selected;
  final Map<String, int> Function(String facet) counts;
  final void Function(String facet, String value) onToggle;
  final ValueChanged<String> onSort;
  final VoidCallback onOrder;
  final VoidCallback onReset;
  final List<Widget> fields;

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final applied = selected.values.any((v) => v.isNotEmpty);
    return Material(
      color: scheme.surfaceContainerLow,
      elevation: 1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadiusDirectional.horizontal(
          start: Radius.circular(Corner.large),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: (width - 56).clamp(0, 400),
        height: double.infinity,
        child: SafeArea(
          left: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: ShellMetrics.topBar,
                child: Row(
                  children: [
                    const SizedBox(width: 16),
                    _SectionIcon(icon: Symbols.filter_alt_rounded),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        t('common.actions.filter', 'Filter'),
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    if (applied)
                      TextButton(
                        onPressed: onReset,
                        child: Text(t('common.actions.reset', 'Reset')),
                      ),
                    IconButton(
                      tooltip: MaterialLocalizations.of(context)
                          .closeButtonTooltip,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Symbols.close_rounded),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  children: [
                    for (final facet in facets)
                      _Facet(
                        facet: facet,
                        counts: counts(facet.key),
                        selected: selected[facet.key] ?? const {},
                        onToggle: (value) => onToggle(facet.key, value),
                      ),
                    for (final s in switches)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(s.label),
                        value: s.value,
                        onChanged: s.onChanged,
                      ),
                    ...fields,
                    if (sorts.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
                        child: Text(
                          t('catalog.common.sort', 'Sort'),
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      CatalogSortControl(
                        options: [for (final s in sorts) (s.key, s.label)],
                        value: sort,
                        descending: descending,
                        onSort: onSort,
                        onOrder: onOrder,
                      ),
                    ],
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

class _SectionIcon extends StatelessWidget {
  const _SectionIcon({required this.icon});
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 20, color: scheme.onSecondaryContainer),
    );
  }
}

/// A titled group of checkable values with counts (`filter-facet`): open when
/// short or in use, searchable when long.
class _Facet extends StatefulWidget {
  const _Facet({
    required this.facet,
    required this.counts,
    required this.selected,
    required this.onToggle,
  });
  final FacetSpec facet;
  final Map<String, int> counts;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  @override
  State<_Facet> createState() => _FacetState();
}

class _FacetState extends State<_Facet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    final theme = Theme.of(context);
    final values = {...widget.counts.keys, ...widget.selected}.toList()
      ..sort((a, b) {
        final x = int.tryParse(a), y = int.tryParse(b);
        return x != null && y != null ? x.compareTo(y) : a.compareTo(b);
      });
    final options = [
      for (final value in values) (value, widget.facet.option(value)),
    ].where((o) => o.$2.label.toLowerCase().contains(_query)).toList();
    final number = NumberFormat.decimalPattern(t.locale);
    return ExpansionTile(
      initiallyExpanded: widget.selected.isNotEmpty || values.length <= 8,
      tilePadding: EdgeInsets.zero,
      shape: const Border(),
      collapsedShape: const Border(),
      title: Text(widget.facet.label, style: theme.textTheme.titleSmall),
      trailing: Text(
        '${widget.selected.isNotEmpty ? widget.selected.length : values.length}',
        style: theme.textTheme.labelMedium,
      ),
      children: [
        if (values.length > 8)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextField(
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Symbols.search_rounded),
                hintText: t('common.actions.search', 'Search'),
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
            ),
          ),
        for (final (value, option) in options)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: widget.selected.contains(value),
            onChanged:
                (widget.counts[value] ?? 0) == 0 &&
                    !widget.selected.contains(value)
                ? null
                : (_) => widget.onToggle(value),
            title: Row(
              children: [
                if (option.image != null) ...[
                  SizedBox.square(
                    dimension: 24,
                    child: AppImage(candidates: [option.image!]),
                  ),
                  const SizedBox(width: 8),
                ],
                if (!option.imageOnly)
                  Expanded(
                    child: Text(
                      option.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  )
                else
                  const Spacer(),
              ],
            ),
            secondary: Text(
              number.format(widget.counts[value] ?? 0),
              style: theme.textTheme.labelMedium,
            ),
          ),
      ],
    );
  }
}

/// The results a collection shows, in their order, so an entity opened from
/// it can step to its neighbours (the website's previous/next links).
class BrowseSiblings extends InheritedWidget {
  const BrowseSiblings({super.key, required this.items, required super.child});
  final List<Entry> items;

  static List<Entry>? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<BrowseSiblings>()?.items;

  @override
  bool updateShouldNotify(BrowseSiblings old) => !identical(old.items, items);
}

/// The website's pane rail shared by collections: a column above 1200 dp,
/// a horizontal strip below it, with the selected group's heading in the scroll.
class CollectionPane extends StatelessWidget {
  const CollectionPane({
    super.key,
    this.rail,
    this.heading,
    required this.results,
  });
  final BrowseRail? rail;
  final Widget? heading;
  final Widget Function(BuildContext, List<Widget>) results;
  @override
  Widget build(BuildContext context) {
    final padding = pagePadding(context);
    final side = rail != null && MediaQuery.sizeOf(context).width >= 1200;
    final headers = <Widget>[
      if (rail != null && !side)
        SliverToBoxAdapter(child: _PaneRail(rail: rail!, vertical: false)),
      if (heading != null)
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            padding.left,
            MediaQuery.sizeOf(context).width < 600 ? 12 : 16,
            padding.right,
            4,
          ),
          sliver: SliverToBoxAdapter(child: heading),
        ),
    ];
    final content = results(context, headers);
    return side
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 208,
                child: _PaneRail(rail: rail!, vertical: true),
              ),
              Expanded(child: content),
            ],
          )
        : content;
  }
}

class _PaneRail extends StatelessWidget {
  const _PaneRail({required this.rail, required this.vertical});
  final BrowseRail rail;
  final bool vertical;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final meta = rail.items.any((item) => item.meta != null);
    Widget item(RailItem item) => SizedBox(
      width: vertical ? 192 : 148,
      child: Material(
        color: item.value == rail.value
            ? scheme.secondaryContainer
            : vertical
            ? Colors.transparent
            : scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(Corner.medium),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => rail.onSelect(item.value),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 48,
                  width: double.infinity,
                  child: item.image == null
                      ? null
                      : AppImage(candidates: [item.image!]),
                ),
                const SizedBox(height: 8),
                Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (item.meta != null)
                  Text(
                    item.meta!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    final view = ListView.separated(
      scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: vertical ? 8 : 12, vertical: 8),
      itemCount: rail.items.length,
      separatorBuilder: (_, _) =>
          vertical ? const SizedBox(height: 4) : const SizedBox(width: 8),
      itemBuilder: (context, index) => item(rail.items[index]),
    );
    final box = DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: vertical
            ? Border(right: BorderSide(color: scheme.outlineVariant))
            : Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: view,
    );
    return vertical ? box : SizedBox(height: meta ? 128 : 110, child: box);
  }
}
