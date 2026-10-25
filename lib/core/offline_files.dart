import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'net.dart';
import 'storage.dart';

const _schema = 'haneoka-story-offline-v1';
const _origin = String.fromEnvironment(
  'HANEOKA_API_ORIGIN',
  defaultValue: 'https://haneoka.org',
);
final _originUri = Uri.parse(_origin);
final _storyIndex = RegExp(r'^/api/v1/servers/(jp|intl)/stories$');

bool _canRead(Uri uri) {
  if (!const {'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.origin != _originUri.origin ||
      !uri.queryParameters.containsKey('release')) {
    return false;
  }
  if (uri.path.startsWith('/api/v1/servers/')) {
    return uri.queryParameters.keys.every(
      (key) =>
          key == 'release' ||
          (key == 'projection' &&
              uri.queryParameters[key] == '4' &&
              _storyIndex.hasMatch(uri.path)),
    );
  }
  return true;
}

final class OfflineFileLease {
  OfflineFileLease(this.file, this.release);
  final File file;
  final Future<void> Function() release;
}

final class OfflineSnapshotLease {
  OfflineSnapshotLease(this.snapshot, this.release);
  final Map<String, dynamic> snapshot;
  final Future<void> Function() release;
}

final class OfflineDownloadPaused implements Exception {
  const OfflineDownloadPaused();
}

Future<Uint8List> _selectedBytes(String path, String selector) =>
    Isolate.run(() {
      final value = jsonDecode(File(path).readAsStringSync()) as Map;
      return Uint8List.fromList(utf8.encode(jsonEncode(value[selector])));
    });

/// Complete snapshots own references; object files are shared across releases.
final class OfflineFiles extends ChangeNotifier {
  OfflineFiles._();
  static final instance = OfflineFiles._();
  final _snapshots = <String, Map<String, dynamic>>{};
  final _retained = <Object, Map<String, dynamic>>{};
  final _latest = <String, Map<String, dynamic>>{};
  final _aliases = <String, String>{};
  final _held = <String, int>{};
  final _retireAfterUse = <String>{};
  final _downloads = <String, Future<void>>{};
  final _migrationRefs = <String, List<String>>{};
  final _migrationRoots = <String>[];
  final _checkedAt = <String, DateTime>{};
  Future<void>? _opening;
  Future<void>? _collecting;
  late Directory _root;
  final _pending = <String, Map<String, dynamic>>{};
  Future<void>? _abort;
  Completer<void>? _cancel;
  bool running = false;
  int completedBytes = 0, totalBytes = 0;
  String? activeServer;
  Object? error;

  Map<String, dynamic>? snapshot(String server) => _snapshots[server];
  Map<String, dynamic>? available(String server) =>
      _latest[server] ?? _snapshots[server];
  bool downloaded(String server, String package) =>
      (_snapshots[server]?['selected'] as List? ?? const []).contains(package);
  bool updateAvailable(String server) =>
      _latest[server] != null &&
      _snapshots[server] != null &&
      _latest[server]!['sha256'] != _snapshots[server]!['sha256'];

  Future<void> initialize() => _opening ??= _open();
  Future<void> _open() async {
    _root = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'offline', 'v1'),
    );
    await Directory(p.join(_root.path, 'objects')).create(recursive: true);
    final file = File(p.join(_root.path, 'library.json'));
    if (await file.exists()) {
      final value = jsonDecode(await file.readAsString()) as Map;
      for (final entry in (value['snapshots'] as Map? ?? const {}).entries) {
        _snapshots['${entry.key}'] = Map<String, dynamic>.from(
          entry.value as Map,
        );
      }
      _aliases.addAll(
        (value['aliases'] as Map? ?? const {}).cast<String, String>(),
      );
      for (final entry in (value['pending'] as Map? ?? const {}).entries) {
        _pending['${entry.key}'] = Map<String, dynamic>.from(
          entry.value as Map,
        );
      }
    }
  }

  Future<void> _save() async {
    final file = File(p.join(_root.path, 'library.json'));
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'schema': _schema,
        'snapshots': _snapshots,
        'aliases': _aliases,
        'pending': _pending,
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  File _object(String digest) =>
      File(p.join(_root.path, 'objects', digest.substring(0, 2), digest));
  Uri _url(String path) => _originUri.resolve(path);
  Uri _base(Map snapshot) => _url(
    '/downloads/stories/${snapshot['server']}/${snapshot['releaseId']}/',
  );

  Future<Map<String, dynamic>> _json(Uri uri, {String? digest}) async {
    final response = await netClient
        .get(uri)
        .timeout(const Duration(seconds: 40));
    if (response.statusCode != 200 || response.bodyBytes.length > 16 << 20) {
      throw HttpException('offline_manifest_unavailable', uri: uri);
    }
    if (digest != null &&
        sha256.convert(response.bodyBytes).toString() != digest) {
      throw const FormatException('offline_manifest_digest');
    }
    final value =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    if (value['schema'] != _schema) {
      throw const FormatException('offline_manifest_schema');
    }
    return value;
  }

  Future<void> check(String server, {bool force = false}) async {
    await initialize();
    final last = _checkedAt[server];
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < const Duration(hours: 6)) {
      return;
    }
    final old = _latest[server] ?? _snapshots[server];
    final response = await netClient
        .get(
          _url('/downloads/stories/$server/latest.json'),
          headers: {
            if (old?['etag'] case final String etag)
              HttpHeaders.ifNoneMatchHeader: etag,
          },
        )
        .timeout(const Duration(seconds: 40));
    if (response.statusCode == 304 && old != null) {
      _latest[server] = old;
      _checkedAt[server] = DateTime.now();
      notifyListeners();
      return;
    }
    if (response.statusCode != 200 || response.bodyBytes.length > 65536) {
      throw const HttpException('offline_manifest_unavailable');
    }
    final pointer = jsonDecode(response.body) as Map<String, dynamic>;
    if (pointer['server'] != server ||
        !RegExp(r'^r-[a-f0-9]{20}$').hasMatch('${pointer['releaseId']}') ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch('${pointer['sha256']}')) {
      throw const FormatException('offline_release_identity');
    }
    final root = old?['sha256'] == pointer['sha256']
        ? old!['root'] as Map<String, dynamic>
        : await _json(
            _base(pointer).resolve('manifests/${pointer['sha256']}.json'),
            digest: pointer['sha256'] as String,
          );
    _latest[server] = {
      ...pointer,
      'root': root,
      'etag': response.headers['etag'],
    };
    _checkedAt[server] = DateTime.now();
    notifyListeners();
  }

  Future<Map<String, dynamic>> _manifest(Map snapshot, String digest) async {
    final directory = Directory(p.join(_root.path, 'manifests'));
    final file = File(p.join(directory.path, '$digest.json'));
    if (await file.exists()) {
      final body = await file.readAsBytes();
      if (sha256.convert(body).toString() == digest) {
        return jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      }
    }
    final uri = _base(snapshot).resolve('manifests/$digest.json');
    final response = await netClient
        .get(uri)
        .timeout(const Duration(seconds: 40));
    if (response.statusCode != 200 ||
        response.bodyBytes.length > 16 << 20 ||
        sha256.convert(response.bodyBytes).toString() != digest) {
      throw const FormatException('offline_manifest_digest');
    }
    final value =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    if (value['schema'] != _schema) {
      throw const FormatException('offline_manifest_schema');
    }
    await directory.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(response.bodyBytes, flush: true);
    await temporary.rename(file.path);
    return value;
  }

  Future<Map<String, dynamic>> _compose(
    Map<String, dynamic> snapshot,
    List<String> selected,
  ) async {
    final root = snapshot['root'] as Map;
    final objects = <String, dynamic>{}, resources = <String, dynamic>{};
    final hashes = <String>{root['common'] as String};
    for (final package in (root['packages'] as List).cast<Map>()) {
      if (selected.contains(package['id'])) {
        hashes.add(package['manifest'] as String);
      }
    }
    for (final hash in hashes) {
      final value = await _manifest(snapshot, hash);
      objects.addAll((value['objects'] as Map).cast<String, dynamic>());
      resources.addAll((value['resources'] as Map).cast<String, dynamic>());
    }
    return {
      ...snapshot,
      'selected': selected,
      'objects': objects,
      'resources': resources,
    };
  }

  Future<void> download(
    String server, {
    String? package,
    bool all = false,
    List<String>? packageIds,
    bool forceCheck = false,
  }) async {
    if (running) return;
    await initialize();
    await _collecting;
    if (running) return;
    running = true;
    activeServer = server;
    error = null;
    _cancel = Completer<void>();
    _abort = _cancel!.future;
    notifyListeners();
    try {
      await check(server, force: forceCheck);
      final latest = _latest[server]!;
      final packages = (latest['root']['packages'] as List).cast<Map>();
      final old = _snapshots[server];
      final full = all || old?['all'] == true;
      final selected = full
          ? packages.map((row) => row['id'] as String).toList()
          : <String>{
              ...(old?['selected'] as List? ?? const []).cast<String>(),
              ...?packageIds,
              ?package,
            }.toList();
      selected.removeWhere((id) => !packages.any((row) => row['id'] == id));
      final pending = await _compose(latest, selected);
      pending['all'] = full;
      _migrationRefs.clear();
      for (final entry in (pending['resources'] as Map).entries) {
        if (entry.value['selector'] == null) {
          (_migrationRefs[entry.value['sha256'] as String] ??= []).add(
            entry.key as String,
          );
        }
      }
      final storage = CacheStorage.instance;
      await storage.initialize();
      _migrationRoots
        ..clear()
        ..addAll([
          p.join((await storage.mediaRoot).path, '${storage.mediaGeneration}'),
          p.join(
            (await storage.resourceRoot).path,
            '${storage.resourceGeneration}',
          ),
        ]);
      _pending[server] = pending;
      await _save();
      completedBytes = 0;
      totalBytes = (pending['objects'] as Map).values.fold<int>(
        0,
        (sum, row) => sum + (row['bytes'] as int),
      );
      final entries =
          (pending['objects'] as Map).entries
              .map((entry) => MapEntry(entry.key as String, entry.value as Map))
              .toList()
            ..sort((a, b) => a.key.compareTo(b.key));
      final jobs = <List<MapEntry<String, Map>>>[];
      var small = <MapEntry<String, Map>>[];
      for (final entry in entries) {
        if ((entry.value['bytes'] as int) <= 128 * 1024) {
          small.add(entry);
          if (small.length == 32) {
            jobs.add(small);
            small = [];
          }
        } else {
          jobs.add([entry]);
        }
      }
      if (small.isNotEmpty) jobs.add(small);
      var next = 0;
      Future<void> worker() async {
        while (next < jobs.length) {
          if (_cancel!.isCompleted) throw const OfflineDownloadPaused();
          final job = jobs[next++];
          try {
            await _fetchJob(pending, job);
          } catch (_) {
            if (!_cancel!.isCompleted) _cancel!.complete();
            rethrow;
          }
          completedBytes += job.fold<int>(
            0,
            (sum, entry) => sum + (entry.value['bytes'] as int),
          );
          notifyListeners();
        }
      }

      await Future.wait([worker(), worker()], eagerError: false);
      if (_cancel!.isCompleted) throw const OfflineDownloadPaused();
      final previous = _snapshots[server];
      _snapshots[server] = pending;
      _pending.remove(server);
      try {
        await _save();
      } catch (_) {
        if (previous == null) {
          _snapshots.remove(server);
        } else {
          _snapshots[server] = previous;
        }
        _pending[server] = pending;
        rethrow;
      }
      await _collect();
    } on OfflineDownloadPaused {
      // Completed objects and partial files remain ready for Resume.
    } catch (value) {
      error = value;
    } finally {
      running = false;
      _abort = null;
      activeServer = null;
      notifyListeners();
    }
  }

  void pause() {
    if (_cancel case final cancel? when !cancel.isCompleted) cancel.complete();
  }

  Future<void> resume(String server) async {
    await initialize();
    if (_pending[server] case final pending?) {
      final selected = (pending['selected'] as List).cast<String>();
      await download(
        server,
        packageIds: selected,
        all: pending['all'] == true,
        forceCheck: true,
      );
    }
  }

  Future<void> _fetchJob(Map snapshot, List<MapEntry<String, Map>> job) async {
    if (job.length == 1) {
      await _ensure(snapshot, job.single.key, job.single.value);
      return;
    }
    final needed = <MapEntry<String, Map>>[];
    for (final entry in job) {
      if (_cancel!.isCompleted) throw const OfflineDownloadPaused();
      final file = _object(entry.key);
      if (await file.exists() && await file.length() == entry.value['bytes']) {
        continue;
      }
      await file.parent.create(recursive: true);
      if (await _migrate(snapshot, entry.key, file)) continue;
      final partial = File('${file.path}.part');
      if (await partial.exists() && await partial.length() > 0) {
        await _ensure(snapshot, entry.key, entry.value);
      } else {
        needed.add(entry);
      }
    }
    if (needed.length == 1) {
      await _ensure(snapshot, needed.single.key, needed.single.value);
    } else if (needed.isNotEmpty) {
      await _batch(snapshot, needed);
    }
  }

  Future<void> _batch(Map snapshot, List<MapEntry<String, Map>> entries) async {
    final url = _base(snapshot)
        .resolve('batches/v1')
        .replace(
          queryParameters: {
            'objects': entries.map((entry) => entry.key).join(','),
          },
        );
    final request = http.AbortableRequest('GET', url, abortTrigger: _abort);
    request.headers[HttpHeaders.acceptEncodingHeader] = 'identity';
    try {
      final response = await sendFileRequest(request)
          .timeout(const Duration(seconds: 40));
      if (response.statusCode != 200) {
        await response.stream.listen(null).cancel();
        throw HttpException('offline_batch_http_${response.statusCode}');
      }
      final expected =
          6 +
          entries.fold<int>(
            0,
            (sum, entry) =>
                sum +
                66 +
                '${entry.value['bytes']}'.length +
                (entry.value['bytes'] as int),
          );
      final chunks = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 40),
      )) {
        if (_cancel!.isCompleted) throw const OfflineDownloadPaused();
        if (chunks.length + chunk.length > expected) {
          throw const FormatException('offline_batch_size');
        }
        chunks.add(chunk);
      }
      final bytes = chunks.takeBytes();
      if (bytes.length != expected ||
          utf8.decode(bytes.sublist(0, 6)) != 'HNPK1\n') {
        throw const FormatException('offline_batch_header');
      }
      var offset = 6;
      for (final entry in entries) {
        if (_cancel!.isCompleted) throw const OfflineDownloadPaused();
        final end = bytes.indexOf(10, offset);
        if (end < offset ||
            end - offset > 80 ||
            utf8.decode(bytes.sublist(offset, end)) !=
                '${entry.key}\t${entry.value['bytes']}') {
          throw const FormatException('offline_batch_object');
        }
        final length = entry.value['bytes'] as int;
        offset = end + 1;
        final body = Uint8List.sublistView(bytes, offset, offset + length);
        if (sha256.convert(body).toString() != entry.key) {
          throw const FormatException('offline_resource_digest');
        }
        final file = _object(entry.key),
            partial = File('${_object(entry.key).path}.part');
        await partial.writeAsBytes(body, flush: true);
        await partial.rename(file.path);
        offset += length;
      }
    } on http.RequestAbortedException {
      throw const OfflineDownloadPaused();
    }
  }

  Future<void> _ensure(
    Map snapshot,
    String digest,
    Map entry,
  ) => _downloads.putIfAbsent(digest, () async {
    try {
      final file = _object(digest);
      if (await file.exists() && await file.length() == entry['bytes']) return;
      await file.parent.create(recursive: true);
      if (await _migrate(snapshot, digest, file)) return;
      final partial = File('${file.path}.part');
      var offset = await partial.exists() ? await partial.length() : 0;
      if (offset == entry['bytes']) {
        if ((await sha256.bind(partial.openRead()).first).toString() ==
            digest) {
          await partial.rename(file.path);
          return;
        }
        await partial.delete();
        offset = 0;
      }
      if (offset > entry['bytes']) {
        await partial.delete();
        offset = 0;
      }
      final request = http.AbortableRequest(
        'GET',
        _base(snapshot).resolve('objects/$digest'),
        abortTrigger: _abort,
      );
      request.headers[HttpHeaders.acceptEncodingHeader] = 'identity';
      if (offset > 0) {
        request.headers[HttpHeaders.rangeHeader] = 'bytes=$offset-';
      }
      final response = await sendFileRequest(request)
          .timeout(const Duration(seconds: 40));
      if (response.statusCode != 200 && response.statusCode != 206) {
        await response.stream.listen(null).cancel();
        throw HttpException('offline_resource_http_${response.statusCode}');
      }
      if (response.statusCode == 206 &&
          response.headers['content-range'] !=
              'bytes $offset-${(entry['bytes'] as int) - 1}/${entry['bytes']}') {
        await response.stream.listen(null).cancel();
        throw const FormatException('offline_resource_range');
      }
      final output = await partial.open(
        mode: response.statusCode == 206 ? FileMode.append : FileMode.write,
      );
      try {
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 40),
        )) {
          if (_cancel!.isCompleted) throw const OfflineDownloadPaused();
          await output.writeFrom(chunk);
        }
        await output.flush();
      } finally {
        await output.close();
      }
      if (await partial.length() != entry['bytes'] ||
          (await sha256.bind(partial.openRead()).first).toString() != digest) {
        await partial.delete();
        throw const FormatException('offline_resource_digest');
      }
      await partial.rename(file.path);
    } on http.RequestAbortedException {
      throw const OfflineDownloadPaused();
    } finally {
      _downloads.remove(digest);
    }
  });

  Future<bool> _migrate(Map snapshot, String digest, File target) async {
    final storage = CacheStorage.instance;
    for (final path in _migrationRefs[digest] ?? const <String>[]) {
      final uri = _url(
        path,
      ).replace(queryParameters: {'release': snapshot['releaseId'] as String});
      final family = _url(path).toString();
      for (final directory in _migrationRoots) {
        final index = File(
          p.join(
            directory,
            '${sha256.convert(utf8.encode(family))}.family.json',
          ),
        );
        if (!await index.exists()) continue;
        final data = jsonDecode(await index.readAsString()) as Map;
        final source = File(p.join(directory, '${data['key']}.resource'));
        if (!storage.canRead(source.path) || !await source.exists()) continue;
        final lease = storage.lease([source.path]);
        var reused = false;
        try {
          if ((await sha256.bind(source.openRead()).first).toString() !=
              digest) {
            continue;
          }
          final temporary = File('${target.path}.migrating');
          await source.copy(temporary.path);
          await temporary.rename(target.path);
          _aliases[data['uri'] as String] = digest;
          _aliases[uri.toString()] = digest;
          reused = true;
        } finally {
          await lease.release();
        }
        if (reused) {
          await storage.retire(source);
          return true;
        }
      }
    }
    return false;
  }

  (String, String?)? _reference(Uri uri) {
    if (!_canRead(uri)) return null;
    if (_aliases[uri.toString()] case final digest?) return (digest, null);
    final release = uri.queryParameters['release'];
    if (release == null) return null;
    final path = Uri.decodeComponent(uri.path);
    for (final snapshot in [
      ..._snapshots.values,
      ..._pending.values,
      ..._retained.values,
    ]) {
      if (snapshot['releaseId'] != release) continue;
      final ref = (snapshot['resources'] as Map?)?[path] as Map?;
      if (ref != null) {
        return (ref['sha256'] as String, ref['selector'] as String?);
      }
    }
    return null;
  }

  bool contains(Uri uri) => _reference(uri) != null;

  OfflineSnapshotLease retain(String server) {
    final key = Object(), snapshot = _snapshots[server]!;
    _retained[key] = snapshot;
    return OfflineSnapshotLease(snapshot, () async {
      if (_retained.remove(key) != null && !running) await _collect();
    });
  }

  Future<OfflineFileLease?> acquire(Uri uri) async {
    if (!_canRead(uri)) return null;
    await initialize();
    final ref = _reference(uri);
    if (ref == null || ref.$2 != null) return null;
    final file = _object(ref.$1);
    final lease = _hold(file, ref.$1);
    if (await file.exists()) return lease;
    await lease.release();
    return null;
  }

  OfflineFileLease _hold(File file, String digest) {
    _held.update(digest, (count) => count + 1, ifAbsent: () => 1);
    var released = false;
    return OfflineFileLease(file, () async {
      if (released) return;
      released = true;
      final count = (_held[digest] ?? 1) - 1;
      if (count == 0) {
        _held.remove(digest);
        if (!running && _retireAfterUse.remove(digest)) await _collect();
      } else {
        _held[digest] = count;
      }
    });
  }

  Future<Uint8List?> readBytes(Uri uri) async {
    if (!_canRead(uri)) return null;
    await initialize();
    final ref = _reference(uri);
    if (ref == null) return null;
    final file = _object(ref.$1);
    final lease = _hold(file, ref.$1);
    try {
      if (!await file.exists()) return null;
      if (ref.$2 case final selector?) {
        return await _selectedBytes(file.path, selector);
      }
      return await file.readAsBytes();
    } finally {
      await lease.release();
    }
  }

  Future<void> remove(String server, {String? package}) async {
    if (running) return;
    await initialize();
    final old = _snapshots[server];
    if (old == null) {
      if (_pending.remove(server) == null) return;
      await _save();
      await _collect();
      notifyListeners();
      return;
    }
    final selected = (old['selected'] as List)
        .cast<String>()
        .where((id) => id != package)
        .toList();
    if (package == null || selected.isEmpty) {
      _snapshots.remove(server);
    } else {
      _snapshots[server] = {...await _compose(old, selected), 'all': false};
    }
    _pending.remove(server);
    await _save();
    await _collect();
    notifyListeners();
  }

  Future<void> _collect() =>
      _collecting ??= _sweep().whenComplete(() => _collecting = null);

  Future<void> _sweep() async {
    final used = <String>{};
    for (final snapshot in [
      ..._snapshots.values,
      ..._pending.values,
      ..._retained.values,
    ]) {
      used.addAll(
        (snapshot['objects'] as Map? ?? const {}).keys.cast<String>(),
      );
    }
    _retireAfterUse.addAll(
      _held.keys.where((digest) => !used.contains(digest)),
    );
    used.addAll(_held.keys);
    _aliases.removeWhere((_, digest) => !used.contains(digest));
    final objects = Directory(p.join(_root.path, 'objects'));
    await for (final entity in objects.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File &&
          !used.contains(p.basename(entity.path).replaceFirst('.part', ''))) {
        await entity.delete();
      }
    }
    _aliases.removeWhere((_, digest) => !used.contains(digest));
    final manifests = <String>{};
    for (final snapshot in [
      ..._snapshots.values,
      ..._pending.values,
      ..._retained.values,
    ]) {
      final root = snapshot['root'] as Map;
      manifests.add(root['common'] as String);
      for (final package in (root['packages'] as List).cast<Map>()) {
        if ((snapshot['selected'] as List).contains(package['id'])) {
          manifests.add(package['manifest'] as String);
        }
      }
    }
    final manifestRoot = Directory(p.join(_root.path, 'manifests'));
    if (await manifestRoot.exists()) {
      await for (final entity in manifestRoot.list(followLinks: false)) {
        if (entity is File &&
            !manifests.contains(
              p.basename(entity.path).replaceFirst('.json', ''),
            )) {
          await entity.delete();
        }
      }
    }
    await _save();
  }

  bool resumable(String server) => _pending.containsKey(server);
}
