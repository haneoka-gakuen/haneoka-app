import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class SiteOrigin extends ValueNotifier<Uri> {
  SiteOrigin._() : super(configured);

  static final configured = Uri.parse(
    const String.fromEnvironment(
      'HANEOKA_ORIGIN',
      defaultValue: 'https://haneoka.org',
    ),
  );
  static final instance = SiteOrigin._();
  static const _production = ['https://haneoka.org', 'https://haneoka.com'];

  List<Uri> get origins => [
    configured,
    if (_production.contains(configured.origin))
      for (final candidate in _production)
        if (candidate != configured.origin) Uri.parse(candidate),
  ];

  bool contains(Uri? uri) =>
      uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.userInfo.isEmpty &&
      uri.hasAuthority &&
      origins.any((site) => site.origin == uri.origin);

  Uri at(Uri origin, Uri page) => page.replace(
    scheme: origin.scheme,
    host: origin.host,
    port: origin.port,
    userInfo: '',
  );

  Uri local(Uri page) => contains(page) ? at(value, page) : page;

  Uri? get alternative =>
      origins.where((site) => site.origin != value.origin).firstOrNull;

  Uri? untried(Set<String> tried) =>
      origins.where((site) => !tried.contains(site.origin)).firstOrNull;

  void select(Uri page) {
    if (!contains(page)) return;
    value = origins.firstWhere((site) => site.origin == page.origin);
  }

  Future<void> load() async {
    final saved = (await SharedPreferences.getInstance()).getString(
      'site.origin',
    );
    if (saved != null && _production.contains(configured.origin)) {
      final uri = Uri.tryParse(saved);
      if (contains(uri)) select(uri!);
    }
  }

  Future<void> remember() async {
    if (_production.contains(configured.origin)) {
      await (await SharedPreferences.getInstance()).setString(
        'site.origin',
        value.origin,
      );
    }
  }
}
