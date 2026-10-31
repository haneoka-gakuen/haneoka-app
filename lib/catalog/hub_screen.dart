import '../core/catalog_source.dart';

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../shell/navigation.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/tile.dart' show pagePadding;
import 'hub_data.dart';

class CatalogHubScreen extends StatefulWidget {
  const CatalogHubScreen({
    super.key,
    required this.navigate,
    this.section = 'library',
  });
  final ValueChanged<String> navigate;
  final String section;
  @override
  State<CatalogHubScreen> createState() => _CatalogHubScreenState();
}

class _CatalogHubScreenState extends State<CatalogHubScreen> {
  int _revision = 0;
  @override
  Widget build(BuildContext context) {
    final text = AppScope.of(context).text;
    return ShellPage(
      title: text(
        'navigation.${widget.section == 'library' ? 'catalog' : widget.section}',
      ),
      actions: [
        BarAction(
          icon: Symbols.refresh_rounded,
          label: text('common.actions.refresh'),
          onPressed: () => setState(() => _revision++),
        ),
      ],
      body: DestinationMosaic(
        key: ValueKey(_revision),
        section: widget.section,
        navigate: (route) {
          final api = CatalogSourceScope.maybeApi(context);
          widget.navigate(
            api == null
                ? route
                : Uri.parse(route)
                      .replace(
                        queryParameters: {
                          ...Uri.parse(route).queryParameters,
                          'server': api.server,
                        },
                      )
                      .toString(),
          );
        },
      ),
    );
  }
}

class DestinationMosaic extends StatefulWidget {
  const DestinationMosaic({
    super.key,
    required this.section,
    required this.navigate,
    this.sliver = false,
    this.padding,
  });
  final String section;
  final ValueChanged<String> navigate;
  final bool sliver;
  final EdgeInsets? padding;
  @override
  State<DestinationMosaic> createState() => _DestinationMosaicState();
}

class _DestinationMosaicState extends State<DestinationMosaic> {
  Future<List<Map<String, Object?>>>? _data;
  Object? _key;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context),
        kind = widget.section == 'library' ? 'catalog' : widget.section;
    final key = (CatalogSourceScope.keyOf(context), kind);
    if (_key != key) {
      _key = key;
      final path = kind == 'home'
          ? '/${CatalogSourceScope.serverOf(context)}/${state.text.locale}/'
          : ['catalog', 'stories'].contains(kind)
          ? '/${CatalogSourceScope.serverOf(context)}/${state.text.locale}/$kind/'
          : '/${state.text.locale}/$kind/';
      _data = hubData(CatalogSourceScope.apiOf(context).origin, path);
    }
  }

  Widget _box(Widget child) =>
      widget.sliver ? SliverToBoxAdapter(child: child) : child;
  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _data,
    builder: (context, snapshot) {
      if (!snapshot.hasData && !snapshot.hasError) {
        return _box(
          const SizedBox(
            height: 320,
            child: Center(child: CircularProgressIndicator()),
          ),
        );
      }
      final entries =
          snapshot.data ??
          [
            for (final section in navSections.where(
              (s) => widget.section == 'home'
                  ? !['home'].contains(s.id)
                  : widget.section == 'community'
                  ? ['community', 'mirrors', 'sekai'].contains(s.id)
                  : s.id == widget.section,
            ))
              for (final item in section.items)
                {
                  'columns': 3,
                  'rows': 2,
                  'visual': 'icon',
                  'links': [
                    {'route': item.route, 'label': item.label},
                  ],
                },
          ];
      final padding = widget.padding ?? pagePadding(context);
      Widget grid(double width, {required bool sliver}) {
        final delegate = _MosaicDelegate(
          entries,
          width > 700 ? 12 : 6,
          width <= 420
              ? 80
              : width <= 700
              ? 90
              : 100,
        );
        final children = SliverChildBuilderDelegate(
          (context, index) =>
              _MosaicTile(data: entries[index], navigate: widget.navigate),
          childCount: entries.length,
        );
        return sliver
            ? SliverGrid(gridDelegate: delegate, delegate: children)
            : GridView.custom(
                padding: padding,
                gridDelegate: delegate,
                childrenDelegate: children,
              );
      }

      return widget.sliver
          ? SliverPadding(
              padding: padding,
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) =>
                    grid(constraints.crossAxisExtent, sliver: true),
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) => grid(
                constraints.maxWidth - padding.horizontal,
                sliver: false,
              ),
            );
    },
  );
}

