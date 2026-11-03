import 'package:flutter/material.dart';

/// The page's own Material colours, so native bars and sheets are the
/// website's surfaces rather than a second theme.
class PageTheme {
  PageTheme({
    required this.dark,
    required this.bar,
    required this.bottom,
    this.duration = Duration.zero,
    required this.background,
    required this.scheme,
    required this.locale,
    ThemeData? data,
  }) : _inheritedData = data;

  final ThemeData? _inheritedData;

  final bool dark;

  /// What the page shows at its top and bottom edges, under the system bars.
  final List<EdgeRun> bar;
  final List<EdgeRun> bottom;

  /// The page's own colour transition, so the bars change in step with it.
  final Duration duration;
  final Color background;
  final ColorScheme scheme;
  final String? locale;

  /// Until the first page reports, the launch screen's colours.
  static PageTheme fallback(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final surface = dark ? const Color(0xFF131316) : const Color(0xFFFCF8FD);
    return PageTheme(
      dark: dark,
      bar: [EdgeRun(surface, 1)],
      bottom: [EdgeRun(surface, 1)],
      background: surface,
      scheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF31356E),
        brightness: brightness,
      ),
      locale: null,
    );
  }

  static PageTheme? read(Object? message, PageTheme previous) {
    if (message is! Map) return null;
    final colors = message['colors'];
    final dark = message['dark'] == true;
    Color? token(String name) => colors is Map ? cssColor(colors[name]) : null;
    final seed = token('primary') ?? previous.scheme.primary;
    final base = previous.dark == dark && previous.scheme.primary == seed
        ? previous.scheme
        : ColorScheme.fromSeed(
            seedColor: seed,
            brightness: dark ? Brightness.dark : Brightness.light,
          );
    final scheme = base.copyWith(
      primary: token('primary'),
      onPrimary: token('on-primary'),
      primaryContainer: token('primary-container'),
      onPrimaryContainer: token('on-primary-container'),
      secondary: token('secondary'),
      onSecondary: token('on-secondary'),
      secondaryContainer: token('secondary-container'),
      onSecondaryContainer: token('on-secondary-container'),
      tertiary: token('tertiary'),
      onTertiary: token('on-tertiary'),
      error: token('error'),
      onError: token('on-error'),
      surface: token('surface'),
      onSurface: token('on-surface'),
      onSurfaceVariant: token('on-surface-variant'),
      surfaceContainerLowest: token('surface-container-lowest'),
      surfaceContainerLow: token('surface-container-low'),
      surfaceContainer: token('surface-container'),
      surfaceContainerHigh: token('surface-container-high'),
      surfaceContainerHighest: token('surface-container-highest'),
      outline: token('outline'),
      outlineVariant: token('outline-variant'),
      inverseSurface: token('inverse-surface'),
      onInverseSurface: token('inverse-on-surface'),
      inversePrimary: token('inverse-primary'),
    );
    final background = cssColor(message['background']) ?? scheme.surface;
    return PageTheme(
      dark: dark,
      bar: EdgeRun.read(message['bar'], background),
      bottom: EdgeRun.read(message['bottom'], background),
      duration: Duration(
        milliseconds: (message['duration'] as num?)?.round() ?? 0,
      ),
      background: background,
      scheme: scheme,
      data: scheme == previous.scheme && background == previous.background
          ? previous.data
          : null,
      locale: switch (message['locale']) {
        final String tag when tag.isNotEmpty => tag,
        _ => null,
      },
    );
  }

  late final ThemeData data =
      _inheritedData ??
      ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: background,
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
        bottomSheetTheme: BottomSheetThemeData(
          backgroundColor: scheme.surfaceContainerLow,
          showDragHandle: true,
        ),
        listTileTheme: const ListTileThemeData(minVerticalPadding: 12),
      );
}

/// One stretch of an edge in one colour; [width] is a fraction of the edge.
class EdgeRun {
  const EdgeRun(this.color, this.width);
  final Color color;
  final double width;

  static List<EdgeRun> read(Object? value, Color fallback) {
    final runs = <EdgeRun>[
      if (value is List)
        for (final run in value.whereType<Map>())
          if (cssColor(run['color']) case final color?)
            EdgeRun(color, (run['width'] as num?)?.toDouble() ?? 0),
    ];
    return runs.isEmpty ? [EdgeRun(fallback, 1)] : runs;
  }

  /// The colour covering most of the edge, for the system icons' contrast.
  static Color dominant(List<EdgeRun> runs) =>
      runs.reduce((a, b) => b.width > a.width ? b : a).color;
}

/// `rgb()`, `rgba()` and `#rrggbb` as computed styles and tokens give them;
/// a transparent value is no colour.
Color? cssColor(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  final hex = RegExp(r'^#([0-9a-fA-F]{6})([0-9a-fA-F]{2})?$').firstMatch(text);
  if (hex != null) {
    final alpha = hex.group(2) == null
        ? 0xFF
        : int.parse(hex.group(2)!, radix: 16);
    if (alpha == 0) return null;
    return Color(int.parse(hex.group(1)!, radix: 16) | alpha << 24);
  }
  final rgb = RegExp(r'^rgba?\(([^)]+)\)$').firstMatch(text);
  if (rgb == null) return null;
  final parts = rgb
      .group(1)!
      .split(RegExp(r'[\s,/]+'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.length < 3) return null;
  final channels = parts
      .take(3)
      .map((p) => double.tryParse(p)?.round())
      .toList();
  if (channels.contains(null)) return null;
  final alpha = parts.length > 3
      ? (parts[3].endsWith('%')
            ? (double.tryParse(parts[3].replaceAll('%', '')) ?? 100) / 100
            : double.tryParse(parts[3]) ?? 1)
      : 1.0;
  if (alpha == 0) return null;
  return Color.fromARGB(
    (alpha * 255).round(),
    channels[0]!,
    channels[1]!,
    channels[2]!,
  );
}
