import 'dart:math';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../core/i18n.dart';
import '../shell/links.dart';
import '../ui/app_image.dart';
import '../ui/gacha_prize_card.dart';
import '../ui/export_brand.dart';
import '../ui/detail.dart';
import '../ui/theme.dart';
import 'catalog_screen.dart';
import 'visuals.dart';

num _num(Object? value) =>
    value is num ? value : num.tryParse('${value ?? ''}') ?? 0;

List<Map> _rows(Object? value) =>
    (value as List? ?? const []).whereType<Map>().toList();

/// `member`, `support` or `item` (`prizeKind`).
String prizeKind(Map row) {
  final type = _num(row['resourceType']);
  if (row['kind'] == 'SupportCard' || type == 3) return 'support';
  if (row['kind'] == 'MemberCard' || type == 2) return 'member';
  return 'item';
}

class GachaPrize {
  GachaPrize(this.kind, this.id, this.rarity, this.pickup, this.source);
  final String kind;
  final int id;
  final int rarity;
  final bool pickup;
  final Map source;
  String get key => '$kind:$id';
}

class GachaRun {
  GachaRun(this.option, this.pulls, this.draws, this.cost, this.points);
  final Map option;

  /// One entry per product use, in order.
  final List<List<GachaPrize>> pulls;
  final int draws;
  final num cost;
  final num points;
}

class _Lot {
  _Lot(this.weight, this.rarity, this.kind, this.prizes);
  final num weight;
  final int rarity;
  final String kind;
  final List<(num weight, GachaPrize prize)> prizes;
}

/// The published lot table (`lots`): rarity × card type, then prizes.
List<_Lot> _lots(Map item) => [
  for (final group in _rows(item['rates']))
    if (_num(group['rate']) > 0)
      if ([
            for (final prize in _rows(group['prizes']))
              if (_num(prize['rate']) > 0)
                (
                  _num(prize['rate']),
                  GachaPrize(
                    prizeKind(prize),
                    _num(prize['resourceId']).toInt(),
                    _num(prize['rarity'] ?? group['rarity']).toInt(),
                    prize['pickup'] == true,
                    prize,
                  ),
                ),
          ]
          case final prizes when prizes.isNotEmpty)
        _Lot(
          _num(group['rate']),
          _num(group['rarity']).toInt(),
          group['resourceType'] == 'SupportCard'
              ? 'support'
              : group['resourceType'] == 'MemberCard'
              ? 'member'
              : prizes.first.$2.kind,
          prizes,
        ),
];

/// GachaEnsureType: 2 member card, 3 support card, otherwise no type limit.
List<_Lot> _guaranteedLots(List<_Lot> table, Map option) {
  final rarity = _num(option['guaranteedRarity']).toInt();
  final type = _num(option['guaranteedType']).toInt();
  return [
    for (final lot in table)
      if (type == 2
          ? lot.kind == 'member'
          : type == 3
          ? lot.kind == 'support'
          : true)
        if (lot.prizes.where((p) => p.$2.rarity >= rarity).toList()
            case final prizes when prizes.isNotEmpty)
          _Lot(
            lot.weight *
                prizes.fold<num>(0, (s, p) => s + p.$1) /
                lot.prizes.fold<num>(0, (s, p) => s + p.$1),
            lot.rarity,
            lot.kind,
            prizes,
          ),
  ];
}

T _pick<T>(List<T> entries, num Function(T) weight, Random random) {
  var roll =
      random.nextDouble() * entries.fold<num>(0, (s, e) => s + weight(e));
  for (final entry in entries) {
    roll -= weight(entry);
    if (roll < 0) return entry;
  }
  return entries.last;
}

GachaPrize _draw(List<_Lot> table, Random random) =>
    _pick(_pick(table, (l) => l.weight, random).prizes, (p) => p.$1, random).$2;

int drawCountOf(Map option) => max(1, _num(option['drawCount']).floor());

