/// The site's one date and time format with the reader's preferences, a port
/// of `date-format.ts`. Dates reach the screen through here.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

const dateChoices = <String, List<String>>{
  'order': ['auto', 'mdy', 'dmy', 'ymd'],
  'month': ['short', 'long', 'numeric', '2-digit'],
  'day': ['numeric', '2-digit', 'ordinal'],
  'separator': ['/', '-', '.', ' '],
  'year': ['auto', 'always', 'never'],
  'yearDigits': ['numeric', '2-digit'],
  'weekday': ['none', 'short', 'long', 'narrow'],
  'cycle': ['h23', 'h12'],
  'hour': ['2-digit', 'numeric'],
  'seconds': ['off', 'on'],
  'zoneName': ['none', 'short', 'shortOffset', 'long'],
};
const _storageKey = 'haneoka.date-format.v3';

/// Stored preferences; every missing choice takes its first value.
class SiteDatePreferences {
  SiteDatePreferences._();
  static final changes = ValueNotifier(0);
  static final Map<String, String> _values = {};
  static bool _zonesReady = false;

  static Map<String, String>? _overlay;

  /// Runs [read] as if [overrides] were chosen, for a settings sample.
  static String preview(Map<String, String> overrides, String Function() read) {
    _overlay = overrides;
    try {
      return read();
    } finally {
      _overlay = null;
    }
  }

  static String value(String key) =>
      _overlay?[key] ??
      _values[key] ??
      (key == 'zone' ? 'local' : dateChoices[key]?.first ?? '');
  static List<String> get zones {
    _ensureZones();
    return ['local', ...tz.timeZoneDatabase.locations.keys.toList()..sort()];
  }

  static void _ensureZones() {
    if (_zonesReady) return;
    tz_data.initializeTimeZones();
    _zonesReady = true;
  }

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final stored = jsonDecode(prefs.getString(_storageKey) ?? '{}');
      if (stored is Map) {
        for (final MapEntry(:key, :value) in stored.entries) {
          if (dateChoices[key]?.contains(value) == true ||
              key == 'zone' && value is String) {
            _values['$key'] = '$value';
          }
        }
      }
    } catch (_) {}
    changes.value++;
  }

  static Future<void> set(String key, String value) async {
    _values[key] = value;
    changes.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(_values));
  }

  /// [at] in the chosen zone, with its offset name.
  static (DateTime, String, Duration) resolve(DateTime at) {
    final zone = value('zone');
    final local = at.toLocal();
    if (zone == 'local') {
      return (local, local.timeZoneName, local.timeZoneOffset);
    }
    _ensureZones();
    final location = tz.timeZoneDatabase.locations[zone];
    if (location == null) {
      return (local, local.timeZoneName, local.timeZoneOffset);
    }
    final time = tz.TZDateTime.from(at, location);
    return (
      DateTime(
        time.year,
        time.month,
        time.day,
        time.hour,
        time.minute,
        time.second,
      ),
      time.timeZoneName,
      time.timeZoneOffset,
    );
  }
}

/// A date format with the same use as an `intl` [DateFormat].
class SiteDate {
  const SiteDate(
    this.locale, {
    this.time = false,
    this.seconds,
    this.weekday = false,
  });
  factory SiteDate.day(String? locale) =>
      SiteDate(locale ?? Intl.defaultLocale ?? 'en');
  final String locale;
  final bool time, weekday;
  final bool? seconds;

  SiteDate withTime({bool? seconds}) =>
      SiteDate(locale, time: true, seconds: seconds, weekday: weekday);

  String format(DateTime value) {
    final (date, zone, offset) = SiteDatePreferences.resolve(value);
    final day = _date(date);
    return time ? '$day ${_time(date, zone, offset)}' : day;
  }

  String formatTime(DateTime value) {
    final (date, zone, offset) = SiteDatePreferences.resolve(value);
    return _time(date, zone, offset);
  }

  String _time(DateTime date, String zone, Duration offset) {
    final v = SiteDatePreferences.value;
    final twelve = v('cycle') == 'h12';
    final showSeconds = seconds ?? v('seconds') == 'on';
    final hour = twelve
        ? (date.hour % 12 == 0 ? 12 : date.hour % 12)
        : date.hour;
    String pad(int n) => '$n'.padLeft(2, '0');
    final clock = [
      v('hour') == '2-digit' ? pad(hour) : '$hour',
      pad(date.minute),
      if (showSeconds) pad(date.second),
    ].join(':');
    final period = twelve ? ' ${date.hour < 12 ? 'AM' : 'PM'}' : '';
    final name = switch (v('zoneName')) {
      'none' => '',
      'shortOffset' => ' ${_offset(offset)}',
      _ => ' $zone',
    };
    return '$clock$period$name';
  }

  String _offset(Duration offset) {
    final minutes = offset.inMinutes;
    final sign = minutes < 0 ? '-' : '+';
    final hours = minutes.abs() ~/ 60, rest = minutes.abs() % 60;
    return 'GMT$sign$hours${rest == 0 ? '' : ':${'$rest'.padLeft(2, '0')}'}';
  }

  String _date(DateTime date) {
    final v = SiteDatePreferences.value;
    final english = locale.startsWith('en');
    final tight = locale.startsWith('ja') || locale.startsWith('zh');
    final order = v('order') == 'auto' ? (english ? 'mdy' : 'ymd') : v('order');
    final showYear = switch (v('year')) {
      'always' => true,
      'never' => false,
      _ => date.year != DateTime.now().year,
    };
    final yearText = v('yearDigits') == '2-digit'
        ? '${date.year}'.substring(2)
        : '${date.year}';
    final String text;
    if (v('month') == 'numeric' || v('month') == '2-digit') {
      String piece(int n, bool padded) => padded ? '$n'.padLeft(2, '0') : '$n';
      final month = piece(date.month, v('month') == '2-digit');
      final day = piece(date.day, v('day') == '2-digit');
      final year = showYear ? yearText : '';
      final pieces = switch (order) {
        'mdy' => [month, day, year],
        'dmy' => [day, month, year],
        _ => [year, month, day],
      };
      text = pieces.where((p) => p.isNotEmpty).join(v('separator'));
    } else {
      final month = DateFormat(
        v('month') == 'long' ? 'MMMM' : 'MMM',
        locale,
      ).format(date);
      var day = DateFormat(
        v('day') == '2-digit' ? 'dd' : 'd',
        locale,
      ).format(date);
      if (v('day') == 'ordinal' && english) {
        final n = date.day, teen = n % 100 >= 11 && n % 100 <= 13;
        day =
            '$n${teen ? 'th' : const {1: 'st', 2: 'nd', 3: 'rd'}[n % 10] ?? 'th'}';
      }
      final year = showYear
          ? (tight ? DateFormat('y', locale).format(date) : yearText)
          : '';
      String join(List<String> items) =>
          items.where((p) => p.isNotEmpty).join(tight ? '' : ' ');
      if (order == 'ymd') {
        text = join([year, month, day]);
      } else if (order == 'dmy') {
        text = join([day, month, year]);
      } else if (tight) {
        text = join([month, day, if (year.isNotEmpty) ' $year']);
      } else {
        text = '$month $day${year.isEmpty ? '' : ', $year'}';
      }
    }
    final style = switch (v('weekday')) {
      'none' => weekday ? 'E' : null,
      'long' => 'EEEE',
      'narrow' => 'EEEEE',
      _ => 'E',
    };
    if (style == null) return text;
    final name = DateFormat(style, locale).format(date);
    return english ? '$name, $text' : '$text $name';
  }
}
