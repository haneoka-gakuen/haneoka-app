import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/system_proxy.dart';
import '../save/game_save.dart';
import 'game_history_client.dart';
import 'history_snapshot.dart';
import 'history_handoff.dart';
import 'history_identity.dart';

export 'history_identity.dart';

Future<Object?> _decodeHistory(String text) =>
    Isolate.run(() => jsonDecode(text));
Future<(String, String)> _encodeSnapshot(HistorySnapshot snapshot) =>
    Isolate.run(() {
      final text = jsonEncode(snapshot.toJson());
      return (text, sha256.convert(utf8.encode(text)).toString());
    });
Future<String> _encodeHistoryRecord(StoredHistory record) => Isolate.run(
  () => jsonEncode({
    'key': record.key,
    'saveKey': record.saveKey,
    'snapshot': record.snapshot.toJson(),
    'histories': record.histories.map((history) => history.toJson()).toList(),
  }),
);

class StoredHistory {
  const StoredHistory({
    required this.key,
    required this.snapshot,
    this.saveKey,
    this.snapshots = const [],
  });
  final String key;
  final String? saveKey;
  final HistorySnapshot snapshot;
  final List<HistorySnapshot> snapshots;
  List<HistorySnapshot> get histories =>
      snapshots.isEmpty ? [snapshot] : snapshots;
  HistorySnapshot history(String? kind) =>
      histories.where((history) => history.historyKind == kind).firstOrNull ??
      snapshot;
}

class HistoryRepository extends ChangeNotifier {
  HistoryRepository._();
  static final instance = HistoryRepository._();
  final _client = GameHistoryClient(
    proxyFor: (uri) => systemProxyFor(uri).httpProxy,
  );
  final _records = <String, StoredHistory>{};
  final _pending = <String, Future<StoredHistory>>{};
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  bool _loaded = false;
  List<StoredHistory> get records => List.unmodifiable(_records.values);
  bool isReading(String key) => _pending.containsKey(key);
  static String accountKey(GameSave save, GameHistoryRegion region) =>
      '${historySaveKey(save)}-${region.id}';
  static String? persistAccountKey(Object? document, GameHistoryRegion region) {
    final key = historyPersistKey(document);
    return key == null ? null : '$key-${region.id}';
  }