({int rarity, int count})? gachaGuarantee(Map option) {
  final rarity = _num(option['guaranteedRarity']).toInt();
  final count = min(
    drawCountOf(option),
    max(0, _num(option['guaranteedCount']).toInt()),
  );
  return rarity != 0 && count != 0 ? (rarity: rarity, count: count) : null;
}

bool canSimulate(Map item, Map option) {
  final table = _lots(item);
  return table.isNotEmpty &&
      (gachaGuarantee(option) == null ||
          _guaranteedLots(table, option).isNotEmpty);
}

/// Highest use count the product allows; 0 means unlimited.
int useLimitOf(Map option) => max(0, _num(option['limitCount']).floor());

/// [previousUses] is how often this product was already used, for its
/// first-use price (`simulateGacha`).
GachaRun simulateGacha(
  Map item,
  Map option,
  int uses, {
  int previousUses = 0,
  Random? random,
}) {
  random ??= Random();
  final table = _lots(item);
  final guarantee = gachaGuarantee(option);
  final ensured = guarantee == null
      ? const <_Lot>[]
      : _guaranteedLots(table, option);
  final size = drawCountOf(option);
  final redraw = item['guaranteeRule'] == 'redraw';
  final pulls = <List<GachaPrize>>[];
  num cost = 0;
  for (var use = 0; use < uses; use++) {
    final pull = [
      for (var index = 0; index < size; index++)
        _draw(
          guarantee != null && !redraw && index >= size - guarantee.count
              ? ensured
              : table,
          random,
        ),
    ];
    if (guarantee != null && redraw) {
      var missing =
          guarantee.count -
          pull.where((p) => p.rarity >= guarantee.rarity).length;
      for (var index = size - 1; missing > 0 && index >= 0; index--) {
        if (pull[index].rarity >= guarantee.rarity) continue;
        pull[index] = _draw(ensured, random);
        missing--;
      }
    }
    pulls.add(pull);
    final first = _num(option['firstPrice']);
    cost += previousUses + use == 0 && first > 0
        ? first
        : max<num>(0, _num(option['price']));
  }
  return GachaRun(
    option,
    pulls,
    uses * size,
    cost,
    uses * _num(option['gachaPoint']),
  );
}

const _maxDraws = 3000;
const _kinds = ['member', 'support', 'item'];

/// The recruitment simulator (`renderSimulator`): a draw option and how many
/// times to use it, then every draw or the merged summary.
class GachaSimulator extends StatefulWidget {
  const GachaSimulator({super.key, required this.item, required this.visuals});
  final Map<String, Object?> item;
  final CatalogVisuals? visuals;

  @override
  State<GachaSimulator> createState() => _GachaSimulatorState();
}

class _GachaSimulatorState extends State<GachaSimulator> {
  late final List<Map> _options = _rows(widget.item['drawOptions']);
  late Map? _selected = () {
    // The unlimited product with the most draws, as the page opens on it.
    final sorted = [..._options]
      ..sort((a, b) {
        final limited =
            (useLimitOf(a) > 0 ? 1 : 0) - (useLimitOf(b) > 0 ? 1 : 0);
        return limited != 0 ? limited : drawCountOf(b) - drawCountOf(a);
      });
    return sorted.firstOrNull;
  }();
  final _runs = <GachaRun>[];
  final _uses = TextEditingController(text: '10');
  final _summaryKey = GlobalKey();
  final _resultKey = GlobalKey();
  String _view = 'pulls';
  bool _exporting = false;

  @override
  void dispose() {
    _uses.dispose();
    super.dispose();
  }

  AppState get state => AppScope.of(context);
  SiteText get t => state.text;
  String number(num value) =>
      NumberFormat.decimalPattern(t.locale).format(value);
  String sim(String key, String fallback) =>
      t('catalog.recruitments.$key', fallback);

  int _used(Map option) => _runs
      .where((r) => identical(r.option, option))
      .fold(0, (sum, run) => sum + run.pulls.length);

