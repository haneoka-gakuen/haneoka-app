import 'analytics.dart';
import 'site_date.dart';

import 'dart:async';

import 'dart:convert';

import 'package:flutter/material.dart' show Brightness, ColorScheme, ThemeMode;
import 'package:flutter/widgets.dart';
import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import '../gacha_history/history_cloud_sync.dart';
import 'audio.dart';
import 'provider_api.dart';
import 'i18n.dart';
import 'page_data.dart';
import 'render_preferences.dart';
import '../catalog/visuals.dart';
import '../ui/themes.dart';

/// The reader's choices and what follows from them: release server, language,
/// the API client and the site's text for that language.
class AppState extends ChangeNotifier {
  AppState._(this._prefs, this.server, this.text)
    : api = HaneokaApi(server: server),
      themeMode = ThemeMode.values.byName(
        _prefs.getString('themeMode') ?? ThemeMode.system.name,
      ),
      seed = _prefs.getString('seed') ?? 'haneoka',
      compact = _prefs.getBool('compact') ?? false,
      japaneseTitles = _prefs.getBool('japaneseTitles') ?? true,
      difficultyEstimates = _prefs.getBool('difficultyEstimates') ?? false,
      analytics = _prefs.getBool('analytics') ?? true,
      seasonEffects = _prefs.getBool('seasonEffects') ?? true,
      themeCharacters = _storedCharacters(_prefs) {
    SiteDatePreferences.changes.addListener(notifyListeners);
    HistoryCloudSync.instance.start();
    _apis[server] = api;
    api.addListener(_publicDataChanged);
    _pageUpdates = publicPageDataChanges.listen((_) => _publicDataChanged());
    _scheduleThemeBoundary();
    unawaited(_loadThemeCharacters());
  }
  final SharedPreferences _prefs;
  late final RenderPreferences rendering = RenderPreferences(_prefs);
  String server;
  SiteText text;
  HaneokaApi api;
  late final AudioService audio = AudioService(_prefs);
  final _apis = <String, HaneokaApi>{};
  late final StreamSubscription<Object?> _pageUpdates;
  int _publicDataRevision = 0;
  bool _dataChangeQueued = false, _disposed = false;

  Object get publicDataKey => (server, text.locale, _publicDataRevision);

  void _publicDataChanged() {
    if (_disposed || _dataChangeQueued) return;
    _dataChangeQueued = true;
    scheduleMicrotask(() {
      _dataChangeQueued = false;
      if (_disposed) return;
      _publicDataRevision++;
      notifyListeners();
    });
  }

  T _observe<T extends HaneokaApi>(T value) {
    value.addListener(_publicDataChanged);
    return value;
  }

  /// The client for one release server; the selected one is [api].
  HaneokaApi apiFor(String value) =>
      _apis[value] ??= _observe(HaneokaApi(server: value));

  final _providers = <String, ProviderApi>{};

  /// GBP (`bestdori`) or Project Sekai (`sekai`) data in the reading
  /// language's region.
  ProviderApi providerApi(String provider) =>
      _providers['$provider:${text.locale}'] ??= _observe(
        ProviderApi(provider: provider, locale: text.locale),
      );

  /// Both formal releases, for the cross-server catalogue.
  Map<String, HaneokaApi> get catalogApis => {
    for (final value in const ['jp', 'intl']) value: apiFor(value),
  };

  /// The website's appearance: light, dark or the system's, and the theme colour.
  ThemeMode themeMode;
  String seed;

  /// The website's display density, song-title and difficulty switches.
  bool compact;
  bool japaneseTitles;
  bool difficultyEstimates;
  bool analytics;

  Future<void> setFlag(String key, bool value) async {
    switch (key) {
      case 'compact':
        compact = value;
      case 'japaneseTitles':
        japaneseTitles = value;
      case 'difficultyEstimates':
        difficultyEstimates = value;
      case 'analytics':
        analytics = value;
        AppAnalytics.setEnabled(value);
      case 'seasonEffects':
        seasonEffects = value;
    }
    await _prefs.setBool(key, value);
    notifyListeners();
  }

  /// A song's title: Japanese when the reader asked for it (`songTitle`).
  String songTitle(Object? value) =>
      japaneseTitles ? text.textIn(value, 'ja') : text.text(value);

  Future<void> setThemeMode(ThemeMode value) async {
    themeMode = value;
    await _prefs.setString('themeMode', value.name);
    notifyListeners();
  }

