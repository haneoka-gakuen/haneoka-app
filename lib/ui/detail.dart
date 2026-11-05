import 'package:flutter/material.dart';

import '../core/account_resource.dart';

import 'package:material_symbols_icons/symbols.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

import 'account_image.dart';

import 'package:material_new_shapes/material_new_shapes.dart';

import 'app_image.dart';
import 'shapes.dart';
import 'theme.dart';

/// The website's detail layout (`detailLayout`): media beside the sections on
/// wide windows, above them on narrow ones.
class DetailLayout extends StatelessWidget {
  const DetailLayout({super.key, this.media, required this.sections});
  final Widget? media;
  final List<Widget> sections;

  @override
  Widget build(BuildContext context) {
    final padding = EdgeInsets.fromLTRB(
      (MediaQuery.sizeOf(context).width * 0.022).clamp(12.0, 24.0),
      16,
      (MediaQuery.sizeOf(context).width * 0.022).clamp(12.0, 24.0),
      32,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final column = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: sections,
        );
        if (constraints.maxWidth >= 840 && media != null) {
          return SingleChildScrollView(
            padding: padding,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: (constraints.maxWidth * 0.36).clamp(280, 440),
                  child: media,
                ),
                const SizedBox(width: 24),
                Expanded(child: column),
              ],
            ),
          );
        }
        return ListView(
          padding: padding,
          children: [
            if (media != null) ...[media!, const SizedBox(height: 16)],
            column,
          ],
        );
      },
    );
  }
}

/// A detail section (`renderDetailSectionHeading`): an icon in a tonal
/// circle, the title and a count, over its content; long groups fold.
class DetailSection extends StatelessWidget {
  const DetailSection({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    this.count,
    this.folded = false,
    this.large = false,
  });
  final IconData icon;
  final String title;
  final int? count;

  /// The `--h2` heading of a tool page's main sections.
  final bool large;
  final Widget child;
  final bool folded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final heading = Row(
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
            style:
                (large
                        ? theme.textTheme.titleLarge
                        : theme.textTheme.titleMedium)
                    ?.copyWith(fontWeight: FontWeight.w700),
            overflow: TextOverflow.ellipsis,
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
            child: Text('$count', style: theme.textTheme.labelSmall),
          ),
        ],
      ],
    );
    if (folded) {
      return ExpansionTile(
        tilePadding: EdgeInsets.zero,
        shape: const Border(),
        collapsedShape: const Border(),
        title: heading,
        children: [child],
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [heading, const SizedBox(height: 16), child],
      ),
    );
  }
}

/// A folded group inside a section (`fold` / `.detail-fold`): one outlined
/// row with its title and trailing meta; the body opens beneath it.
class DetailFold extends StatelessWidget {
  const DetailFold({
    super.key,
    required this.title,
    required this.child,
    this.meta,
    this.open = false,
    this.onExpansionChanged,
  });
  final String title;
  final String? meta;
  final Widget child;

  /// Whether the fold starts open.
  final bool open;
  final ValueChanged<bool>? onExpansionChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shape = RoundedRectangleBorder(
      side: BorderSide(color: scheme.outlineVariant),
      borderRadius: BorderRadius.circular(Corner.medium),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ExpansionTile(
        initiallyExpanded: open,
        onExpansionChanged: onExpansionChanged,
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        shape: shape,
        collapsedShape: shape,
        backgroundColor: scheme.surfaceContainerLow,
        collapsedBackgroundColor: scheme.surfaceContainerLow,
        tilePadding: const EdgeInsets.only(left: 16, right: 8),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: Text(title, style: theme.textTheme.titleSmall),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (meta != null)
              Text(
                meta!,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(width: 4),
            const Icon(Symbols.expand_more_rounded),
          ],
        ),
        children: [child],
      ),
    );
  }
}

/// One fact: a label above its value, which may be a widget (an emblem).
class Fact {
  const Fact(this.label, this.value, {this.widget, this.full = false});
  final String label;
  final String value;
  final Widget? widget;

  /// Takes the whole row: a description rather than a figure.
  final bool full;
}

