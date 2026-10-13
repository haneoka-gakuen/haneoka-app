import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'game_save.dart';

// Keep isolate closures outside AccountStore: its pending write Future and
// ChangeNotifier listeners cannot be sent to another isolate.
Future<Object?> _decodeAccount(String text) =>
    Isolate.run(() => jsonDecode(text));
Future<String> _encodeAccount(Map<String, Object?> data) =>
    Isolate.run(() => jsonEncode(data));

/// The accounts imported on this device, kept in the app's private storage
/// so they are still there next time. Nothing leaves the device.
class AccountStore extends ChangeNotifier {
  AccountStore._();
  static final AccountStore instance = AccountStore._();

  final List<GameSave> _saves = [];
  bool _loaded = false;
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  List<GameSave> get saves => List.unmodifiable(_saves);

  static String _key(GameSave save) =>
      '${save.release?.server ?? 'save'}-${save.profileId}';

  Future<Directory> _folder() async {
    final root = await getApplicationSupportDirectory();
    final folder = Directory(p.join(root.path, 'accounts'));
    await folder.create(recursive: true);
    return folder;
  }

  Future<void> load() {
    if (_loaded) return Future.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    final folder = await _folder();
    final files = await folder
        .list()
        .where((f) => f is File && f.path.endsWith('.json'))
        .cast<File>()
        .toList();
    for (final file in files) {
      try {
        final text = await file.readAsString();
        final json = await _decodeAccount(text);
        if (decode(json) case final save?) _saves.add(save);
      } catch (_) {
        // A damaged file is skipped; importing again replaces it.
      }
    }
    _loaded = true;
    _sort();
    notifyListeners();
  }

  Future<void> _exclusive(Future<void> Function() write) {
    final result = _writes.then((_) async {
      await load();
      await write();
    });
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> put(GameSave save) => _exclusive(() async {
    final folder = await _folder();
    final json = encode(save);
    final text = await _encodeAccount(json);
    final target = File(
      p.join(folder.path, '${Uri.encodeComponent(_key(save))}.json'),
    );
    final temporary = File(
      '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
    _saves.removeWhere((s) => _key(s) == _key(save));
    _saves.add(save);
    _sort();
    notifyListeners();
  });

  Future<void> remove(GameSave save) => _exclusive(() async {
    final file = File(
      p.join((await _folder()).path, '${Uri.encodeComponent(_key(save))}.json'),
    );
    if (await file.exists()) await file.delete();
    _saves.removeWhere((s) => _key(s) == _key(save));
    notifyListeners();
  });

  void _sort() => _saves.sort(
    (a, b) =>
        (b.modifiedAt ?? DateTime(0)).compareTo(a.modifiedAt ?? DateTime(0)),
  );

  /// One account as stored (`haneoka-account-v1`).
  static Map<String, Object?> encode(GameSave save) => {
    'schema': 'haneoka-account-v1',
    'profileId': save.profileId,
    'name': save.name,
    'release': save.release?.name,
    'source': save.source,
    'documents': {
      for (final MapEntry(:key, :value) in save.documents.entries)
        key.name: {
          'modifiedAt': value.modifiedAt?.toUtc().toIso8601String(),
          'data': value.data,
        },
    },
  };

  /// An account read back from [encode]; null for anything else.
  static GameSave? decode(Object? json) {
    if (json is! Map || json['schema'] != 'haneoka-account-v1') return null;
    final save = GameSave(
      profileId: '${json['profileId']}',
      name: json['name'] as String?,
      release: GameRelease.values
          .where((r) => r.name == json['release'])
          .firstOrNull,
      source: '${json['source'] ?? ''}',
    );
    for (final MapEntry(:key, :value)
        in ((json['documents'] as Map?) ?? const {}).entries) {
      final kind = SaveDocumentKind.values
          .where((k) => k.name == key)
          .firstOrNull;
      if (kind == null || value is! Map) continue;
      save.documents[kind] = SaveDocument(
        kind,
        ((value['data'] as Map?) ?? const {}).cast<String, Object?>(),
        DateTime.tryParse('${value['modifiedAt'] ?? ''}')?.toLocal(),
      );
    }
    return save;
  }
}
