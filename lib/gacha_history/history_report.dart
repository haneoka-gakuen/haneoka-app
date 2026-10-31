import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../core/net.dart';
import '../ui/gacha_prize_card.dart';
import '../ui/app_image.dart';
import '../ui/export_brand.dart';
import '../ui/theme.dart';
import 'history_chart.dart';

class GachaHistoryReportCard {
  const GachaHistoryReportCard({
    required this.name,
    required this.kindLabel,
    required this.quantity,
    this.imageUrl,
    this.attributeImageUrl,
    this.rarityImageUrl,
    this.rarity = 0,
    this.pickup = 0,
  });
  final String name, kindLabel;
  final int quantity;
  final String? imageUrl, attributeImageUrl, rarityImageUrl;
  final int rarity;
  final int pickup;
}

class GachaHistoryReportGroup {
  const GachaHistoryReportGroup({
    required this.label,
    required this.cards,
    this.imageUrl,
  });
  final String label;
  final String? imageUrl;
  final List<GachaHistoryReportCard> cards;
}

class GachaHistoryReportData {
  const GachaHistoryReportData({
    required this.title,
    required this.scope,
    required this.metrics,
    required this.groups,
    required this.charts,
  });
  final List<GachaHistoryChart> charts;
  final String title;
  final List<String> scope;
  final List<(String label, String value)> metrics;
  final List<GachaHistoryReportGroup> groups;
}

typedef GachaHistoryImageExporter = Future<void> Function(
  List<GlobalKey> pages,
);

class GachaHistoryImagePreview extends StatefulWidget {
  const GachaHistoryImagePreview({
    super.key,
    required this.report,
    this.onExport,
  });
  final GachaHistoryReportData report;
  final GachaHistoryImageExporter? onExport;
  @override
  State<GachaHistoryImagePreview> createState() =>
      _GachaHistoryImagePreviewState();
}

class _GachaHistoryImagePreviewState extends State<GachaHistoryImagePreview> {
  final _pages = <List<GachaHistoryReportGroup>>[[]];
  final _keys = <GlobalKey>[];
  bool _started = false, _ready = false, _saving = false;
  String? _error;
  String _t(String key) =>
      AppScope.of(context).text('catalog.gachaHistory.$key');
  @override
  void initState() {
    super.initState();
    var remaining = 36;
    for (final group in widget.report.groups) {
      for (var start = 0; start < group.cards.length;) {
        if (remaining == 0) {
          _pages.add([]);
          remaining = 36;
        }
        final end = (start + remaining).clamp(0, group.cards.length);
        _pages.last.add(
          GachaHistoryReportGroup(
            label: group.label,
            imageUrl: group.imageUrl,
            cards: group.cards.sublist(start, end),
          ),
        );
        remaining -= end - start;
        start = end;
      }
    }
    _keys.addAll([for (final _ in _pages) GlobalKey()]);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final sources = {
      for (final group in widget.report.groups)
        if (group.imageUrl != null) group.imageUrl!,
      for (final group in widget.report.groups)
        for (final card in group.cards)
          ...[
            card.imageUrl,
            card.attributeImageUrl,
            card.rarityImageUrl,
          ].whereType<String>(),
    };
    Future.wait([
      loadExportBrandLogo(),
      for (final source in sources)
        precacheImage(
          CachedNetworkImageProvider(source, cacheManager: artworkCache),
          context,
          onError: (error, stack) {},
        ),
    ]).then((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await WidgetsBinding.instance.endOfFrame;
      await widget.onExport!(_keys);
    } catch (_) {
      if (mounted) setState(() => _error = _t('exportImageFailed'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: SizedBox(
        width: 760,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _t('imagePreview'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: _t('close'),
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    icon: const Icon(Symbols.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    for (var index = 0; index < _pages.length; index++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: RepaintBoundary(
                          key: _keys[index],
                          child: GachaHistoryReportPage(
                            report: widget.report,
                            groups: _pages[index],
                            pageLabel: '${index + 1}/${_pages.length}',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SizedBox(
              height: 24,
              child: Text(
                _error ?? '',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: FilledButton.icon(
                onPressed: !_ready || _saving || widget.onExport == null
                    ? null
                    : _save,
                icon: _saving || !_ready
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Symbols.file_download_rounded),
                label: Text(
                  _t(!_ready || _saving ? 'exportingImage' : 'saveImage'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class GachaHistoryReportPage extends StatelessWidget {
  const GachaHistoryReportPage({
    super.key,
    required this.report,
    required this.groups,
    required this.pageLabel,
  });
  final GachaHistoryReportData report;
  final List<GachaHistoryReportGroup> groups;
  final String pageLabel;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, box) => Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      report.title,
                      style: theme.textTheme.headlineMedium,
                    ),
                  ),
                  const SizedBox(width: 12),
                  ExportBrand(width: (box.maxWidth * 0.42).clamp(120, 184)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            for (final line in report.scope)
              Text(
                line,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 24),
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth < 500 ? 2 : 4;
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final metric in report.metrics)
                      SizedBox(
                        width:
                            (constraints.maxWidth - (columns - 1) * 8) /
                            columns,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainer,
                            borderRadius: BorderRadius.circular(Corner.large),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  metric.$1,
                                  style: theme.textTheme.labelMedium,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  metric.$2,
                                  style: theme.textTheme.titleLarge,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            for (final chart in report.charts)
              Padding(padding: const EdgeInsets.only(top: 16), child: chart),
            for (final group in groups) ...[
              const SizedBox(height: 24),
              Row(
                children: [
                  if (group.imageUrl case final image?) ...[
                    SizedBox(
                      width: 72,
                      height: 40,
                      child: AppImage(
                        candidates: [image],
                        placeholder: const Icon(Symbols.photo_library_rounded),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Text(
                      group.label,
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: scheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = (constraints.maxWidth / 128).floor().clamp(
                    2,
                    6,
                  );
                  return Wrap(
                    spacing: 8,
                    runSpacing: 12,
                    children: [
                      for (final card in group.cards)
                        SizedBox(
                          width:
                              (constraints.maxWidth - (columns - 1) * 8) /
                              columns,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              GachaPrizeCard(
                                label: card.name,
                                rarityValue: card.rarity,
                                image: card.imageUrl,
                                attribute: card.attributeImageUrl,
                                rarity: card.rarityImageUrl,
                                pickup: card.pickup > 0,
                                pickupCount: card.pickup,
                                count: card.quantity,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                card.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelMedium,
                              ),
                              Text(
                                card.kindLabel,
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
            const SizedBox(height: 24),
            Text(
              'Haneoka / $pageLabel',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
