import 'analytics.dart';
import 'site_date.dart';

import 'dart:async';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import '../gacha_history/history_cloud_sync.dart';
import 'audio.dart';
import 'provider_api.dart';
import 'i18n.dart';
import 'page_data.dart';
import 'render_preferences.dart';

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
      analytics = _prefs.getBool('analytics') ?? true {
    SiteDatePreferences.changes.addListener(notifyListeners);
    HistoryCloudSync.instance.start();
    _apis[server] = api;
    api.addListener(_publicDataChanged);
    _pageUpdates = publicPageDataChanges.listen((_) => _publicDataChanged());
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

  Future<void> setSeed(String value) async {
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