class _MosaicTile extends StatelessWidget {
  const _MosaicTile({required this.data, required this.navigate});
  final Map<String, Object?> data;
  final ValueChanged<String> navigate;
  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context), colors = Theme.of(context).colorScheme;
    final links = (data['links'] as List).cast<Map>();
    NavItem? item(Map link) =>
        allNavItems.where((v) => v.route == link['route']).firstOrNull;
    final icon = item(links.first)?.icon ?? Symbols.arrow_forward_rounded;
    String label(Map link) =>
        state.text('${link['label'] ?? item(link)?.label}');
    final compound = links.length > 1;
    return Material(
      color: HSLColor.fromColor(colors.surfaceContainer)
          .withSaturation(0)
          .toColor(),
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: compound ? null : () => navigate('${links.first['route']}'),
        child: Column(
          children: [
            Expanded(
              child: ExcludeSemantics(
                child: _HubArt(data: data, icon: icon),
              ),
            ),
            if (compound)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final link in links)
                      FilledButton.tonalIcon(
                        onPressed: () => navigate('${link['route']}'),
                        icon: Icon(item(link)?.icon ?? icon, size: 20),
                        label: Text(label(link)),
                      ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label(links.first),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: (data['columns'] == 6
                            ? (MediaQuery.sizeOf(context).width <= 700
                                  ? Theme.of(context).textTheme.titleLarge
                                  : Theme.of(context).textTheme.headlineSmall)
                            : Theme.of(context).textTheme.titleMedium),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Symbols.arrow_forward_rounded, size: 22),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HubArt extends StatelessWidget {
  const _HubArt({required this.data, required this.icon});
  final Map<String, Object?> data;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context), colors = Theme.of(context).colorScheme;
    Widget image(Object? value, {BoxFit fit = BoxFit.contain}) => AppImage(
      candidates: [
        CatalogSourceScope.apiOf(context).asset('$value').toString(),
      ],
      fit: fit,
      localized: false,
    );
    final visual = data['visual'],
        images = (data['images'] as List? ?? []).cast<String>();
    final team = (data['team'] as List? ?? []).cast<Map>();
    if (visual == 'team' && team.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (final slot in team)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (final kind in ['member', 'snap'])
                        if ((slot[kind] as List).isNotEmpty)
                          Flexible(
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: AspectRatio(
                                aspectRatio: 1,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      image((slot[kind] as List).first),
                                      if ((slot[kind] as List).length > 1)
                                        Positioned(
                                          left: 0,
                                          top: 0,
                                          width: 20,
                                          height: 20,
                                          child: image((slot[kind] as List)[1]),
                                        ),
                                      if ((slot[kind] as List).length > 2)
                                        Positioned(
                                          right: 0,
                                          bottom: 0,
                                          width: 26,
                                          height: 26,
                                          child: image((slot[kind] as List)[2]),
                                        ),
                                      if (slot['leader'] == true &&
                                          kind == 'member')
                                        Positioned(
                                          left: 0,
                                          right: 0,
                                          bottom: 0,
                                          child: ColoredBox(
                                            color: colors.primaryContainer,
                                            child: Text(
                                              state.text(
                                                'navigation.mosaic.leader',
                                              ),
                                              textAlign: TextAlign.center,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .labelSmall
                                                  ?.copyWith(
                                                    color: colors
                                                        .onPrimaryContainer,
                                                  ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    }
    final friendship = data['friendship'] as Map?;
    if (visual == 'friendship' && friendship?['board'] != null) {
      final portraits = friendship!['portraits'] as List;
      final styles = friendship['slots'] as List;
      double point(String style, String key) => double.parse(
        RegExp('--$key:([\\d.−-]+)')
            .firstMatch(style)![1]!
            .replaceAll('−', '-'),
      );
      return Padding(
        padding: const EdgeInsets.all(8),
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: 1312,
            height: 964,
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fill(child: image(friendship['board'])),
                Positioned(
                  left: 144,
                  bottom: -36.6,
                  width: 1024,
                  height: 1024,
                  child: image(friendship['lead']),
                ),
                for (final (i, src) in portraits.indexed)
                  Positioned(
                    left: point(styles[i] as String, 'slot-x') * 13.12 - 175,
                    top: point(styles[i] as String, 'slot-y') * 9.64 - 175,
                    width: 350,
                    height: 350,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        if (friendship['arrow'] != null)
                          Positioned(
                            left:
                                point(styles[i] as String, 'arrow-x') * 3.5 -
                                80,
                            top:
                                point(styles[i] as String, 'arrow-y') * 3.5 -
                                40,
                            width: 160,
                            height: 80,
                            child: Transform.rotate(
                              angle:
                                  point(styles[i] as String, 'arrow-rotation') *
                                  math.pi /
                                  180,
                              child: image(friendship['arrow']),
                            ),
                          ),
                        Positioned.fill(child: image(src)),
                      ],
                    ),
                  ),
                if (friendship['logo'] != null)
                  Positioned(
                    left: 175,
                    top: 86,
                    width: 250,
                    height: 140,
                    child: image(friendship['logo']),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    if (visual == 'discussion') {
      return Center(
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final (i, symbol) in [
              Symbols.forum_rounded,
              Symbols.favorite_rounded,
              Symbols.sell_rounded,
            ].indexed)
              Transform.translate(
                offset: Offset(
                  0,
                  i == 1
                      ? 18
                      : i == 2
                      ? -12
                      : 0,
                ),
                child: Container(
                  width: 72,
                  height: 64,
                  decoration: BoxDecoration(
                    color: i == 1
                        ? colors.tertiaryContainer
                        : colors.secondaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(
                    symbol,
                    size: 40,
                    color: i == 1
                        ? colors.onTertiaryContainer
                        : colors.onSecondaryContainer,
                  ),
                ),
              ),
          ],
        ),
      );
    }
    if (visual == 'personal') {
      return Center(
        child: SizedBox(
          width: 160,
          height: 116,
          child: Stack(
            children: [
              Positioned(
                left: 8,
                top: 18,
                child: Icon(
                  Symbols.account_circle_rounded,
                  size: 88,
                  color: colors.primary,
                ),
              ),
              Positioned(
                right: 4,
                top: 8,
                child: Icon(
                  Symbols.notifications_rounded,
                  size: 40,
                  color: colors.tertiary,
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (images.isEmpty) {
      return Center(child: Icon(icon, size: 64, color: colors.primary));
    }
    if (visual == 'guess') {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 7, sigmaY: 7),
                child: image(images.first, fit: BoxFit.cover),
              ),
              Center(
                child: Icon(
                  Symbols.graphic_eq_rounded,
                  size: 64,
                  color: colors.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (visual == 'puzzle') {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            fit: StackFit.expand,
            children: [
              image(images.first, fit: BoxFit.cover),
              CustomPaint(painter: _HubPuzzlePainter(colors.surfaceContainer)),
            ],
          ),
        ),
      );
    }
    if (visual == 'sonolus' || visual == 'chart') {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(
              painter: _HubScorePainter(
                colors.primary,
                colors.onSurface.withValues(alpha: .12),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: .58,
                heightFactor: .8,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: image(images.first),
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: visual == 'sonolus'
                    ? Image.asset(
                        'assets/settings/sonolus-icon.png',
                        width: 80,
                        height: 80,
                      )
                    : Icon(
                        Symbols.edit_note_rounded,
                        size: 64,
                        color: colors.primary,
                      ),
              ),
            ),
          ],
        ),
      );
    }
    return _LookArt(
      look: '${data['look'] ?? ''}',
      visual: '$visual',
      images: images,
      marks: (data['marks'] as List? ?? const []).cast<Map>(),
      image: image,
    );
  }
}

/// A tile's artwork in its look, as `destination-hub.css` draws it.
class _LookArt extends StatelessWidget {
  const _LookArt({
    required this.look,
    required this.visual,
    required this.images,
    required this.marks,
    required this.image,
  });
  final String look, visual;
  final List<String> images;
  final List<Map> marks;
  final Widget Function(Object? value, {BoxFit fit}) image;

  Map _marks(int index) =>
      index < marks.length ? marks[index] : const <String, Object?>{};

  /// Attribute and rarity on cards, band and attribute on jackets.
  List<Widget> _overlay(int index, double size) {
    final marks = _marks(index);
    return [
      if (marks['attribute'] != null)
        Positioned(
          left: 2,
          top: 2,
          width: size,
          height: size,
          child: image(marks['attribute']),
        ),
      if (marks['rarity'] != null)
        Positioned(
          right: 2,
          bottom: 2,
          width: size * 1.6,
          height: size,
          child: image(marks['rarity']),
        ),
      if (marks['band'] != null)
        Positioned(
          left: 0,
          bottom: 0,
          width: size,
          height: size,
          child: image(marks['band']),
        ),
      if (marks['songBand'] != null)
        Positioned(
          left: 2,
          bottom: 2,
          width: size,
          height: size,
          child: image(marks['songBand']),
        ),
      if (marks['songAttribute'] != null)
        Positioned(
          right: 2,
          bottom: 2,
          width: size,
          height: size,
          child: image(marks['songAttribute']),
        ),
    ];
  }

  Widget _card(
    int index,
    double radius, {
    BoxFit fit = BoxFit.cover,
    ShapeBorder? shape,
    double mark = 22,
  }) => Stack(
    fit: StackFit.expand,
    children: [
      ClipPath(
        clipper: ShapeBorderClipper(
          shape:
              shape ??
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(radius),
              ),
        ),
        child: image(images[index], fit: fit),
      ),
      ..._overlay(index, mark),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final count = images.length;
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth, height = box.maxHeight;
        double centered(int index, double step) =>
            (index - (count - 1) / 2) * step;
        Widget fan({
          required double w,
          required double h,
          required double step,
          required double angle,
          double lift = 0,
          BoxFit fit = BoxFit.cover,
          double radius = 12,
          ShapeBorder? shape,
          Decoration? frame,
          EdgeInsets inset = EdgeInsets.zero,
        }) => Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            for (var i = count - 1; i >= 0; i--)
              Positioned(
                left: (width - w) / 2 + centered(i, step),
                top: (height - h) / 2 + lift * centered(i, 1) * centered(i, 1),
                width: w,
                height: h,
                child: Transform.rotate(
                  angle: centered(i, angle),
                  child: Container(
                    decoration: frame,
                    padding: inset,
                    child: _card(i, radius, fit: fit, shape: shape),
                  ),
                ),
              ),
          ],
        );
        switch (look) {
          case 'arc':
            final h = height * .92, w = h * .72;
            return fan(
              w: w,
              h: h,
              step: count > 1 ? (width - w) / (count - 1) * .9 : 0,
              angle: .08,
              lift: h * .03,
            );
          case 'records':
            final side = height * .84;
            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                for (var i = count - 1; i >= 0; i--) ...[
                  Positioned(
                    left: 12 + i * side * .62 + side * .3,
                    top: (height - side) / 2 + side * .04,
                    width: side * .92,
                    height: side * .92,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colors.surfaceContainerHighest,
                        border: Border.all(
                          color: colors.outlineVariant,
                          width: 6,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 12 + i * side * .62,
                    top: (height - side) / 2,
                    width: side,
                    height: side,
                    child: _card(i, 12),
                  ),
                ],
              ],
            );
          case 'cookies':
            final side = math.min(
              height * .84,
              width / math.max(count, 1) * 1.25,
            );
            return fan(
              w: side,
              h: side,
              step: count > 1 ? (width - side) / (count - 1) : 0,
              angle: 0,
              shape: const CircleBorder(),
            );
          case 'polaroid':
            final h = height * .84, w = h * .82;
            return fan(
              w: w,
              h: h,
              step: count > 1 ? math.min((width - w) / (count - 1), w * .7) : 0,
              angle: .1,
              frame: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              inset: const EdgeInsets.fromLTRB(6, 6, 6, 18),
              radius: 2,
            );
          case 'panels':
            return Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                spacing: 4,
                children: [
                  for (var i = 0; i < count; i++)
                    Expanded(flex: i == 0 ? 2 : 1, child: _card(i, 8)),
                ],
              ),
            );
          case 'bleed':
            return ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (rect) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black, Colors.transparent],
                stops: [.55, 1],
              ).createShader(rect),
              child: SizedBox.expand(
                child: image(images.first, fit: BoxFit.cover),
              ),
            );
          case 'capsule':
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: Column(
                spacing: 6,
                children: [
                  for (var i = 0; i < math.min(count, 2); i++)
                    Expanded(
                      child: _card(i, 999, shape: const StadiumBorder()),
                    ),
                ],
              ),
            );
          case 'scatter':
            final side = math.min(height * .72, width * .46);
            return fan(
              w: side,
              h: side,
              step: count > 1 ? (width - side) / (count - 1) : 0,
              angle: .16,
              fit: BoxFit.contain,
            );
          case 'shelf':
            final side = math.min(height * .7, width / math.max(count, 1));
            return Stack(
              children: [
                Positioned(
                  left: 12,
                  right: 12,
                  top: height * .78,
                  height: 6,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
                for (var i = 0; i < count; i++)
                  Positioned(
                    left: (width - side * count) / 2 + i * side,
                    top: height * .78 - side,
                    width: side,
                    height: side,
                    child: image(images[i]),
                  ),
              ],
            );
          case 'stage':
            final w = width / math.max(count, 1);
            return Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.topCenter,
                        radius: 1,
                        colors: [
                          colors.primary.withValues(alpha: .24),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
                for (var i = 0; i < count; i++)
                  Positioned(
                    left: i * w,
                    top: 0,
                    bottom: 0,
                    width: w,
                    child: image(images[i]),
                  ),
              ],
            );
          default:
            final portrait = ['portraits', 'models'].contains(visual);
            final w = math.min(
              width * (count == 1 ? .88 : .58),
              portrait ? 120.0 : 136.0,
            );
            return fan(
              w: w,
              h: math.min(height - 16, portrait ? w * 1.45 : w),
              step: w * .28,
              angle: .11,
              fit: BoxFit.contain,
            );
        }
      },
    );
  }
}