/// Facts as the website's `.spec-list`: label above value, two columns.
class SpecList extends StatelessWidget {
  const SpecList({super.key, required this.facts});
  final List<Fact> facts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 280 ? 2 : 1;
        final width = (constraints.maxWidth - (columns - 1) * 16) / columns;
        return Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            for (final fact in facts)
              SizedBox(
                width: fact.full || fact.value.length > 40
                    ? constraints.maxWidth
                    : width,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fact.label,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    fact.widget ??
                        SelectableText(
                          fact.value,
                          style: theme.textTheme.titleMedium,
                        ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The website's difficulty colours (`--md-extended-color-difficulty-*`).
const difficultyColors = [
  Color(0xFF48CADC),
  Color(0xFF56CE79),
  Color(0xFFF4BB3C),
  Color(0xFFE84E43),
  Color(0xFFC950D7),
];

/// The static difficulty picker: one tinted chip per chart with its level.
class DifficultyChips extends StatelessWidget {
  const DifficultyChips({
    super.key,
    required this.levels,
    this.selected,
    this.onSelected,
    this.captions = const {},
  });

  /// A small line under a chip's level: the estimated constant.
  final Map<int, String> captions;

  /// (difficulty index, name, level).
  final List<(int, String, String)> levels;
  final int? selected;
  final ValueChanged<int>? onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (index, name, level) in levels)
          Builder(
            builder: (context) {
              final color = difficultyColors[index.clamp(0, 4)];
              final checked = selected == index;
              return Material(
                color: checked
                    ? color
                    : Color.alphaBlend(
                        color.withValues(alpha: 0.18),
                        scheme.surface,
                      ),
                shape: RoundedRectangleBorder(
                  side: BorderSide(
                    color: Color.lerp(color, scheme.outline, 0.3)!,
                  ),
                  borderRadius: BorderRadius.circular(
                    checked ? Corner.medium : Corner.large,
                  ),
                ),
                child: InkWell(
                  onTap: onSelected == null ? null : () => onSelected!(index),
                  customBorder: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Corner.large),
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: 56,
                      minHeight: 52,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            name,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: checked ? const Color(0xFF121318) : null,
                            ),
                          ),
                          Text(
                            level,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: checked ? const Color(0xFF121318) : null,
                            ),
                          ),
                          if (captions[index] case final caption?)
                            Text(
                              caption,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                                color: checked ? const Color(0xFF121318) : null,
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
}

/// The detail's artwork (`image-gallery`): an outlined card, one image at a
/// time with a zoom button, a pager and a strip of thumbnails.
/// One gallery entry: its address, its caption, and whether the reading
/// locale's own variant is tried first.
class GalleryImage {
  const GalleryImage(
    this.url,
    this.label, {
    this.localized = true,
    this.player,
    this.sourceSize,
    this.bounds,
  });
  final String url;
  final String label;
  final bool localized;
  final Size? sourceSize;
  final Rect? bounds;

  /// A moving entry (the animated card's movie); [url] is its poster.
  final WidgetBuilder? player;
}

class ImageGallery extends StatefulWidget {
  const ImageGallery({
    super.key,
    required this.images,
    this.aspectRatio = 1,
    this.framed = true,
    this.entries,
    this.initial = 0,
    this.natural = false,
    this.stageHeight,
  });

  /// Event and recruitment art: full bleed at the image's own shape
  /// (`image-gallery natural`).
  final bool natural;
  final double? stageHeight;
  final List<String> images;

  /// Captioned entries (`image-gallery` items); [images] when null.
  final List<GalleryImage>? entries;
  final int initial;
  final double aspectRatio;

  /// False where the gallery sits on its own ground (a character's profile).
  final bool framed;
  @override
  State<ImageGallery> createState() => _ImageGalleryState();
}

class _ImageGalleryState extends State<ImageGallery> {
  late int _index = widget.initial;
  late final _pages = PageController(initialPage: widget.initial);
  final _ratios = <String, double>{};

  /// The image's own shape, read once it has decoded.
  double _ratio(String url) {
    final known = _ratios[url];
    if (known != null) return known;
    final stream = nativeNetworkImage(url).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      stream.removeListener(listener);
      final ratio = info.image.width / info.image.height;
      if (mounted && ratio.isFinite && ratio > 0) {
        setState(() => _ratios[url] = ratio);
      }
    }, onError: (_, _) => stream.removeListener(listener));
    stream.addListener(listener);
    return widget.aspectRatio;
  }

  List<GalleryImage> get _entries =>
      widget.entries ??
      [for (final url in widget.images) GalleryImage(url, '')];

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _go(int index) => _pages.animateToPage(
    index,
    duration: Durations.medium2,
    curve: Easing.standard,
  );

  void _zoom(BuildContext context) => Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black,
      pageBuilder: (context, _, _) =>
          _ZoomView(images: [for (final e in _entries) e.url], initial: _index),
      transitionsBuilder: (context, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entries = _entries;
    final images = [for (final e in entries) e.url];
    return DecoratedBox(
      decoration: BoxDecoration(
        border: widget.framed ? Border.all(color: scheme.outlineVariant) : null,
        borderRadius: BorderRadius.circular(Corner.extraLarge),
      ),
      child: Column(
        children: [
          AnimatedSize(
            duration: Durations.short4,
            child: _GalleryStage(
              height: widget.stageHeight,
              aspectRatio: widget.natural
                  ? _ratio(images[_index])
                  : widget.aspectRatio,
              child: Stack(
                children: [
                  PageView(
                    controller: _pages,
                    onPageChanged: (index) => setState(() => _index = index),
                    children: [
                      for (final entry in entries)
                        GestureDetector(
                          onTap: () => _zoom(context),
                          child: Padding(
                            padding: widget.natural || entry.bounds != null
                                ? EdgeInsets.zero
                                : const EdgeInsets.all(16),
                            child: ClipRRect(
                              borderRadius: widget.natural
                                  ? const BorderRadius.vertical(
                                      top: Radius.circular(
                                        Corner.extraLarge - 1,
                                      ),
                                    )
                                  : BorderRadius.zero,
                              child: entry.player != null
                                  ? entry.player!(context)
                                  : _GalleryPicture(
                                      entry: entry,
                                      natural: widget.natural,
                                    ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: IconButton.filledTonal(
                      tooltip: MaterialLocalizations.of(context).expandedHint,
                      onPressed: () => _zoom(context),
                      icon: const Icon(Symbols.zoom_in_rounded),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (images.length > 1) ...[
            if (widget.framed) Divider(height: 1, color: scheme.outlineVariant),
            Row(
              children: [
                IconButton(
                  onPressed: _index == 0 ? null : () => _go(_index - 1),
                  icon: const Icon(Symbols.chevron_left_rounded),
                ),
                Expanded(
                  child: Column(
                    children: [
                      if (entries[_index].label.isNotEmpty)
                        Text(
                          entries[_index].label,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      Text(
                        '${_index + 1} / ${images.length}',
                        textAlign: TextAlign.center,
                        style: entries[_index].label.isEmpty
                            ? theme.textTheme.labelLarge
                            : theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _index == images.length - 1
                      ? null
                      : () => _go(_index + 1),
                  icon: const Icon(Symbols.chevron_right_rounded),
                ),
              ],
            ),
            SizedBox(
              height: 64,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                itemCount: images.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) => InkWell(
                  onTap: () => _go(index),
                  borderRadius: BorderRadius.circular(Corner.small),
                  child: Container(
                    width: 52,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(Corner.small),
                      border: Border.all(
                        width: 2,
                        color: index == _index
                            ? scheme.primary
                            : Colors.transparent,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _GalleryPicture(entry: entries[index]),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Full-screen pinch zoom over the gallery (`photo_view`).
class _ZoomView extends StatefulWidget {
  const _ZoomView({required this.images, required this.initial});
  final List<String> images;
  final int initial;
  @override
  State<_ZoomView> createState() => _ZoomViewState();
}

class _ZoomViewState extends State<_ZoomView> {
  late final _pages = PageController(initialPage: widget.initial);
  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          StreamBuilder<void>(
            stream:
                widget.images.any((url) => isAccountResource(Uri.parse(url)))
                ? AccountResources.instance.changes
                : null,
            builder: (context, _) => PhotoViewGallery.builder(
              key: ValueKey(AccountResources.instance.epoch),
              itemCount: widget.images.length,
              pageController: _pages,
              builder: (context, index) => PhotoViewGalleryPageOptions(
                imageProvider: nativeNetworkImage(widget.images[index]),
                minScale: PhotoViewComputedScale.contained,
                maxScale: PhotoViewComputedScale.covered * 4,
              ),
            ),
          ),
          SafeArea(
            child: IconButton(
              color: Colors.white,
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Symbols.close_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

class _GalleryStage extends StatelessWidget {
  const _GalleryStage({
    required this.aspectRatio,
    required this.child,
    this.height,
  });
  final double aspectRatio;
  final double? height;
  final Widget child;
  @override
  Widget build(BuildContext context) => height == null
      ? AspectRatio(aspectRatio: aspectRatio, child: child)
      : SizedBox(height: height, child: child);
}

/// The website's SVG viewBox applied to the complete source raster.
class _GalleryPicture extends StatelessWidget {
  const _GalleryPicture({required this.entry, this.natural = false});
  final GalleryImage entry;
  final bool natural;
  @override
  Widget build(BuildContext context) {
    final bounds = entry.bounds;
    final size = entry.sourceSize;
    if (bounds == null || size == null) {
      return AppImage(
        candidates: [entry.url],
        localized: entry.localized,
        fit: natural ? BoxFit.cover : BoxFit.contain,
      );
    }
    return FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: bounds.width,
        height: bounds.height,
        child: ClipRect(
          child: Stack(
            children: [
              Positioned(
                left: -bounds.left,
                top: -bounds.top,
                width: size.width,
                height: size.height,
                child: AppImage(
                  candidates: [entry.url],
                  localized: false,
                  fit: BoxFit.fill,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
