import 'package:flutter/widgets.dart';

import 'api.dart';
import 'i18n.dart';

/// What the native account screens need from the app: the release server,
/// the website's text in the page's language and the API client.
class AppState extends ChangeNotifier {
  AppState(this.server, this.text) : api = HaneokaApi(server: server) {
    _apis[server] = api;
  }

  String server;
  SiteText text;
  HaneokaApi api;
  final _apis = <String, HaneokaApi>{};

  /// The website's own song-title choice is not visible natively; titles use
  /// the reading language.
  final bool japaneseTitles = false;
  final bool compact = false;
  final bool difficultyEstimates = false;

  /// Changes when the cached public data should be read again.
  Object get publicDataKey => (server, text.locale);

  /// Both formal releases, for the cross-server catalogue.
  Map<String, HaneokaApi> get catalogApis => {
    for (final value in const ['jp', 'intl']) value: apiFor(value),
  };

  HaneokaApi apiFor(String value) => _apis[value] ??= HaneokaApi(server: value);

  String songTitle(Object? value) => text.text(value);

  Future<void> setLocale(String value) async {
    if (value == text.locale || !SiteText.locales.contains(value)) return;
    text = await SiteText.load(value);
    notifyListeners();
  }

  void setServer(String value) {
    if (value == server) return;
    server = value;
    api = apiFor(value);
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
