/// Theme seeds beyond the brand and band schemes, as the website has them
/// (`src/lib/themes.ts`): one per character, seasonal themes that open only
/// on their dates, and each character's birthday in Japan time.
library;

import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:material_symbols_icons/symbols.dart';

/// The effect layer a seasonal theme draws.
enum Motif {
  fireworks,
  beans,
  hearts,
  petals,
  sparkles,
  confetti,
  stars,
  lanterns,
  moon,
  bats,
  snow,
}

class Season {
  const Season({
    required this.id,
    required this.key,
    required this.motif,
    required this.ornament,
    required this.shape,
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.open,
  });
  final String id;

  /// i18n key under `settings.seasons`.
  final String key;
  final Motif motif;
  final IconData ornament;

  /// The brand mark's container shape.
  final RoundedPolygon shape;
  final Color primary, secondary, tertiary;
  final bool Function(DateTime local) open;

  String get seed => 'season-$id';
}

bool _between(DateTime d, int m1, int d1, int m2, int d2) {
  final value = d.month * 100 + d.day, from = m1 * 100 + d1, to = m2 * 100 + d2;
  return from <= to
      ? value >= from && value <= to
      : value >= from || value <= to;
}

/// Lunar dates the Chinese calendar gives (`Intl` en-u-ca-chinese): the
/// first day of the New Year window (lunar 12/29), lunar 1/1 and lunar 8/15.
final _lunar = <int, (DateTime, DateTime, DateTime)>{
  2024: (DateTime(2024, 2, 8), DateTime(2024, 2, 10), DateTime(2024, 9, 17)),
  2025: (DateTime(2025, 1, 28), DateTime(2025, 1, 29), DateTime(2025, 10, 6)),
  2026: (DateTime(2026, 2, 16), DateTime(2026, 2, 17), DateTime(2026, 9, 25)),
  2027: (DateTime(2027, 2, 5), DateTime(2027, 2, 7), DateTime(2027, 9, 15)),
  2028: (DateTime(2028, 1, 25), DateTime(2028, 1, 26), DateTime(2028, 10, 3)),
  2029: (DateTime(2029, 2, 12), DateTime(2029, 2, 13), DateTime(2029, 9, 22)),
  2030: (DateTime(2030, 2, 1), DateTime(2030, 2, 2), DateTime(2030, 9, 12)),
  2031: (DateTime(2031, 1, 22), DateTime(2031, 1, 23), DateTime(2031, 10, 1)),
  2032: (DateTime(2032, 2, 10), DateTime(2032, 2, 11), DateTime(2032, 9, 19)),
  2033: (DateTime(2033, 1, 29), DateTime(2033, 1, 31), DateTime(2033, 9, 8)),
  2034: (DateTime(2034, 2, 17), DateTime(2034, 2, 19), DateTime(2034, 9, 27)),
  2035: (DateTime(2035, 2, 6), DateTime(2035, 2, 8), DateTime(2035, 9, 16)),
  2036: (DateTime(2036, 1, 26), DateTime(2036, 1, 28), DateTime(2036, 10, 4)),
  2037: (DateTime(2037, 2, 13), DateTime(2037, 2, 15), DateTime(2037, 9, 24)),
  2038: (DateTime(2038, 2, 2), DateTime(2038, 2, 4), DateTime(2038, 9, 13)),
  2039: (DateTime(2039, 1, 23), DateTime(2039, 1, 24), DateTime(2039, 10, 2)),
  2040: (DateTime(2040, 2, 11), DateTime(2040, 2, 12), DateTime(2040, 9, 20)),
  2041: (DateTime(2041, 1, 31), DateTime(2041, 2, 1), DateTime(2041, 9, 10)),
  2042: (DateTime(2042, 1, 20), DateTime(2042, 1, 22), DateTime(2042, 9, 28)),
  2043: (DateTime(2043, 2, 8), DateTime(2043, 2, 10), DateTime(2043, 9, 17)),
  2044: (DateTime(2044, 1, 28), DateTime(2044, 1, 30), DateTime(2044, 10, 5)),
  2045: (DateTime(2045, 2, 15), DateTime(2045, 2, 17), DateTime(2045, 9, 25)),
};

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

bool _lunarNewYear(DateTime d) {
  final day = _day(d);
  for (final year in [d.year, d.year + 1]) {
    final row = _lunar[year];
    if (row == null) continue;
    final (start, first, _) = row;
    if (!day.isBefore(start) &&
        !day.isAfter(first.add(const Duration(days: 13)))) {
      return true;
    }
  }
  return false;
}

