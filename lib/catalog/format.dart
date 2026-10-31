import '../core/site_date.dart';


import '../core/i18n.dart';

/// Turns API values into text: localized tuples, dates, birthdays and lists.
class ValueFormat {
  ValueFormat(this.text) : _date = SiteDate.day(text.locale);
  final SiteText text;
  final SiteDate _date;

  static bool isTimestampKey(String key) =>
      key.endsWith('At') || key.endsWith('Date');

  /// A per-server time tuple has a number in its first slot; a text tuple has strings.
  static bool _isTimeTuple(Object? value) =>
      value is List &&
      value.isNotEmpty &&
      value.every((v) => v == null || v is num);

  String format(String key, Object? value) {
    if (value == null) return '';
    if (isTimestampKey(key)) {
      final ms = _isTimeTuple(value)
          ? (value as List).whereType<num>().firstOrNull
          : value is num
          ? value
          : null;
      if (ms != null && ms > 1e11) {
        return _date.format(DateTime.fromMillisecondsSinceEpoch(ms.toInt()));
      }
    }
    if (key == 'birthday' && value is Map) {
      return '${value['month'] ?? '—'}/${value['day'] ?? '—'}';
    }
    if (value is List && value.isNotEmpty && value.every((v) => v is String)) {
      final localized = text.text(value);
      if (value.length == 5) return localized;
      return value.join(' · ');
    }
    if (value is List && value.every((v) => v is num)) return value.join(', ');
    if (value is bool) return value ? '✓' : '—';
    return text.text(value);
  }

  /// Whether a value reads as one line rather than a structure.
  static bool isScalar(Object? value) =>
      value is String ||
      value is num ||
      value is bool ||
      (value is List &&
          (value.every((v) => v is String) ||
              value.every((v) => v == null || v is num))) ||
      (value is Map && value.containsKey('month') && value.containsKey('day'));
}

/// Every image path in a record, in order of appearance.
List<String> imagesIn(Object? value, [int depth = 0]) {
  if (depth > 3) return const [];
  return switch (value) {
    String()
        when value.startsWith('/assets/') &&
            RegExp(
              r'\.(png|jpe?g|webp)$',
              caseSensitive: false,
            ).hasMatch(value) =>
      [value],
    Map() => [for (final v in value.values) ...imagesIn(v, depth + 1)],
    List() => [for (final v in value.take(24)) ...imagesIn(v, depth + 1)],
    _ => const [],
  };
}
