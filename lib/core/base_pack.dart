/// Common chart and story files built into the app, so the players start
/// without downloading them.
///
/// `assets/render/base-pack.bin` holds the files one after another and
/// `base-pack.json` maps each site path (`/assets/jp/...`, `/runtime/intl/...`)
/// to its offset and length. A file the pack lacks is downloaded as before.
library;

import 'dart:convert';

import 'package:flutter/services.dart';

final class BasePack {
  BasePack._();
  static final instance = BasePack._();

  Map<String, (int, int)> _index = const {};
  ByteData? _data;
  Future<void>? _loading;

  /// The bundled bytes for a site file of any release, or null.
  Future<Uint8List?> read(Uri uri) async {
    final segments = uri.pathSegments;
    if (segments.length < 3 ||
        !const {'assets', 'runtime'}.contains(segments[0])) {
      return null;
    }
    await (_loading ??= _load());
    final entry = _index[uri.path];
    final data = _data;
    if (entry == null || data == null) return null;
    return Uint8List.sublistView(data, entry.$1, entry.$1 + entry.$2);
  }

  Future<void> _load() async {
    try {
      final index = jsonDecode(
        await rootBundle.loadString('assets/render/base-pack.json'),
      ) as Map;
      _data = await rootBundle.load('assets/render/base-pack.bin');
      _index = {
        for (final MapEntry(:key, :value) in (index['files'] as Map).entries)
          key as String: ((value as List)[0] as int, value[1] as int),
      };
    } on Object {
      _index = const {};
    }
  }
}
