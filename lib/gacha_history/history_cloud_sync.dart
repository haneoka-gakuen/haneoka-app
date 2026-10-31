import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../account/haneoka_account.dart';
import '../save/account_store.dart';
import '../save/game_save.dart';
import 'game_history_client.dart';
import 'history_cloud.dart';
import 'history_repository.dart';
import 'history_sessions.dart';
import 'history_snapshot.dart';

class _CloudOperationCancelled implements Exception {
  const _CloudOperationCancelled();
}

/// Owner-scoped cloud cache. Only original repository records can be uploaded.
class HistoryCloudSync extends ChangeNotifier with WidgetsBindingObserver {
  HistoryCloudSync._();
  static final instance = HistoryCloudSync._();
  final _account = HaneokaAccount.instance;
  final _repository = HistoryRepository.instance;
  final _accounts = AccountStore.instance;
  final _sessions = HistorySessionStore.instance;
  final _client = HistoryCloudClient();
  final _documents = <String, HistoryCloudDocument>{};
  final _links = <String, String>{};
  final _linkCommands = <String, String>{};
  final _digests = <String, Map<String, String>>{};
  String? _owner, _errorCode;
  int _epoch = 0, _leases = 0;
  bool _busy = false, _rerun = false;
  int _requesting = 0;
  final _refreshRequests = <String, Future<void>>{};
  Future<void>? _flight, _hydrating;
  Future<void> _writes = Future.value();
  DateTime? _lastSync;
  List<StoredHistory> _sourceRecords = const [];
  List<GameSave> _sourceSaves = const [];

  bool get _owned => _owner != null && _owner == _currentOwner;
  String? get owner => _owned ? _owner : null;
  bool get signedIn => _owned;
  bool get busy => _owned && (_busy || _requesting > 0);
  String? get errorCode => _owned ? _errorCode : null;
  bool isLinked(String? key) =>
      _owned && key != null && _links.containsKey(key);
  bool pendingFor(String? key) =>
      _owned && (_documents[key]?.refreshPending ?? false);
  bool hasDocument(String? key) => _owned && _documents.containsKey(key);

  static String accountKeyFor(StoredHistory record) =>
      record.snapshot.accountKey ??
      (record.saveKey == null
          ? record.key
          : historyPortableKey(record.key, record.snapshot.server));

  /// A combined view, never an input to repository persistence or cloud upload.
  List<StoredHistory> get visibleRecords {
    final local = _repository.records;
    if (!_owned) return local;
    final known = local.map(accountKeyFor).toSet();
    return [
      for (final record in local) _visible(record),
      for (final document in _documents.values)
        if (!known.contains(document.accountKey))
          StoredHistory(
            key: document.accountKey,
            snapshot: document.histories.first,
            snapshots: document.histories,
          ),
    ];
  }

  StoredHistory _visible(StoredHistory local) {
    final key = accountKeyFor(local), remote = _documents[accountKeyFor(local)];
    if (remote == null || remote.server != local.snapshot.server) return local;
    var histories = [
      for (final history in local.histories) history.forAccount(key),
    ];
    for (final history in remote.histories) {
      histories = mergeHistoryCollection(histories, history);
    }
    return StoredHistory(
      key: local.key,
      saveKey: local.saveKey,
      snapshot:
          histories
              .where((row) => row.historyKind == local.snapshot.historyKind)
              .firstOrNull ??
          histories.first,
      snapshots: histories,
    );
  }

  void start() {
    if (++_leases != 1) return;
    WidgetsBinding.instance.addObserver(this);
    _account.addListener(_ownerChanged);
    _repository.addListener(_localChanged);
    _accounts.addListener(_localChanged);
    _ownerChanged();
    unawaited(_initialize());
  }

  void stop() {
    if (_leases == 0 || --_leases != 0) return;
    WidgetsBinding.instance.removeObserver(this);
    _account.removeListener(_ownerChanged);
    _repository.removeListener(_localChanged);
    _accounts.removeListener(_localChanged);
    _reset(null);
  }