bool _midAutumn(DateTime d) {
  final row = _lunar[d.year];
  if (row == null) return false;
  final day = _day(d), moon = row.$3;
  return !day.isBefore(moon.subtract(const Duration(days: 5))) &&
      !day.isAfter(moon.add(const Duration(days: 2)));
}

bool _newYearOpen(DateTime d) => _between(d, 12, 31, 1, 7);
bool _setsubunOpen(DateTime d) => _between(d, 2, 1, 2, 3);
bool _lunarNewYearOpen(DateTime d) => _lunarNewYear(d);
bool _valentineOpen(DateTime d) => _between(d, 2, 7, 2, 14);
bool _hinamatsuriOpen(DateTime d) => _between(d, 2, 26, 3, 3);
bool _whiteDayOpen(DateTime d) => _between(d, 3, 7, 3, 14);
bool _hanamiOpen(DateTime d) => _between(d, 3, 20, 4, 10);
bool _aprilFoolsOpen(DateTime d) => d.month == 4 && d.day == 1;
bool _childrensDayOpen(DateTime d) => _between(d, 5, 1, 5, 5);
bool _tanabataOpen(DateTime d) => _between(d, 7, 1, 7, 7);
bool _obonOpen(DateTime d) => _between(d, 8, 13, 8, 16);
bool _midAutumnOpen(DateTime d) => _midAutumn(d);
bool _halloweenOpen(DateTime d) => _between(d, 10, 17, 10, 31);
bool _christmasOpen(DateTime d) => _between(d, 12, 18, 12, 26);

final seasons = <Season>[
  Season(
    id: 'new-year',
    key: 'newYear',
    motif: Motif.fireworks,
    ornament: Symbols.celebration_rounded,
    shape: MaterialShapes.verySunny,
    primary: Color(0xFFB3202F),
    secondary: Color(0xFF8A6D3B),
    tertiary: Color(0xFFC99A1E),
    open: _newYearOpen,
  ),
  Season(
    id: 'setsubun',
    key: 'setsubun',
    motif: Motif.beans,
    ornament: Symbols.mood_bad_rounded,
    shape: MaterialShapes.cookie4Sided,
    primary: Color(0xFFA0522D),
    secondary: Color(0xFF6D6A4F),
    tertiary: Color(0xFF3F7A3A),
    open: _setsubunOpen,
  ),
  Season(
    id: 'lunar-new-year',
    key: 'lunarNewYear',
    motif: Motif.fireworks,
    ornament: Symbols.festival_rounded,
    shape: MaterialShapes.cookie9Sided,
    primary: Color(0xFFC62A1F),
    secondary: Color(0xFF9C5A2C),
    tertiary: Color(0xFFD9A227),
    open: _lunarNewYearOpen,
  ),
  Season(
    id: 'valentine',
    key: 'valentine',
    motif: Motif.hearts,
    ornament: Symbols.favorite_rounded,
    shape: MaterialShapes.clover4Leaf,
    primary: Color(0xFFC2185B),
    secondary: Color(0xFF8D5A4A),
    tertiary: Color(0xFF7B4A2B),
    open: _valentineOpen,
  ),
  Season(
    id: 'hinamatsuri',
    key: 'hinamatsuri',
    motif: Motif.petals,
    ornament: Symbols.filter_vintage_rounded,
    shape: MaterialShapes.flower,
    primary: Color(0xFFE07A96),
    secondary: Color(0xFF8F7A6A),
    tertiary: Color(0xFF5F8F4A),
    open: _hinamatsuriOpen,
  ),
  Season(
    id: 'white-day',
    key: 'whiteDay',
    motif: Motif.sparkles,
    ornament: Symbols.redeem_rounded,
    shape: MaterialShapes.cookie12Sided,
    primary: Color(0xFF4F7FBF),
    secondary: Color(0xFF6D7A90),
    tertiary: Color(0xFFD27AA0),
    open: _whiteDayOpen,
  ),
  Season(
    id: 'hanami',
    key: 'hanami',
    motif: Motif.petals,
    ornament: Symbols.local_florist_rounded,
    shape: MaterialShapes.flower,
    primary: Color(0xFFD0688F),
    secondary: Color(0xFF9A6F7C),
    tertiary: Color(0xFF6E9A4C),
    open: _hanamiOpen,
  ),
  Season(
    id: 'april-fools',
    key: 'aprilFools',
    motif: Motif.confetti,
    ornament: Symbols.sentiment_very_satisfied_rounded,
    shape: MaterialShapes.gem,
    primary: Color(0xFF7A3FB0),
    secondary: Color(0xFF3B8A6E),
    tertiary: Color(0xFFE0A100),
    open: _aprilFoolsOpen,
  ),
  Season(
    id: 'childrens-day',
    key: 'childrensDay',
    motif: Motif.confetti,
    ornament: Symbols.toys_rounded,
    shape: MaterialShapes.sunny,
    primary: Color(0xFF2F7FD0),
    secondary: Color(0xFF5F7A8F),
    tertiary: Color(0xFFE2504A),
    open: _childrensDayOpen,
  ),
  Season(
    id: 'tanabata',
    key: 'tanabata',
    motif: Motif.stars,
    ornament: Symbols.auto_awesome_rounded,
    shape: MaterialShapes.sunny,
    primary: Color(0xFF2C4A9A),
    secondary: Color(0xFF5B6A8F),
    tertiary: Color(0xFFD4A72C),
    open: _tanabataOpen,
  ),
  Season(
    id: 'obon',
    key: 'obon',
    motif: Motif.lanterns,
    ornament: Symbols.candle_rounded,
    shape: MaterialShapes.arch,
    primary: Color(0xFF3D5A9A),
    secondary: Color(0xFF6A6F80),
    tertiary: Color(0xFFE08A3A),
    open: _obonOpen,
  ),
  Season(
    id: 'mid-autumn',
    key: 'midAutumn',
    motif: Motif.moon,
    ornament: Symbols.bedtime_rounded,
    shape: MaterialShapes.circle,
    primary: Color(0xFFB9721A),
    secondary: Color(0xFF7D6A4F),
    tertiary: Color(0xFF3D4F8F),
    open: _midAutumnOpen,
  ),
  Season(
    id: 'halloween',
    key: 'halloween',
    motif: Motif.bats,
    ornament: Symbols.skull_rounded,
    shape: MaterialShapes.cookie6Sided,
    primary: Color(0xFFD9690B),
    secondary: Color(0xFF6F5A4A),
    tertiary: Color(0xFF6B3FA0),
    open: _halloweenOpen,
  ),
  Season(
    id: 'christmas',
    key: 'christmas',
    motif: Motif.snow,
    ornament: Symbols.featured_seasonal_and_gifts_rounded,
    shape: MaterialShapes.cookie12Sided,
    primary: Color(0xFF1F7A4D),
    secondary: Color(0xFF5F7466),
    tertiary: Color(0xFFC0392B),
    open: _christmasOpen,
  ),
];