  /// Uses still possible: the product's limit and the session's ceiling.
  int _maxUses(Map option) {
    final drawn = _runs.fold(0, (sum, run) => sum + run.draws);
    final byDraws = (_maxDraws - drawn) ~/ drawCountOf(option);
    final limit = useLimitOf(option);
    return max(0, limit > 0 ? min(byDraws, limit - _used(option)) : byDraws);
  }

  String _optionLabel(Map option) =>
      '${t.system('draw', '{count} draws', {'count': number(drawCountOf(option))})} / ${t.text(option['currency']).isEmpty ? t.label('free', 'Free') : t.text(option['currency'])}';

  String _kindLabel(String kind) => t.label(
    kind == 'member'
        ? 'memberCards'
        : kind == 'support'
        ? 'supportCards'
        : 'items',
    kind,
  );

  String? _rarityMark(int rarity) =>
      widget.visuals?.mark('RarityIconCenter_${cardRarityName(rarity)}.png');

  Widget _cost(String amount, Object? image, {TextStyle? style}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (image is String && image.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: SizedBox.square(
            dimension: 18,
            child: AppImage(candidates: [state.api.asset(image).toString()]),
          ),
        ),
      Text(amount, style: style),
    ],
  );

  Widget _chip(List<Widget> children) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(Corner.small),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  Widget _up({bool inline = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(Corner.full),
      ),
      child: Text(
        'UP',
        style: TextStyle(
          color: scheme.onPrimary,
          fontSize: 11,
          height: 16 / 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _card(GachaPrize prize, {int count = 0, double aspectRatio = 1}) {
    final source = prize.source;
    final href = source['href'];
    return GachaPrizeCard(
      label: '${t.text(source['name'])} ×${count > 0 ? count : 1}',
      rarityValue: prize.rarity,
      image: source['image'] is String
          ? state.api.asset(source['image'] as String).toString()
          : null,
      attribute: prize.kind == 'item'
          ? null
          : widget.visuals?.cardTypeMark(source['cardType']),
      rarity: prize.kind == 'item' ? null : _rarityMark(prize.rarity),
      pickup: prize.pickup,
      count: count,
      aspectRatio: aspectRatio,
      onTap: href is String && href.isNotEmpty
          ? () => openLink(context, href)
          : null,
    );
  }

  /// One row per recruitment of five or more draws; single draws packed ten
  /// to a row (`runRows`).
  List<(int start, List<GachaPrize> prizes)> _runRows(
    GachaRun run,
    int offset,
  ) {
    final size = drawCountOf(run.option);
    if (size >= 5) {
      return [
        for (final (index, prizes) in run.pulls.indexed)
          (offset + index * size + 1, prizes),
      ];
    }
    final flat = run.pulls.expand((p) => p).toList();
    return [
      for (var index = 0; index * 10 < flat.length; index++)
        (
          offset + index * 10 + 1,
          flat.sublist(index * 10, min(flat.length, index * 10 + 10)),
        ),
    ];
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final scheme = Theme.of(context).colorScheme;
      final textColor = scheme.onSurface;
      final title = t.text(widget.item['title']);
      const ratio = 2.0, margin = 24.0;
      final parts = <ui.Image>[];
      for (final key in [_summaryKey, _resultKey]) {
        final boundary =
            key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
        if (boundary == null) return;
        parts.add(await boundary.toImage(pixelRatio: ratio));
      }
      TextPainter line(String text, double size, Color color, FontWeight w) =>
          TextPainter(
            text: TextSpan(
              text: text,
              style: TextStyle(
                fontFamily: 'Roboto',
                fontSize: size * ratio,
                color: color,
                fontWeight: w,
              ),
            ),
            textDirection: ui.TextDirection.ltr,
            maxLines: 2,
            ellipsis: '…',
          );
      final width = parts.first.width + margin * ratio * 2;
      final heading = line(title, 20, textColor, FontWeight.w700)
        ..layout(maxWidth: width - margin * ratio * 2 - 200 * ratio);
      final logo = await loadExportBrandLogo();
      if (!mounted) return;
      final headerHeight = max(heading.height, 52 * ratio);
      final gap = 16 * ratio;
      final height =
          margin * ratio * 2 +
          headerHeight +
          gap * 3 +
          parts.fold<double>(0, (sum, part) => sum + part.height);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)
        ..drawRect(
          Rect.fromLTWH(0, 0, width, height),
          Paint()..color = scheme.surface,
        );
      var y = margin * ratio;
      heading.paint(canvas, Offset(margin * ratio, y));
      paintExportBrand(
        canvas,
        Theme.of(context),
        Rect.fromLTWH(
          width - margin * ratio - 184 * ratio,
          y,
          184 * ratio,
          52 * ratio,
        ),
        logo,
      );
      y += headerHeight + gap;
      for (final part in parts) {
        canvas.drawImage(part, Offset(margin * ratio, y), Paint());
        y += part.height + gap;
      }
      final image = await recorder.endRecording().toImage(
        width.ceil(),
        height.ceil(),
      );
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      final bytes = data.buffer.asUint8List();
      await FilePicker.saveFile(
        fileName: 'gacha-${widget.item['id'] ?? ''}-$_view.png',
        type: FileType.image,
        bytes: bytes,
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    if (selected == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final item = widget.item;
    final size = drawCountOf(selected);
    final available = _maxUses(selected);
    final uses = (int.tryParse(_uses.text) ?? 1)
        .clamp(1, max(1, available))
        .toInt();
    final simulable = canSimulate(item, selected);
    final ready = simulable && available > 0;
    final guarantee = gachaGuarantee(selected);
    final price = max<num>(0, _num(selected['price']));
    void simulate() {
      setState(() {
        _runs.add(
          simulateGacha(item, selected, uses, previousUses: _used(selected)),
        );
        _uses.text = '$uses';
      });
    }

    final option = DropdownMenu<Map>(
      expandedInsets: EdgeInsets.zero,
      label: Text(t.label('drawOptions', 'Draw options')),
      initialSelection: selected,
      onSelected: (value) => setState(() => _selected = value ?? selected),
      dropdownMenuEntries: [
        for (final option in _options)
          DropdownMenuEntry(value: option, label: _optionLabel(option)),
      ],
    );
    final count = TextField(
      controller: _uses,
      enabled: available > 0,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: sim('useCount', 'Recruitments'),
        suffixText: '= ${number(uses * size)}',
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => ready ? simulate() : null,
    );
    final button = FilledButton.icon(
      onPressed: ready ? simulate : null,
      icon: const Icon(Symbols.casino_rounded, size: 18),
      label: Text(sim('simulate', 'Simulate')),
    );
    final label = theme.textTheme.labelLarge;
    final guaranteeParts = guarantee == null
        ? const <String>[]
        : t
              .system(
                'guaranteedDraws',
                'At least {count} {rarity} or higher',
                {'count': number(guarantee.count), 'rarity': '￼'},
              )
              .split('￼');
    return DetailSection(
      icon: Symbols.casino_rounded,
      title: t.label('simulator', 'Simulator'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) => constraints.maxWidth < 600
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      option,
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(child: count),
                          const SizedBox(width: 12),
                          button,
                        ],
                      ),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(child: option),
                      const SizedBox(width: 12),
                      SizedBox(width: 160, child: count),
                      const SizedBox(width: 12),
                      button,
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _chip([
                if (price > 0)
                  _cost(number(price), selected['currencyImage'], style: label)
                else
                  Text(t.label('free', 'Free'), style: label),
                Text(
                  ' / ${t.system('draw', '{count} draws', {'count': number(size)})}',
                  style: label,
                ),
              ]),
              if (_num(selected['firstPrice']) > 0)
                _chip([
                  Text('${t.label('firstTime', 'First time')} ', style: label),
                  _cost(
                    number(_num(selected['firstPrice'])),
                    selected['currencyImage'],
                    style: label,
                  ),
                ]),
              if (guarantee != null)
                _chip([
                  for (final (index, part) in guaranteeParts.indexed) ...[
                    if (index > 0)
                      if (_rarityMark(guarantee.rarity) case final mark?)
                        SizedBox(
                          height: 18,
                          width: 30,
                          child: AppImage(candidates: [mark]),
                        )
                      else
                        Text(cardRarityName(guarantee.rarity), style: label),
                    Text(part, style: label),
                  ],
                ]),
              if (useLimitOf(selected) > 0)
                _chip([
                  Text(
                    '${t.label('limit', 'Limit')} ${_used(selected)} / ${useLimitOf(selected)}',
                    style: label,
                  ),
                ]),
            ],
          ),
          if (!simulable)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                t.label(
                  'simulationUnavailable',
                  'Complete rates are required to simulate this recruitment.',
                ),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          if (_runs.isNotEmpty) ...[
            const SizedBox(height: 16),
            RepaintBoundary(
              key: _summaryKey,
              child: ColoredBox(color: scheme.surface, child: _summary()),
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: 'pulls',
                      icon: const Icon(Symbols.view_list_rounded),
                      label: Text(sim('viewPulls', 'Each draw')),
                    ),
                    ButtonSegment(
                      value: 'stats',
                      icon: const Icon(Symbols.leaderboard_rounded),
                      label: Text(sim('viewStats', 'Summary')),
                    ),
                  ],
                  selected: {_view},
                  onSelectionChanged: (value) =>
                      setState(() => _view = value.single),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton.icon(
                      onPressed: () => setState(_runs.clear),
                      icon: const Icon(Symbols.restart_alt_rounded, size: 18),
                      label: Text(sim('reset', 'Reset')),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      onPressed: _exporting ? null : _export,
                      icon: const Icon(Symbols.download_rounded, size: 18),
                      label: Text(sim('exportImage', 'Save image')),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            RepaintBoundary(
              key: _resultKey,
              child: ColoredBox(
                color: scheme.surface,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _view == 'pulls' ? _pulls() : _stats(),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _summary() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final draws = _runs.fold(0, (sum, run) => sum + run.draws);
    final points = _runs.fold<num>(0, (sum, run) => sum + run.points);
    final prizes = _runs.expand((r) => r.pulls.expand((p) => p)).toList();
    final counts = <String, Map<int, int>>{};
    for (final prize in prizes) {
      final kind = counts[prize.kind] ??= {};
      kind[prize.rarity] = (kind[prize.rarity] ?? 0) + 1;
    }
    final kinds = _kinds.where(counts.containsKey).toList();
    final rarities = {for (final kind in kinds) ...counts[kind]!.keys}.toList()
      ..sort((a, b) => b - a);
    final costs = <String, (Object? currency, Object? image, num spent)>{};
    for (final run in _runs) {
      final key = '${run.option['currencyImage']}|${run.option['currency']}';
      final previous = costs[key];
      costs[key] = (
        run.option['currency'],
        run.option['currencyImage'],
        (previous?.$3 ?? 0) + run.cost,
      );
    }
    final value = theme.textTheme.titleMedium?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    Widget fact(Widget label, Widget child) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [label, const SizedBox(height: 4), child],
    );
    Widget caption(String text) => Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    );
    final percent = NumberFormat('#,##0.##', t.locale);
    Widget cell(int count) => count == 0
        ? const Text('—')
        : Text.rich(
            TextSpan(
              text: number(count),
              children: [
                TextSpan(
                  text: ' ${percent.format(count / draws * 100)}%',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 24,
          runSpacing: 16,
          children: [
            fact(
              caption(t.label('drawCount', 'Draws')),
              Text(number(draws), style: value),
            ),
            for (final (currency, image, spent) in costs.values)
              fact(
                caption(
                  '${t.label('spent', 'Cost')} / ${t.text(currency).isEmpty ? t.label('free', 'Free') : t.text(currency)}',
                ),
                spent > 0
                    ? _cost(number(spent), image, style: value)
                    : Text(t.label('free', 'Free'), style: value),
              ),
            if (points > 0)
              fact(
                caption(t.label('gachaPoint', 'Gacha points')),
                Text(number(points), style: value),
              ),
            fact(
              _up(inline: true),
              Text(number(prizes.where((p) => p.pickup).length), style: value),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: 40,
            dataRowMinHeight: 40,
            dataRowMaxHeight: 40,
            columns: [
              const DataColumn(label: SizedBox.shrink()),
              for (final rarity in rarities)
                DataColumn(
                  numeric: true,
                  label: switch (_rarityMark(rarity)) {
                    final String mark => SizedBox(
                      height: 20,
                      width: 34,
                      child: AppImage(candidates: [mark]),
                    ),
                    _ => Text(cardRarityName(rarity)),
                  },
                ),
            ],
            rows: [
              for (final kind in kinds)
                DataRow(
                  cells: [
                    DataCell(Text(_kindLabel(kind))),
                    for (final rarity in rarities)
                      DataCell(cell(counts[kind]![rarity] ?? 0)),
                  ],
                ),
              if (kinds.length > 1)
                DataRow(
                  cells: [
                    DataCell(Text(sim('total', 'Total'))),
                    for (final rarity in rarities)
                      DataCell(
                        cell(
                          kinds.fold(
                            0,
                            (sum, kind) => sum + (counts[kind]![rarity] ?? 0),
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _pulls() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    var offset = 0;
    return [
      for (final (index, run) in _runs.indexed)
        () {
          final rows = _runRows(run, offset);
          offset += run.draws;
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      constraints: const BoxConstraints(minWidth: 24),
                      height: 24,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(Corner.full),
                      ),
                      child: Text(
                        '${index + 1}',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: scheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${_optionLabel(run.option)} × ${number(run.pulls.length)}',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    if (run.cost > 0)
                      _cost(
                        number(run.cost),
                        run.option['currencyImage'],
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final narrow = constraints.maxWidth <= 720;
                    final columns = narrow ? 5 : 10;
                    Widget cards(List<GachaPrize> prizes, double width) {
                      final card = (width - 6 * (columns - 1)) / columns;
                      return Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final prize in prizes)
                            SizedBox(width: card, child: _card(prize)),
                        ],
                      );
                    }

                    Widget start(int value) => Text(
                      '#$value',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (first, prizes) in rows)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: narrow
                                ? Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      start(first),
                                      const SizedBox(height: 4),
                                      cards(prizes, constraints.maxWidth),
                                    ],
                                  )
                                : Row(
                                    children: [
                                      SizedBox(width: 48, child: start(first)),
                                      const SizedBox(width: 8),
                                      cards(prizes, constraints.maxWidth - 56),
                                    ],
                                  ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          );
        }(),
    ];
  }

  List<Widget> _stats() {
    final theme = Theme.of(context);
    final merged = <String, (GachaPrize, int)>{};
    for (final prize in _runs.expand((r) => r.pulls.expand((p) => p))) {
      merged[prize.key] = (prize, (merged[prize.key]?.$2 ?? 0) + 1);
    }
    final sorted = merged.values.toList()
      ..sort((a, b) {
        final rarity = b.$1.rarity - a.$1.rarity;
        return rarity != 0 ? rarity : b.$1.id - a.$1.id;
      });
    return [
      for (final kind in _kinds)
        if (sorted.where((e) => e.$1.kind == kind).toList() case final entries
            when entries.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${_kindLabel(kind)}  ${entries.length} / ${entries.fold(0, (sum, e) => sum + e.$2)}',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final minWidth = kind == 'support' ? 148.0 : 84.0;
                    final columns =
                        ((constraints.maxWidth + 8) / (minWidth + 8))
                            .floor()
                            .clamp(1, 99);
                    final width =
                        (constraints.maxWidth - 8 * (columns - 1)) / columns;
                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final (prize, count) in entries)
                          SizedBox(
                            width: width,
                            child: _card(
                              prize,
                              count: count,
                              aspectRatio: kind == 'member'
                                  ? 3 / 4
                                  : kind == 'support'
                                  ? 16 / 9
                                  : 1,
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
    ];
  }
}
