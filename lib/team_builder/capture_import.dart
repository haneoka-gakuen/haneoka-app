/// A player's cards from a captured GetPlayerData response in an HTTP
/// archive (HAR), as `capture.ts` in game-data-exporter reads it. Tokens and
/// names in the archive are never read.
library;

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

const _method = '/app.player.PlayerService/GetPlayerData';

class CaptureError implements Exception {
  const CaptureError(this.code);
  final String code;
}

typedef _Fields = Map<int, List<Object>>;

(int, int) _varint(Uint8List data, int at) {
  var value = 0, scale = 1, i = at;
  while (true) {
    if (i >= data.length || i - at > 9) {
      throw const CaptureError('box_invalid_capture');
    }
    final byte = data[i++];
    value += (byte & 0x7f) * scale;
    if (byte & 0x80 == 0) return (value, i);
    scale *= 128;
  }
}

_Fields _fields(Uint8List data) {
  final out = <int, List<Object>>{};
  var at = 0;
  while (at < data.length) {
    final (key, next) = _varint(data, at);
    at = next;
    final number = key >> 3, wire = key & 7;
    Object value;
    switch (wire) {
      case 0:
        final (v, n) = _varint(data, at);
        value = v;
        at = n;
      case 2:
        final (length, start) = _varint(data, at);
        if (start + length > data.length) {
          throw const CaptureError('box_invalid_capture');
        }
        value = Uint8List.sublistView(data, start, start + length);
        at = start + length;
      case 1:
        at += 8;
        continue;
      case 5:
        at += 4;
        continue;
      default:
        throw const CaptureError('box_invalid_capture');
    }
    (out[number] ??= []).add(value);
  }
  return out;
}

List<_Fields> _messages(_Fields f, int n) => [
  for (final v in f[n] ?? const <Object>[])
    if (v is Uint8List) _fields(v),
];
int _number(_Fields f, int n) {
  final v = f[n]?.last;
  return v is int ? v : 0;
}

Map<String, Object?>? _player(Uint8List data) {
  final root = _messages(_fields(data), 1).firstOrNull;
  if (root == null) return null;
  return {
    '_memberCards': [
      for (final m in _messages(root, 2))
        {
          '_masterId': _number(m, 2),
          '_exp': _number(m, 3),
          '_awakeCount': _number(m, 4),
          '_rank': _number(m, 5),
          '_liveSkillLevel': _number(m, 7),
          '_performanceSkillLevel': _number(m, 8),
        },
    ],
    '_supportCards': [
      for (final m in _messages(root, 3))
        {
          '_masterId': _number(m, 2),
          '_exp': _number(m, 3),
          '_rank': _number(m, 5),
        },
    ],
    '_bandItems': [
      for (final m in _messages(root, 8))
        {'_masterId': _number(m, 1), '_level': _number(m, 2)},
    ],
    '_characters': [
      for (final m in _messages(root, 12))
        {'_masterId': _number(m, 1), '_exp': _number(m, 2)},
    ],
  };
}

Uint8List _unframe(Uint8List body) {
  if (body.length < 5) throw const CaptureError('box_invalid_capture');
  final length = ByteData.sublistView(body, 1, 5).getUint32(0);
  if (5 + length > body.length) throw const CaptureError('box_invalid_capture');
  final message = Uint8List.sublistView(body, 5, 5 + length);
  return body[0] == 1 ? Uint8List.fromList(gzip.decode(message)) : message;
}

bool isCapture(Object? root) =>
    root is Map &&
    root['log'] is Map &&
    (root['log'] as Map)['entries'] is List;

/// The newest GetPlayerData response, as a save document.
Map<String, Object?> captureDocument(Map root) {
  final entries = [
    for (final entry in ((root['log'] as Map)['entries'] as List).reversed)
      if (entry is Map &&
          '${(entry['request'] as Map?)?['url'] ?? ''}'.contains(_method))
        entry,
  ];
  for (final entry in entries) {
    final content = (entry['response'] as Map?)?['content'] as Map?;
    final text = content?['text'];
    if (text is! String || text.isEmpty) continue;
    final body = content!['encoding'] == 'base64'
        ? base64Decode(text.replaceAll(RegExp(r'\s'), ''))
        : Uint8List.fromList([for (final c in text.codeUnits) c & 0xff]);
    final player = _player(_unframe(body));
    if (player != null &&
        ((player['_memberCards'] as List).isNotEmpty ||
            (player['_supportCards'] as List).isNotEmpty)) {
      return {'_player': player};
    }
  }
  throw CaptureError(
    entries.isEmpty ? 'box_no_capture' : 'box_invalid_capture',
  );
}
