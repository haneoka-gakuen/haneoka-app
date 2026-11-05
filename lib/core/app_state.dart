import 'package:flutter/widgets.dart';

import 'api.dart';
import 'i18n.dart';
import 'site_origin.dart';

/// What the native account screens need from the app: the release server,
/// the website's text in the page's language and the API client.
class AppState extends ChangeNotifier {
  AppState(this.server, this.text) {
    SiteOrigin.instance.addListener(_siteChanged);
  }

  String server;
  SiteText text;
  HaneokaApi get api => apiFor(server);
  final _apis = <String, HaneokaApi>{};

  /// The website's own song-title choice is not visible natively; titles use
  /// the reading language.
  final bool japaneseTitles = false;
  final bool compact = false;
  final bool difficultyEstimates = false;

  /// Changes when the cached public data should be read again.
  Object get publicDataKey =>
      (server, text.locale, SiteOrigin.instance.value.origin);

  /// Both formal releases, for the cross-server catalogue.
  Map<String, HaneokaApi> get catalogApis => {
    for (final value in const ['jp', 'intl']) value: apiFor(value),
  };

  HaneokaApi apiFor(String value) => _apis[value] ??= HaneokaApi(
    server: value,
    origin: const String.fromEnvironment('HANEOKA_API_ORIGIN').isNotEmpty
        ? const String.fromEnvironment('HANEOKA_API_ORIGIN')
        : SiteOrigin.instance.value.origin,
  );

  void _siteChanged() {
    for (final api in _apis.values) {
      api.dispose();
    }
    _apis.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    SiteOrigin.instance.removeListener(_siteChanged);
    for (final api in _apis.values) {
      api.dispose();
    }
    super.dispose();
  }

  String songTitle(Object? value) => text.text(value);

  Future<void> setLocale(String value) async {
    if (value == text.locale || !SiteText.locales.contains(value)) return;
    text = await SiteText.load(value);
    notifyListeners();
  }

  void setServer(String value) {
    if (value == server) return;
    server = value;
    notifyListeners();
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
