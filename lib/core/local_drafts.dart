import 'package:shared_preferences/shared_preferences.dart';

/// Local editor snapshots are immediate; disk writes retain that order.
abstract final class LocalDrafts {
  static final _values = <String, String?>{};
  static final _versions = <String, int>{};
  static Future<void> _writing = Future.value();
  static Future<String?> read(String key) async {
    if (_values.containsKey(key)) return _values[key];
    final prefs = await SharedPreferences.getInstance();
    _values.putIfAbsent(key, () => prefs.getString(key));
    return _values[key];
  }

  static void stage(String key, String? value) {
    _values[key] = value;
    _versions[key] = (_versions[key] ?? 0) + 1;
  }

  static Future<void> flush(String key) {
    if (!_values.containsKey(key)) return Future.value();
    final value = _values[key], version = _versions[key];
    final next = _writing.then((_) async {
      if (_versions[key] != version) return;
      final prefs = await SharedPreferences.getInstance();
      final saved = value == null
          ? await prefs.remove(key)
          : await prefs.setString(key, value);
      if (!saved) throw StateError('local_draft_write');
    });
    _writing = next.then((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  static Future<void> remove(String key) {
    stage(key, null);
    return flush(key);
  }
}