  Future<void> _initialize() async {
    try {
      await Future.wait([
        _account.load(),
        _repository.load(),
        _accounts.load(),
        _sessions.load(),
      ]);
      if (_leases > 0) _ownerChanged();
    } on Exception {
      return;
    }
  }

  String? get _currentOwner {
    final id = _account.user?['id'];
    return _account.signedIn && id is String && id.isNotEmpty ? id : null;
  }

  void _reset(String? owner) {
    _epoch++;
    _owner = owner;
    _documents.clear();
    _links.clear();
    _linkCommands.clear();
    _digests.clear();
    _errorCode = null;
    _busy = false;
    _requesting = 0;
    _refreshRequests.clear();
    _rerun = false;
    _flight = null;
    _hydrating = null;
    _lastSync = null;
    notifyListeners();
  }

  void _ownerChanged() {
    if (_leases == 0) return;
    final next = _currentOwner;
    if (next != _owner) {
      _reset(next);
      if (next != null) {
        final epoch = _epoch;
        _hydrating = _hydrate(next, epoch);
      }
    }
    if (next != null) unawaited(sync());
  }

  void _localChanged() {
    final records = _repository.records, saves = _accounts.saves;
    if (listEquals(records, _sourceRecords) &&
        listEquals(saves, _sourceSaves)) {
      return;
    }
    _sourceRecords = records;
    _sourceSaves = saves;
    if (_owner != null) unawaited(sync(force: true, localChange: true));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(sync());
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.state == ViewFocusState.focused) unawaited(sync());
  }

  void _guard(String owner, int epoch, [String? linkedKey, String? grant]) {
    if (_leases == 0 ||
        _epoch != epoch ||
        _owner != owner ||
        _currentOwner != owner ||
        (linkedKey != null &&
            (_links[linkedKey] == null ||
                (grant != null && _links[linkedKey] != grant)))) {
      throw const _CloudOperationCancelled();
    }
  }

  Future<Directory> _folder(String owner) async {
    final support = await getApplicationSupportDirectory();
    return Directory(
      p.join(
        support.path,
        'accounts',
        'gacha-cloud',
        sha256.convert(utf8.encode(owner)).toString(),
      ),
    ).create(recursive: true);
  }

  Future<void> _hydrate(String owner, int epoch) async {
    try {
      final folder = await _folder(owner);
      _guard(owner, epoch);
      final index = File(p.join(folder.path, 'index.json'));
      if (await index.exists() && await index.length() <= historyCloudBytes) {
        final value = jsonDecode(await index.readAsString());
        _guard(owner, epoch);
        if (value is Map &&
            value['schema'] == 'haneoka-gacha-cloud-cache-v1' &&
            value['ownerId'] == owner) {
          final links = value['links'];
          if (links is Map) {
            for (final entry in links.entries) {
              if (entry.key is String &&
                  _keyValid(entry.key as String) &&
                  entry.value is String &&
                  _grantValid(entry.value as String) &&
                  !_linkCommands.containsKey(entry.key)) {
                _links[entry.key as String] = entry.value as String;
              }
            }
          }
          final digests = value['digests'];
          if (digests is Map) {
            for (final entry in digests.entries) {
              if (entry.key is! String ||
                  !_keyValid(entry.key as String) ||
                  entry.value is! Map ||
                  _linkCommands.containsKey(entry.key)) {
                continue;
              }
              _digests[entry.key as String] = {
                for (final digest in (entry.value as Map).entries)
                  if (digest.key is String &&
                      digest.value is String &&
                      _keyValid(digest.value as String))
                    digest.key as String: digest.value as String,
              };
            }
          }
        }
      }
      await for (final entry in folder.list()) {
        _guard(owner, epoch);
        final name = p.basenameWithoutExtension(entry.path);
        if (entry is! File ||
            !entry.path.endsWith('.json') ||
            !_keyValid(name)) {
          continue;
        }
        try {
          if (await entry.length() > historyCloudBytes * 2) continue;
          final value = jsonDecode(await entry.readAsString());
          _guard(owner, epoch);
          if (value is Map) {
            _documents[name] = HistoryCloudDocument.fromJson(
              value,
              owner,
              name,
            );
          }
        } on FormatException {
          continue;
        } on HistoryCloudError {
          continue;
        }
      }
      _guard(owner, epoch);
      notifyListeners();
    } on _CloudOperationCancelled {
      return;
    } on FileSystemException {
      return;
    } on FormatException {
      return;
    }
  }

  static bool _keyValid(String value) =>
      RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
  static bool _grantValid(String value) =>
      RegExp(r'^[a-f0-9]{32}$').hasMatch(value);
  String _newGrant() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<T> _withGrant<T>(
    String owner,
    int epoch,
    String key,
    String grant,
    Future<T> Function() action,
  ) async {
    _guard(owner, epoch, key, grant);
    try {
      final value = await action();
      _guard(owner, epoch, key, grant);
      return value;
    } catch (_) {
      _guard(owner, epoch, key, grant);
      rethrow;
    }
  }

  Map<String, Object?> _documentJson(HistoryCloudDocument value) => {
    'ownerId': value.ownerId,
    'accountKey': value.accountKey,
    'server': value.server,
    'revision': value.revision,
    'updatedAt': value.updatedAt,
    'refreshRequested': value.refreshRequested,
    'refreshCompleted': value.refreshCompleted,
    'histories': [for (final history in value.histories) history.toJson()],
  };

  Future<void> _persist(
    String owner,
    int epoch, [
    HistoryCloudDocument? document,
  ]) {
    _guard(owner, epoch);
    final rawDocument = document == null
        ? null
        : jsonEncode(_documentJson(document));
    final write = _writes.then((_) async {
      _guard(owner, epoch);
      final folder = await _folder(owner);
      _guard(owner, epoch);
      Future<void> replace(String name, String text) async {
        final target = File(p.join(folder.path, name)),
            temporary = File(p.join(folder.path, '$name.tmp'));
        await temporary.writeAsString(text, flush: true);
        _guard(owner, epoch);
        await temporary.rename(target.path);
        _guard(owner, epoch);
      }

      if (rawDocument != null) {
        await replace('${document!.accountKey}.json', rawDocument);
      }
      await replace(
        'index.json',
        jsonEncode({
          'schema': 'haneoka-gacha-cloud-cache-v1',
          'ownerId': owner,
          'links': _links,
          'digests': _digests,
        }),
      );
    });
    _writes = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return write;
  }

  Future<void> _accept(
    HistoryCloudDocument document,
    String owner,
    int epoch,
  ) async {
    _guard(owner, epoch);
    if (document.ownerId != owner) throw const _CloudOperationCancelled();
    if ((_documents[document.accountKey]?.revision ?? -1) > document.revision) {
      return;
    }
    _documents[document.accountKey] = document;
    notifyListeners();
    await _persist(owner, epoch, document);
    _guard(owner, epoch);
  }

  Future<void> setLinked(String key, bool linked) async {
    final owner = _owner, epoch = _epoch;
    if (owner == null) return;
    final command = _newGrant();
    _linkCommands[key] = command;
    if (!linked) {
      _links.remove(key);
      _digests.remove(key);
      notifyListeners();
    }
    try {
      await _hydrating;
      _guard(owner, epoch);
      if (_linkCommands[key] != command) throw const _CloudOperationCancelled();
      if (!_keyValid(key)) {
        throw const HistoryCloudError('history_account_mismatch');
      }
      if (linked) _links[key] = command;
      _errorCode = null;
      notifyListeners();
      await _persist(owner, epoch);
      _guard(owner, epoch);
      if (_linkCommands[key] != command) throw const _CloudOperationCancelled();
      if (linked) {
        final previous = _flight;
        await sync(force: true, localChange: true);
        _guard(owner, epoch, key, command);
        if (previous != null && _errorCode == null) await sync(force: true);
      }
    } on _CloudOperationCancelled {
      return;
    } catch (error) {
      if (_linkCommands[key] == command) _report(error, owner, epoch);
    }
  }

  Future<void> sync({bool force = false, bool localChange = false}) {
    final owner = _owner;
    if (_leases == 0 || owner == null) return Future.value();
    if (_flight case final current?) {
      if (localChange) _rerun = true;
      return current;
    }
    if (!force &&
        _lastSync != null &&
        DateTime.now().difference(_lastSync!) < const Duration(seconds: 8)) {
      return Future.value();
    }
    final epoch = _epoch;
    final future = Future<void>.microtask(() async {
      try {
        _guard(owner, epoch);
        _busy = true;
        _errorCode = null;
        _lastSync = DateTime.now();
        notifyListeners();
        await _hydrating;
        _guard(owner, epoch);
        await Future.wait([
          _repository.load(),
          _accounts.load(),
          _sessions.load(),
        ]);
        _guard(owner, epoch);
        do {
          _rerun = false;
          await _cycle(owner, epoch);
          _guard(owner, epoch);
        } while (_rerun);
        _lastSync = DateTime.now();
      } on _CloudOperationCancelled {
        if (_epoch == epoch && _owner == owner) _rerun = false;
        return;
      } catch (error) {
        if (_epoch == epoch && _owner == owner) _rerun = false;
        _report(error, owner, epoch);
      } finally {
        if (_epoch == epoch && _owner == owner) {
          _busy = false;
          _flight = null;
          notifyListeners();
        }
      }
    });
    _flight = future;
    return future;
  }

  Future<void> _cycle(String owner, int epoch) async {
    final summaries = await _client.list();
    _guard(owner, epoch);
    final present = summaries.map((summary) => summary.accountKey).toSet();
    for (final key
        in _documents.keys.where((key) => !present.contains(key)).toList()) {
      _documents.remove(key);
    }
    for (final summary in summaries) {
      _guard(owner, epoch);
      if (_documents[summary.accountKey]?.revision == summary.revision) {
        continue;
      }
      final document = await _client.read(summary.accountKey);
      _guard(owner, epoch);
      await _accept(document, owner, epoch);
    }
    final local = <String, List<HistorySnapshot>>{};
    for (final record in _repository.records) {
      final key = accountKeyFor(record);
      if (!_links.containsKey(key)) continue;
      var histories = local[key] ?? <HistorySnapshot>[];
      for (final history in record.histories) {
        histories = mergeHistoryCollection(histories, history.forAccount(key));
      }
      local[key] = histories;
    }
    for (final entry in local.entries) {
      final grant = _links[entry.key];
      if (grant == null) continue;
      for (final history in entry.value) {
        _guard(owner, epoch, entry.key, grant);
        final digest = _digest(history);
        if (_digests[entry.key]?[history.historyKind] == digest) continue;
        final document = await _withGrant(
          owner,
          epoch,
          entry.key,
          grant,
          () => _client.upload(entry.key, history),
        );
        _guard(owner, epoch, entry.key, grant);
        (_digests[entry.key] ??= {})[history.historyKind] = digest;
        await _withGrant(
          owner,
          epoch,
          entry.key,
          grant,
          () => _accept(document, owner, epoch),
        );
        _guard(owner, epoch, entry.key, grant);
      }
    }
    for (final document in _documents.values.toList()) {
      if (!document.refreshPending ||
          !_links.containsKey(document.accountKey)) {
        continue;
      }
      final grant = _links[document.accountKey];
      if (grant == null) continue;
      final reader = _reader(document.accountKey, document.server);
      if (reader == null) continue;
      _guard(owner, epoch, document.accountKey, grant);
      final record = await _withGrant(
        owner,
        epoch,
        document.accountKey,
        grant,
        reader,
      );
      _guard(owner, epoch, document.accountKey, grant);
      final histories = [
        for (final history in record.histories)
          history.forAccount(document.accountKey),
      ];
      for (final (index, history) in histories.indexed) {
        _guard(owner, epoch, document.accountKey, grant);
        if (history.server != document.server) {
          throw const HistoryCloudError('history_server_mismatch');
        }
        final digest = _digest(history), last = index == histories.length - 1;
        if (!last &&
            _digests[document.accountKey]?[history.historyKind] == digest) {
          continue;
        }
        final acknowledged = await _withGrant(
          owner,
          epoch,
          document.accountKey,
          grant,
          () => _client.upload(
            document.accountKey,
            history,
            completedRequest: last ? document.refreshRequested : 0,
          ),
        );
        _guard(owner, epoch, document.accountKey, grant);
        (_digests[document.accountKey] ??= {})[history.historyKind] = digest;
        await _withGrant(
          owner,
          epoch,
          document.accountKey,
          grant,
          () => _accept(acknowledged, owner, epoch),
        );
      }
      _guard(owner, epoch, document.accountKey, grant);
    }
  }

  String _digest(HistorySnapshot history) =>
      sha256.convert(utf8.encode(jsonEncode(history.toJson()))).toString();

  Future<StoredHistory> Function()? _reader(String key, String server) {
    final region = GameHistoryRegion.values
        .where((region) => region.id == server)
        .firstOrNull;
    if (region == null) return null;
    for (final save in _accounts.saves) {
      if (save.server != region.catalogServer) continue;
      final hash = historyPersistKey(
        save.documents[SaveDocumentKind.persist]?.data,
      );
      if (hash == null || historyPortableKey('$hash-$server', server) != key) {
        continue;
      }
      final session = _sessions.records['$hash-${region.catalogServer}'];
      return session == null
          ? () => _repository.refresh(save, region)
          : () => _repository.refreshPersist(
              session.document,
              region,
              account: save,
            );
    }
    for (final session in _sessions.records.values) {
      if (session.release.server == region.catalogServer &&
          historyPortableKey('${session.sessionKey}-$server', server) == key) {
        return () => _repository.refreshPersist(session.document, region);
      }
    }
    return null;
  }

  Future<void> requestRefresh(String key) {
    final owner = _owner, epoch = _epoch, grant = _links[key];
    if (owner == null || grant == null || !_documents.containsKey(key)) {
      return Future.value();
    }
    if (_refreshRequests[key] case final pending?) return pending;
    final request = Future<void>.microtask(() async {
      var active = false;
      try {
        _guard(owner, epoch, key, grant);
        _requesting++;
        active = true;
        _errorCode = null;
        notifyListeners();
        final document = await _withGrant(
          owner,
          epoch,
          key,
          grant,
          () => _client.requestRefresh(key),
        );
        _guard(owner, epoch, key, grant);
        await _withGrant(
          owner,
          epoch,
          key,
          grant,
          () => _accept(document, owner, epoch),
        );
        _guard(owner, epoch, key, grant);
        await sync(force: true, localChange: true);
      } on _CloudOperationCancelled {
        return;
      } catch (error) {
        _report(error, owner, epoch);
      } finally {
        if (_owner == owner && _epoch == epoch) {
          if (active) _requesting--;
          _refreshRequests.remove(key);
          notifyListeners();
        }
      }
    });
    _refreshRequests[key] = request;
    return request;
  }

  void _report(Object error, String owner, int epoch) {
    if (_owner != owner || _epoch != epoch || _currentOwner != owner) return;
    final code = switch (error) {
      HistoryCloudError(:final code) => code,
      AccountError(:final code) => code,
      GameHistoryException(:final code) => code,
      FormatException() => 'history_cloud_unavailable',
      _ => 'history_network_error',
    };
    if (code == 'account_changed' ||
        code == 'reader_unavailable' ||
        code == 'history_missing_session') {
      return;
    }
    _errorCode = switch (code) {
      'unauthenticated' ||
      'authentication_required' => 'authentication_required',
      'account_deleted' => 'account_restricted',
      'email_verification_required' ||
      'account_restricted' ||
      'history_too_large' ||
      'history_account_limit' ||
      'history_account_mismatch' ||
      'history_server_mismatch' ||
      'history_session_expired' ||
      'history_cloud_unavailable' => code,
      'database_unavailable' ||
      'profile_unavailable' ||
      'history_not_found' ||
      'busy' ||
      'http_404' ||
      'http_503' ||
      'history_response_invalid' ||
      'invalid_history' ||
      'invalid_refresh' ||
      'history_account_key_invalid' => 'history_cloud_unavailable',
      _ => 'history_network_error',
    };
    notifyListeners();
  }
}