class _MosaicDelegate extends SliverGridDelegate {
  const _MosaicDelegate(this.tiles, this.columns, this.rowHeight);
  final List<Map<String, Object?>> tiles;
  final int columns;
  final double rowHeight;
  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    const gap = 8.0;
    final unit = (constraints.crossAxisExtent - (columns - 1) * gap) / columns;
    final occupied = <int>{}, geometries = <SliverGridGeometry>[];
    for (final tile in tiles) {
      final span = (tile['columns'] as int) == 4 && columns == 6
              ? 3
              : (tile['columns'] as int).clamp(1, columns),
          height = tile['rows'] as int;
      var row = 0, col = 0;
      bool fits() =>
          col + span <= columns &&
          [
            for (var y = 0; y < height; y++)
              for (var x = 0; x < span; x++) (row + y) * columns + col + x,
          ].every((slot) => !occupied.contains(slot));
      while (!fits()) {
        col++;
        if (col == columns) {
          col = 0;
          row++;
        }
      }
      occupied.addAll([
        for (var y = 0; y < height; y++)
          for (var x = 0; x < span; x++) (row + y) * columns + col + x,
      ]);
      geometries.add(
        SliverGridGeometry(
          scrollOffset: row * (rowHeight + gap),
          crossAxisOffset: col * (unit + gap),
          mainAxisExtent: height * (rowHeight + gap) - gap,
          crossAxisExtent: span * (unit + gap) - gap,
        ),
      );
    }
    return _MosaicGridLayout(geometries);
  }

  @override
  bool shouldRelayout(_MosaicDelegate oldDelegate) =>
      tiles != oldDelegate.tiles ||
      columns != oldDelegate.columns ||
      rowHeight != oldDelegate.rowHeight;
}