/// The birthday theme's decoration; its colour is the character's.
const birthdayMotif = Motif.confetti;
const birthdayOrnament = Symbols.cake_rounded;
final birthdayShape = MaterialShapes.softBurst;

/// A character as the theme picker and birthday themes read it.
class ThemeCharacter {
  const ThemeCharacter({
    required this.id,
    required this.bandId,
    required this.color,
    required this.face,
    required this.birthday,
  });
  final int id, bandId;
  final Color color;
  final String face;

  /// (month, day), or null.
  final (int, int)? birthday;

  String get seed => 'character-$id';
  String get birthdaySeed => 'birthday-$id';

  Map<String, Object?> toJson() => {
    'id': id,
    'bandId': bandId,
    'color': color.toARGB32(),
    'face': face,
    'birthday': birthday == null ? null : [birthday!.$1, birthday!.$2],
  };

  static ThemeCharacter fromJson(Map<String, Object?> json) {
    final birthday = json['birthday'] as List?;
    return ThemeCharacter(
      id: json['id']! as int,
      bandId: json['bandId']! as int,
      color: Color(json['color']! as int),
      face: json['face']! as String,
      birthday: birthday == null
          ? null
          : (birthday[0] as int, birthday[1] as int),
    );
  }
}

/// The date in Japan, where the game keeps its characters' birthdays.
(int, int) japanDay(DateTime now) {
  final japan = now.toUtc().add(const Duration(hours: 9));
  return (japan.month, japan.day);
}

List<Season> openSeasons(DateTime now) => [
  for (final season in seasons)
    if (season.open(now)) season,
];

List<ThemeCharacter> birthdaysOn(
  Iterable<ThemeCharacter> characters,
  DateTime now,
) {
  final today = japanDay(now);
  return [
    for (final character in characters)
      if (character.birthday == today) character,
  ];
}

/// The next moment a day boundary may change the automatic theme: local or
/// Japan midnight, whichever comes first.
DateTime nextThemeBoundary(DateTime now) {
  final local = DateTime(now.year, now.month, now.day + 1);
  final utc = now.toUtc().add(const Duration(hours: 9));
  final japan = DateTime.utc(
    utc.year,
    utc.month,
    utc.day + 1,
  ).subtract(const Duration(hours: 9)).toLocal();
  return local.isBefore(japan) ? local : japan;
}

/// A character's scheme: fidelity to its colour, like the band schemes.
ColorScheme characterScheme(Color color, Brightness brightness) =>
    ColorScheme.fromSeed(
      seedColor: color,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );

/// A season's scheme from its triad, as the website generates it.
ColorScheme seasonScheme(Season season, Brightness brightness) {
  final primary = Hct.fromInt(season.primary.toARGB32());
  final tertiary = Hct.fromInt(season.tertiary.toARGB32());
  final scheme = DynamicScheme(
    sourceColorHct: primary,
    variant: Variant.tonalSpot,
    contrastLevel: 0,
    isDark: brightness == Brightness.dark,
    primaryPalette: TonalPalette.of(
      primary.hue,
      primary.chroma < 48 ? 48 : primary.chroma,
    ),
    secondaryPalette: TonalPalette.of(
      Hct.fromInt(season.secondary.toARGB32()).hue,
      20,
    ),
    tertiaryPalette: TonalPalette.of(
      tertiary.hue,
      tertiary.chroma < 40 ? 40 : tertiary.chroma,
    ),
    neutralPalette: TonalPalette.of(primary.hue, 6),
    neutralVariantPalette: TonalPalette.of(primary.hue, 10),
  );
  Color c(DynamicColor color) => Color(color.getArgb(scheme));
  return ColorScheme(
    brightness: brightness,
    primary: c(MaterialDynamicColors.primary),
    onPrimary: c(MaterialDynamicColors.onPrimary),
    primaryContainer: c(MaterialDynamicColors.primaryContainer),
    onPrimaryContainer: c(MaterialDynamicColors.onPrimaryContainer),
    primaryFixed: c(MaterialDynamicColors.primaryFixed),
    primaryFixedDim: c(MaterialDynamicColors.primaryFixedDim),
    onPrimaryFixed: c(MaterialDynamicColors.onPrimaryFixed),
    onPrimaryFixedVariant: c(MaterialDynamicColors.onPrimaryFixedVariant),
    secondary: c(MaterialDynamicColors.secondary),
    onSecondary: c(MaterialDynamicColors.onSecondary),
    secondaryContainer: c(MaterialDynamicColors.secondaryContainer),
    onSecondaryContainer: c(MaterialDynamicColors.onSecondaryContainer),
    secondaryFixed: c(MaterialDynamicColors.secondaryFixed),
    secondaryFixedDim: c(MaterialDynamicColors.secondaryFixedDim),
    onSecondaryFixed: c(MaterialDynamicColors.onSecondaryFixed),
    onSecondaryFixedVariant: c(MaterialDynamicColors.onSecondaryFixedVariant),
    tertiary: c(MaterialDynamicColors.tertiary),
    onTertiary: c(MaterialDynamicColors.onTertiary),
    tertiaryContainer: c(MaterialDynamicColors.tertiaryContainer),
    onTertiaryContainer: c(MaterialDynamicColors.onTertiaryContainer),
    tertiaryFixed: c(MaterialDynamicColors.tertiaryFixed),
    tertiaryFixedDim: c(MaterialDynamicColors.tertiaryFixedDim),
    onTertiaryFixed: c(MaterialDynamicColors.onTertiaryFixed),
    onTertiaryFixedVariant: c(MaterialDynamicColors.onTertiaryFixedVariant),
    error: c(MaterialDynamicColors.error),
    onError: c(MaterialDynamicColors.onError),
    errorContainer: c(MaterialDynamicColors.errorContainer),
    onErrorContainer: c(MaterialDynamicColors.onErrorContainer),
    surface: c(MaterialDynamicColors.surface),
    onSurface: c(MaterialDynamicColors.onSurface),
    surfaceDim: c(MaterialDynamicColors.surfaceDim),
    surfaceBright: c(MaterialDynamicColors.surfaceBright),
    surfaceContainerLowest: c(MaterialDynamicColors.surfaceContainerLowest),
    surfaceContainerLow: c(MaterialDynamicColors.surfaceContainerLow),
    surfaceContainer: c(MaterialDynamicColors.surfaceContainer),
    surfaceContainerHigh: c(MaterialDynamicColors.surfaceContainerHigh),
    surfaceContainerHighest: c(MaterialDynamicColors.surfaceContainerHighest),
    onSurfaceVariant: c(MaterialDynamicColors.onSurfaceVariant),
    outline: c(MaterialDynamicColors.outline),
    outlineVariant: c(MaterialDynamicColors.outlineVariant),
    shadow: c(MaterialDynamicColors.shadow),
    scrim: c(MaterialDynamicColors.scrim),
    inverseSurface: c(MaterialDynamicColors.inverseSurface),
    onInverseSurface: c(MaterialDynamicColors.inverseOnSurface),
    inversePrimary: c(MaterialDynamicColors.inversePrimary),
    surfaceTint: c(MaterialDynamicColors.surfaceTint),
  );
}