  /// Characters with a theme colour, cached so a birthday theme shows from
  /// the first frame.
  List<ThemeCharacter> themeCharacters;

  /// Whether a seasonal theme draws its effect layer.
  bool seasonEffects;
  Timer? _themeTimer;
  final _schemes = <String, (ColorScheme, ColorScheme)>{};

  static List<ThemeCharacter> _storedCharacters(SharedPreferences prefs) {
    try {
      return [
        for (final row
            in jsonDecode(prefs.getString('themeCharacters') ?? '[]') as List)
          ThemeCharacter.fromJson((row as Map).cast<String, Object?>()),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _loadThemeCharacters() async {
    try {
      final visuals = await CatalogVisuals.of(apiFor('jp'));
      final rows = [
        for (final MapEntry(key: id, value: row) in visuals.characters.entries)
          ?_themeCharacter(id, row),
      ];
      final order = {
        for (final MapEntry(key: id, value: row) in visuals.characters.entries)
          id: (row['displayOrder'] as num?)?.toInt() ?? id,
      };
      rows.sort(
        (a, b) => a.bandId != b.bandId
            ? a.bandId - b.bandId
            : order[a.id]! - order[b.id]!,
      );
      if (_disposed || rows.isEmpty) return;
      themeCharacters = rows;
      _schemes.clear();
      await _prefs.setString(
        'themeCharacters',
        jsonEncode([for (final row in rows) row.toJson()]),
      );
      notifyListeners();
    } catch (_) {}
  }

  static ThemeCharacter? _themeCharacter(int id, Map<String, Object?> row) {
    final band = (row['bandId'] as num?)?.toInt() ?? 0;
    final code = row['colorCode'];
    if (band < 1 || band > 5 || code is! String) return null;
    final hex = int.tryParse(code.replaceFirst('#', ''), radix: 16);
    if (hex == null || code.length != 7) return null;
    final color = Color(0xFF000000 | hex);
    // Achromatic colours (white, grey) cannot seed a scheme.
    final max = [color.r, color.g, color.b].reduce((a, b) => a > b ? a : b);
    final min = [color.r, color.g, color.b].reduce((a, b) => a < b ? a : b);
    if (max - min < 0.08) return null;
    final birthday = row['birthday'];
    final month = birthday is Map ? (birthday['month'] as num?)?.toInt() : null;
    final day = birthday is Map ? (birthday['day'] as num?)?.toInt() : null;
    return ThemeCharacter(
      id: id,
      bandId: band,
      color: color,
      face: row['faceImage'] as String? ?? '',
      birthday: month != null && day != null ? (month, day) : null,
    );
  }

  /// Today's automatic theme: a birthday (Japan time; the reader's own
  /// character first), else the latest-opening season.
  ({String seed, Season? season, ThemeCharacter? character})? get autoTheme {
    final now = DateTime.now();
    final born = birthdaysOn(themeCharacters, now)
      ..sort((a, b) => (b.seed == seed ? 1 : 0) - (a.seed == seed ? 1 : 0));
    if (born.isNotEmpty) {
      return (
        seed: born.first.birthdaySeed,
        season: null,
        character: born.first,
      );
    }
    final open = openSeasons(now);
    if (open.isEmpty) return null;
    return (seed: open.last.seed, season: open.last, character: null);
  }

  bool _overridden(String auto) {
    final [value, until] = (_prefs.getString('seasonOverride') ?? '|0').split(
      '|',
    );
    return value == auto &&
        DateTime.now().millisecondsSinceEpoch < (int.tryParse(until) ?? 0);
  }

  bool _open(String value) {
    final now = DateTime.now();
    if (value.startsWith('season-')) {
      return openSeasons(now).any((season) => season.seed == value);
    }
    if (value.startsWith('birthday-')) {
      return birthdaysOn(
        themeCharacters,
        now,
      ).any((c) => c.birthdaySeed == value);
    }
    return true;
  }

  /// The theme the app shows: the automatic one on its day unless the reader
  /// picked a theme while it was on; a picked seasonal theme returns to the
  /// previous one once it closes.
  String get shownSeed {
    final auto = autoTheme;
    if (auto != null && auto.seed != seed && !_overridden(auto.seed)) {
      return auto.seed;
    }
    if (!_open(seed)) return _prefs.getString('seedFallback') ?? 'haneoka';
    return seed;
  }

  /// The shown theme's season or birthday decoration, if any.
  (Motif, IconData, RoundedPolygon)? get shownDecoration {
    final value = shownSeed;
    if (value.startsWith('birthday-')) {
      return (birthdayMotif, birthdayOrnament, birthdayShape);
    }
    for (final season in seasons) {
      if (season.seed == value) {
        return (season.motif, season.ornament, season.shape);
      }
    }
    return null;
  }

  /// Light and dark schemes for a character or seasonal seed.
  (ColorScheme, ColorScheme)? schemesFor(String value) {
    if (_schemes[value] case final cached?) return cached;
    (ColorScheme, ColorScheme)? pair;
    final id = int.tryParse(value.split('-').last);
    if (value.startsWith('character-') || value.startsWith('birthday-')) {
      final character = themeCharacters.where((c) => c.id == id).firstOrNull;
      if (character != null) {
        pair = (
          characterScheme(character.color, Brightness.light),
          characterScheme(character.color, Brightness.dark),
        );
      }
    } else if (value.startsWith('season-')) {
      final season = seasons.where((s) => s.seed == value).firstOrNull;
      if (season != null) {
        pair = (
          seasonScheme(season, Brightness.light),
          seasonScheme(season, Brightness.dark),
        );
      }
    }
    if (pair != null) _schemes[value] = pair;
    return pair;
  }

  /// When the shown automatic theme closes: the next day boundary on which
  /// it is no longer open.
  DateTime _closes(String value) {
    var at = DateTime.now();
    for (var step = 0; step < 60; step++) {
      at = nextThemeBoundary(at);
      final now = at.add(const Duration(seconds: 1));
      final open = value.startsWith('birthday-')
          ? birthdaysOn(
              themeCharacters,
              now,
            ).any((c) => c.birthdaySeed == value)
          : openSeasons(now).any((s) => s.seed == value);
      if (!open) return at;
    }
    return at;
  }

  void _scheduleThemeBoundary() {
    _themeTimer?.cancel();
    final now = DateTime.now();
    _themeTimer = Timer(
      nextThemeBoundary(now).difference(now) + const Duration(seconds: 1),
      () {
        if (_disposed) return;
        notifyListeners();
        _scheduleThemeBoundary();
      },
    );
  }

  Future<void> setSeed(String value) async {
    final auto = autoTheme;
    if (auto != null) {
      await _prefs.setString(
        'seasonOverride',
        '${auto.seed}|${_closes(auto.seed).millisecondsSinceEpoch}',
      );
    }
    if ((value.startsWith('season-') || value.startsWith('birthday-')) &&
        !seed.startsWith('season-') &&
        !seed.startsWith('birthday-')) {
      await _prefs.setString('seedFallback', seed);
    }
    seed = value;
    await _prefs.setString('seed', value);
    notifyListeners();
  }

  static const servers = ['intl', 'jp'];

  static Future<AppState> load(Locale systemLocale) async {
    final prefs = await SharedPreferences.getInstance();
    final locale = prefs.getString('locale') ?? _siteLocale(systemLocale);
    return AppState._(
      prefs,
      prefs.getString('server') ?? 'intl',
      await SiteText.load(locale),
    );
  }

  static String _siteLocale(Locale locale) {
    if (locale.languageCode == 'zh') {
      return locale.scriptCode == 'Hant' ||
              ['TW', 'HK', 'MO'].contains(locale.countryCode)
          ? 'zh-TW'
          : 'zh-CN';
    }
    return SiteText.locales.contains(locale.languageCode)
        ? locale.languageCode
        : 'en';
  }

  Locale get locale {
    final parts = text.locale.split('-');
    return Locale(parts.first, parts.length > 1 ? parts[1] : null);
  }

  Future<void> setServer(String value) async {
    server = value;
    api = apiFor(value);
    await _prefs.setString('server', value);
    notifyListeners();
  }

  Future<void> setLocale(String value) async {
    text = await SiteText.load(value);
    await _prefs.setString('locale', value);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _themeTimer?.cancel();
    HistoryCloudSync.instance.stop();
    unawaited(_pageUpdates.cancel());
    for (final client in {..._apis.values, ..._providers.values}) {
      client.removeListener(_publicDataChanged);
      client.dispose();
    }
    rendering.dispose();
    super.dispose();
  }
}

/// Makes the [AppState] reachable from any widget.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
    : super(notifier: state);
  static AppState of(BuildContext context) => maybeOf(context)!;

  static AppState? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()?.notifier;
}
