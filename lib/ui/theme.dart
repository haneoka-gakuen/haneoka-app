import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'fonts.dart';
import 'schemes.g.dart';

/// Material 3 shape scale, as the website's tokens define it.
abstract final class Corner {
  static const extraSmall = 4.0,
      small = 8.0,
      medium = 12.0,
      large = 16.0,
      extraLarge = 28.0,
      full = 999.0;
}

/// The website's layout metrics.
abstract final class ShellMetrics {
  static const topBar = 64.0;
  static const rail = 96.0;
  static const drawer = 280.0;
  static const paneGap = 16.0;
  static const compact = 600.0;
  static const expanded = 1200.0;
}

/// The website's type scale (`--md-sys-typescale-*`): M3 sizes, no tracking.
TextTheme _typescale(Color color, List<String> fontFallback) {
  TextStyle style(double size, double height, FontWeight weight) => TextStyle(
    fontFamily: appFont,
    fontFamilyFallback: fontFallback,
    fontSize: size,
    height: height / size,
    fontWeight: weight,
    letterSpacing: 0,
    color: color,
  );
  const regular = FontWeight.w400, medium = FontWeight.w500;
  return TextTheme(
    displayLarge: style(57, 64, regular),
    displayMedium: style(45, 52, regular),
    displaySmall: style(36, 44, regular),
    headlineLarge: style(32, 40, regular),
    headlineMedium: style(28, 36, regular),
    headlineSmall: style(24, 32, regular),
    titleLarge: style(22, 28, regular),
    titleMedium: style(16, 24, medium),
    titleSmall: style(14, 20, medium),
    bodyLarge: style(16, 24, regular),
    bodyMedium: style(14, 20, regular),
    bodySmall: style(12, 16, regular),
    labelLarge: style(14, 20, medium),
    labelMedium: style(12, 16, medium),
    labelSmall: style(11, 16, medium),
  );
}

ThemeData haneokaTheme(
  Brightness brightness, {
  String seed = 'haneoka',
  (ColorScheme, ColorScheme)? schemes,
  bool backdrop = false,
  bool compact = false,
  Locale locale = const Locale('ja'),
}) {
  final (light, dark) =
      schemes ?? haneokaSchemes[seed] ?? haneokaSchemes['haneoka']!;
  final scheme = brightness == Brightness.dark ? dark : light;
  final fontFallback = appFontFallback(locale);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
    fontFamily: appFont,
    fontFamilyFallback: fontFallback,
    textTheme: _typescale(scheme.onSurface, fontFallback),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
      },
    ),
    scaffoldBackgroundColor: backdrop
        ? Colors.transparent
        : scheme.surfaceContainer,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      toolbarHeight: ShellMetrics.topBar,
      titleSpacing: 16,
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Corner.medium),
      ),
    ),
    listTileTheme: const ListTileThemeData(shape: StadiumBorder()),
    searchBarTheme: SearchBarThemeData(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
      constraints: const BoxConstraints(
        minHeight: 48,
        maxHeight: 48,
        maxWidth: 360,
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.secondaryContainer,
      minWidth: ShellMetrics.rail,
    ),
    navigationDrawerTheme: NavigationDrawerThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.secondaryContainer,
      indicatorShape: const StadiumBorder(),
    ),
  );
}