  Future<Directory> _folder() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'accounts', 'gacha-history'))
        .create(recursive: true);
  }

  Future<void> load() async {
    if (_loaded) return;
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    final folder = await _folder();
    await for (final entry in folder.list()) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      try {
        if (await entry.length() > historyResponseLimit * 4) continue;
        final value = await _decodeHistory(await entry.readAsString());
        if (value is! Map || value['key'] is! String) continue;
        final key = value['key'] as String;
        if (!RegExp(
          r'^[a-f0-9]{64}(?:-(?:jp|global-hmt|global-en|global-kr))?$',
        ).hasMatch(key)) {
          continue;
        }
        final snapshot = HistorySnapshot.fromJson(value['snapshot']);
        var histories = <HistorySnapshot>[snapshot];
        for (final raw
            in value['histories'] is List
                ? value['histories'] as List
                : [value['snapshot']]) {
          histories = mergeHistoryCollection(
            histories,
            HistorySnapshot.fromJson(raw),
          );
        }
        _records[key] = StoredHistory(
          key: key,
          snapshot:
              histories
                  .where((row) => row.historyKind == snapshot.historyKind)
                  .firstOrNull ??
              histories.first,
          snapshots: histories,
          saveKey: value['saveKey'] as String?,
        );
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<StoredHistory> import(HistorySnapshot snapshot) async {
    await load();
    final (_, digest) = await _encodeSnapshot(snapshot);
    final previous = snapshot.accountKey == null
        ? null
        : _records.values
              .where(
                (record) =>
                    record.snapshot.server == snapshot.server &&
                    (record.snapshot.accountKey ??
                            (record.saveKey == null
                                ? record.key
                                : historyPortableKey(
                                    record.key,
                                    record.snapshot.server,
                                  ))) ==
                        snapshot.accountKey,
              )
              .firstOrNull;
    final key = previous?.key ?? snapshot.accountKey ?? digest;
    final record = StoredHistory(
      key: key,
      saveKey: previous?.saveKey,
      snapshot: snapshot,
    );
    await _put(record, mergePrevious: snapshot.accountKey != null);
    return _records[key]!;
  }

  Future<StoredHistory> refresh(GameSave save, GameHistoryRegion region) async {
    final session = historySessionFromSave(save);
    if (session == null) {
      throw const GameHistoryException('history_missing_session');
    }
    if (save.server != region.catalogServer) {
      throw const GameHistoryException('history_server_mismatch');
    }
    return _refresh(
      historySaveKey(save),
      region,
      session,
      mergeKey: persistAccountKey(
        save.documents[SaveDocumentKind.persist]?.data,
        region,
      ),
    );
  }

  Future<StoredHistory> refreshPersist(
    Object? document,
    GameHistoryRegion region, {
    GameSave? account,
  }) async {
    final session = SavedGameSession.fromPersist(document);
    final key = historyPersistKey(document);
    if (session == null || key == null) {
      throw const GameHistoryException('history_missing_session');
    }
    if (account != null &&
        (account.server != region.catalogServer ||
            historyPersistKey(
                  account.documents[SaveDocumentKind.persist]?.data,
                ) !=
                key)) {
      throw const GameHistoryException('history_import_invalid');
    }
    return _refresh(
      account == null ? key : historySaveKey(account),
      region,
      session,
      mergeKey: '$key-${region.id}',
    );
  }

  Future<StoredHistory> _refresh(
    String saveKey,
    GameHistoryRegion region,
    SavedGameSession session, {
    String? mergeKey,
  }) async {
    await load();
    final key = '$saveKey-${region.id}';
    if (_pending[key] case final current?) return current;
    final pending = _read(saveKey, region, session, mergeKey: mergeKey);
    _pending[key] = pending;
    notifyListeners();
    try {
      return await pending;
    } finally {
      _pending.remove(key);
      notifyListeners();
    }
  }

  Future<StoredHistory> _read(
    String saveKey,
    GameHistoryRegion region,
    SavedGameSession session, {
    String? mergeKey,
  }) async {
    final key = '$saveKey-${region.id}';
    final snapshot = (await _client.read(
      session,
      region,
    )).forAccount(historyPortableKey(mergeKey ?? key, region.id));
    final record = StoredHistory(
      key: key,
      saveKey: saveKey,
      snapshot: snapshot,
    );
    await _put(record, mergeKey: mergeKey);
    return _records[record.key] ?? record;
  }

  Future<void> _put(
    StoredHistory record, {
    String? mergeKey,
    bool mergePrevious = false,
  }) async {
    final write = _writes.then((_) async {
      final folder = await _folder();
      final (rawSnapshot, digest) = await _encodeSnapshot(record.snapshot);
      final archives = await Directory(p.join(folder.path, 'snapshots'))
          .create(recursive: true);
      final archive = File(p.join(archives.path, '$digest.json'));
      if (!await archive.exists()) {
        await archive.writeAsString(rawSnapshot, flush: true);
      }
      final previous = _records[record.key];
      var histories = record.histories;
      if (previous != null &&
          (mergePrevious ||
              (record.saveKey != null && previous.saveKey == record.saveKey))) {
        histories = previous.histories;
        for (final incoming in record.histories) {
          histories = mergeHistoryCollection(histories, incoming);
        }
        final accountKey = record.snapshot.accountKey;
        if (accountKey != null) {
          histories = histories
              .map((history) => history.forAccount(accountKey))
              .toList();
        }
        record = StoredHistory(
          key: record.key,
          saveKey: record.saveKey,
          snapshot: histories.first,
          snapshots: histories,
        );
      }
      final aliases = _records.values
          .where(
            (candidate) =>
                candidate.key != record.key &&
                candidate.snapshot.server == record.snapshot.server &&
                ((record.snapshot.accountKey != null &&
                        record.snapshot.accountKey ==
                            candidate.snapshot.accountKey) ||
                    (candidate.key == mergeKey &&
                        candidate.saveKey != null &&
                        mergeKey ==
                            '${candidate.saveKey}-${record.snapshot.server}')),
          )
          .toList();
      for (final alias in aliases) {
        var merged = alias.histories;
        for (final incoming in record.histories) {
          merged = mergeHistoryCollection(merged, incoming);
        }
        final accountKey = record.snapshot.accountKey;
        if (accountKey != null) {
          merged = merged
              .map((history) => history.forAccount(accountKey))
              .toList();
        }
        record = StoredHistory(
          key: record.key,
          saveKey: record.saveKey,
          snapshot: merged.first,
          snapshots: merged,
        );
      }
      final target = File(p.join(folder.path, '${record.key}.json'));
      final temporary = File('${target.path}.tmp');
      final text = await _encodeHistoryRecord(record);
      try {
        await temporary.writeAsString(text, flush: true);
        await temporary.rename(target.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
      _records[record.key] = record;
      for (final alias in aliases) {
        _records.remove(alias.key);
        try {
          final oldFile = File(p.join(folder.path, '${alias.key}.json'));
          if (await oldFile.exists()) await oldFile.delete();
        } on FileSystemException {
          // The replacement already contains all versions of this history.
        }
      }
      notifyListeners();
      try {
        await writeHistoryHandoff(
          record.key,
          record.snapshot,
          histories: record.histories,
          replaces: aliases.map((alias) => alias.key),
        );
      } on FileSystemException {
        // The private history remains committed; refresh retries USB sharing.
      }
    });
    _writes = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    await write;
  }
}