class _MosaicGridLayout extends SliverGridLayout {
  const _MosaicGridLayout(this.geometries);
  final List<SliverGridGeometry> geometries;
  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) {
    final index = geometries.indexWhere(
      (g) => g.trailingScrollOffset > scrollOffset,
    );
    return index < 0 ? math.max(0, geometries.length - 1) : index;
  }

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) {
    final index = geometries.lastIndexWhere(
      (g) => g.scrollOffset <= scrollOffset,
    );
    return math.max(0, index);
  }

  @override
  SliverGridGeometry getGeometryForChildIndex(int index) => geometries[index];
  @override
  double computeMaxScrollOffset(int childCount) => geometries
      .take(childCount)
      .fold(0.0, (value, g) => math.max(value, g.trailingScrollOffset));
}

class _HubScorePainter extends CustomPainter {
  const _HubScorePainter(this.note, this.grid);
  final Color note, grid;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 0; i <= 6; i++) {
      final x = i * size.width / 6;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y < size.height; y += 35) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    paint.color = note;
    for (var i = 0; i < 9; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            (i % 6) * size.width / 6,
            (i * .11 % 1) * size.height,
            size.width * .15,
            6,
          ),
          const Radius.circular(3),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_HubScorePainter oldDelegate) =>
      note != oldDelegate.note || grid != oldDelegate.grid;
}

class _HubPuzzlePainter extends CustomPainter {
  const _HubPuzzlePainter(this.gap);
  final Color gap;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = gap
      ..strokeWidth = 4;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(
        Offset(i * size.width / 3, 0),
        Offset(i * size.width / 3, size.height),
        paint,
      );
      canvas.drawLine(
        Offset(0, i * size.height / 3),
        Offset(size.width, i * size.height / 3),
        paint,
      );
    }
    canvas.drawRect(
      Rect.fromLTWH(
        size.width * 2 / 3,
        size.height * 2 / 3,
        size.width / 3,
        size.height / 3,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(_HubPuzzlePainter oldDelegate) => gap != oldDelegate.gap;
}
