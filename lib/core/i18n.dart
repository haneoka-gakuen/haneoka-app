import 'dart:convert';

import 'package:flutter/services.dart';

import '../catalog/labels.g.dart';

/// The website's message catalogues, bundled so every label matches haneoka.org.
class SiteText {
  SiteText._(this.locale, this._messages);
  final String locale;
  final Map<String, Object?> _messages;

  static const locales = ['ja', 'en', 'zh-TW', 'zh-CN', 'ko'];

  static Future<SiteText> load(String locale) async {
    final raw = await rootBundle.loadString('assets/i18n/$locale.json');
    return SiteText._(locale, jsonDecode(raw) as Map<String, Object?>);
  }

  /// Names joined as `Intl.ListFormat` joins them on the website.
  String list(Iterable<String> values) {
    final names = values.where((name) => name.isNotEmpty).toList();
    if (names.length < 2) return names.firstOrNull ?? '';
    final head = names.sublist(0, names.length - 1), last = names.last;
    return switch (locale) {
      'ja' => names.join('、'),
      'ko' => '${head.join(', ')} 및 $last',
      'zh-CN' || 'zh-TW' => '${head.join('、')}和$last',
      _ when names.length == 2 => '${head.first} and $last',
      _ => '${head.join(', ')}, and $last',
    };
  }

  /// A dotted message path, with `{name}` values filled in.
  String call(
    String path, [
    String fallback = '',
    Map<String, Object?> values = const {},
  ]) {
    Object? node = _messages;
    for (final part in path.split('.')) {
      node = switch (node) {
        Map<String, Object?>() => node[part],
        List() => node.elementAtOrNull(int.tryParse(part) ?? -1),
        _ => null,
      };
    }
    var text = node is String ? node : fallback;
    values.forEach((key, value) => text = text.replaceAll('{$key}', '$value'));
    return text;
  }

  /// A catalogue field's label by its id, as the website's `label()`.
  String label(String key, [String? fallback]) {
    final alias = catalogLabelPaths[key] ?? key;
    return call(uiLabelPaths[alias] ?? alias, fallback ?? key);
  }

  /// A rotating-system label (`eventText`): event paths, then system paths.
  String system(
    String key,
    String fallback, [
    Map<String, Object?> values = const {},
  ]) => call(
    eventLabelPaths[key] ??
        systemLabelPaths[key] ??
        catalogLabelPaths[key] ??
        key,
    fallback,
    values,
  );

  /// The site's tuple order for localized game text.
  static const tupleOrder = ['ja', 'en', 'zh-TW', 'zh-CN', 'ko'];
  static const _fallbacks = {
    'zh-TW': ['zh-TW', 'zh-CN', 'ja', 'en'],
    'zh-CN': ['zh-CN', 'zh-TW', 'ja', 'en'],
    'ko': ['ko', 'ja', 'en'],
    'en': ['en', 'ja'],
    'ja': ['ja', 'en'],
  };

  /// Game text read as [locale] would, with that locale's fallbacks.
  String textIn(Object? value, String locale) =>
      SiteText._(locale, _messages).text(value);

  /// The locale supplying the body text also supplies its authored speaker names.
  String textLocale(Object? value) {
    final order = _fallbacks[locale] ?? const ['ja', 'en'];
    for (final code in order) {
      final text = value is List
          ? value.elementAtOrNull(tupleOrder.indexOf(code))
          : value is Map
          ? value[code]
          : null;
      if (text is String && text.trim().isNotEmpty) return code;
    }
    return locale;
  }

  /// Game text: a five-slot tuple, a locale map, or plain text.
  String text(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is num) return '$value';
    final order = _fallbacks[locale] ?? const ['ja', 'en'];
    if (value is List) {
      for (final code in order) {
        final i = tupleOrder.indexOf(code);
        if (i < value.length &&
            value[i] is String &&
            (value[i] as String).trim().isNotEmpty) {
          return value[i] as String;
        }
      }
      return value.whereType<String>().firstWhere(
        (s) => s.trim().isNotEmpty,
        orElse: () => '',
      );
    }
    if (value is Map) {
      for (final code in order) {
        final v = value[code];
        if (v is String && v.trim().isNotEmpty) return v;
      }
      if (value['text'] != null) return text(value['text']);
    }
    return '';
  }
}
