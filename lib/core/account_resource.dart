import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../account/haneoka_account.dart';
import 'net.dart';
import 'site_origin.dart';
import 'media_lifecycle.dart';

bool isAccountResource(Uri uri) {
  if (uri.scheme != 'https' || uri.origin != 'https://haneoka.org') {
    return false;
  }
  if (RegExp(r'^/api/v1/community/charts/[^/]+/media/').hasMatch(uri.path)) {
    return true;
  }
  if (uri.path.startsWith('/api/v1/admin/attachments/')) return true;
  final match = RegExp(
    r'^/(?:(?:assets|runtime|objects)/|api/v1/servers/)([^/]+)/',
  ).firstMatch(uri.path);
  return match != null && !const {'jp', 'intl'}.contains(match[1]);
}

class AccountResourceCancelled implements Exception {
  const AccountResourceCancelled();
}

class AccountResourceLease {
  AccountResourceLease._(this.file, this._release, this.mediaType);
  final String? mediaType;
  final File file;
  final Future<void> Function() _release;
  bool _released = false;
  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _release();
  }
}

class _AccountResourceEntry {
  final abort = Completer<void>();
  late Future<File> file;
  int users = 0;
  bool retired = false;
  int bytes = 0, used = 0;
  String? mediaType;
}

/// Protected media stays in temporary, account-scoped leases, outside public caches.
class AccountResources {
  AccountResources._() {
    _account.addListener(_changed);
    _identity = _currentIdentity;
    MediaLifecycle.register(this, close);
  }
  static final instance = AccountResources._();
  final _account = HaneokaAccount.instance;
  final _entries = <String, _AccountResourceEntry>{};
  final _changes = StreamController<void>.broadcast(sync: true);
  Object? _identity;
  Future<Directory>? _root;
  int _epoch = 0;
  bool _closed = false;
  String? get owner => _account.user?['id'] as String?;
  Object get _currentIdentity =>
      (_account.user?['id'], _account.authorization['Cookie']);
  Stream<void> get changes => _changes.stream;
  int get epoch => _epoch;
  void _changed() {
    if (_closed) return;
    final next = _currentIdentity;
    if (next == _identity) return;
    _identity = next;
    _epoch++;
    final old = _entries.values.toList();
    _entries.clear();
    for (final entry in old) {
      entry.retired = true;
      if (!entry.abort.isCompleted) entry.abort.complete();
      if (entry.users == 0) unawaited(_remove(entry));
    }
    _changes.add(null);
  }

  Future<void> _remove(_AccountResourceEntry entry) async {
    try {
      final file = await entry.file;
      if (await file.exists()) await file.delete();
    } catch (_) {}
    try {
      if (_closed && _root != null) {
        final root = await _root!;
        if (await root.exists() && await root.list().isEmpty) {
          await root.delete();
        }
      }
    } on FileSystemException {
      // Another released lease may have removed the empty directory.
    }
  }

  Future<AccountResourceLease> acquire(
    Uri uri, {
    int? maximumBytes,
    Future<void>? cancelled,
  }) async {
    if (_closed) throw const AccountResourceCancelled();
    await _account.load();
    if (_closed) throw const AccountResourceCancelled();
    _changed();
    final identity = _identity, key = '$_epoch:$uri';
    final entry = _entries.putIfAbsent(key, () {
      final entry = _AccountResourceEntry();
      entry.file = _download(uri, entry, maximumBytes).catchError((
        Object error,
        StackTrace stack,
      ) {
        if (identical(_entries[key], entry)) _entries.remove(key);
        Error.throwWithStackTrace(error, stack);
      });
      return entry;
    });
    entry.users++;
    entry.used = DateTime.now().microsecondsSinceEpoch;
    try {
      final file = await Future.any<File>([
        entry.file,
        if (cancelled != null)
          cancelled.then<File>((_) => throw const AccountResourceCancelled()),
      ]);
      entry.bytes = await file.length();
      if (entry.retired || identity != _currentIdentity) {
        throw const AccountError('account_changed');
      }
      return AccountResourceLease._(file, () async {
        entry.users--;
        if (entry.users == 0) {
          if (entry.retired) {
            await _remove(entry);
          } else {
            await _trim();
          }
        }
      }, entry.mediaType);
    } catch (_) {
      entry.users--;
      if (entry.users == 0) {
        if (identical(_entries[key], entry)) _entries.remove(key);
        entry.retired = true;
        if (!entry.abort.isCompleted) entry.abort.complete();
        unawaited(_remove(entry));
      }
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _account.removeListener(_changed);
    final entries = _entries.values.toList();
    _entries.clear();
    for (final e in entries) {
      e.retired = true;
      if (!e.abort.isCompleted) e.abort.complete();
    }
    await Future.wait([
      for (final e in entries)
        if (e.users == 0) _remove(e),
    ]);
    MediaLifecycle.unregister(this);
  }

  Future<void> _trim() async {
    var bytes = _entries.values.fold<int>(0, (sum, e) => sum + e.bytes);
    final unused = _entries.entries.where((e) => e.value.users == 0).toList()
      ..sort((a, b) => a.value.used.compareTo(b.value.used));
    for (final item in unused) {
      if (bytes <= 128 * 1024 * 1024) break;
      _entries.remove(item.key);
      bytes -= item.value.bytes;
      await _remove(item.value);
    }
  }

  Future<File> _download(
    Uri uri,
    _AccountResourceEntry entry,
    int? maximumBytes,
  ) async {
    final root = await (_root ??= getTemporaryDirectory().then(
      (d) => d.createTemp('haneoka-private-'),
    ));
    final key = sha256.convert(
      utf8.encode('$_epoch:$uri:${DateTime.now().microsecondsSinceEpoch}'),
    );
    final file = File(p.join(root.path, 'haneoka-account-$key.resource'));
    var target = uri;
    IOSink? output;
    try {
      for (var redirect = 0; redirect < 6; redirect++) {
        final request =
            http.AbortableRequest(
                'GET',
                target,
                abortTrigger: entry.abort.future,
              )
              ..followRedirects = false
              ..headers.addAll({
                if (target.origin == SiteOrigin.instance.value.origin)
                  ..._account.authorization,
              });
        final response = await sendFileRequest(request)
            .timeout(const Duration(seconds: 30));
        if (response.statusCode >= 300 &&
            response.statusCode < 400 &&
            response.headers['location'] != null) {
          await response.stream.drain<void>();
          target = target.resolve(response.headers['location']!);
          continue;
        }
        if (response.statusCode != 200) {
          await response.stream.drain<void>();
          throw HttpException('HTTP ${response.statusCode}', uri: target);
        }
        entry.mediaType = response.headers['content-type']?.split(';').first;
        var received = 0;
        output = file.openWrite();
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          received += chunk.length;
          if (maximumBytes != null && received > maximumBytes) {
            throw const FormatException('file_size');
          }
          output.add(chunk);
        }
        await output.flush();
        await output.close();
        output = null;
        return file;
      }
      throw const HttpException('Redirect limit');
    } catch (_) {
      if (!entry.abort.isCompleted) entry.abort.complete();
      await output?.close();
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }
}
