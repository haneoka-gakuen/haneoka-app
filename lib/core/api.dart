import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'net.dart';
import 'storage.dart';

Future<Object?> _decodeResponse(List<int> bytes) =>
    Isolate.run(() => jsonDecode(utf8.decode(bytes)));

/// Haneoka's public API, the same one the website reads. Responses are kept
/// on disk per release, so a release's data is downloaded once and the app
/// works offline with what it has seen.
class HaneokaApi {
  HaneokaApi({this.origin = 'https://haneoka.org', required this.server}) {
    _instances.add(WeakReference(this));
    // The release pin is the first thing every page needs; ask at once.
    release();
  }
  final String origin;

  /// `jp` or `intl`.
  final String server;
  http.Client get _client => netClient;
  String? _releaseId;
  final Map<String, Future<Object?>> _inFlight = {};

  static final _instances = <WeakReference<HaneokaApi>>[];
  static final _resourceCaches = <Map<dynamic, dynamic>>{};
  static void invalidateCaches() {
    for (final cache in _resourceCaches) {
      cache.clear();
    }
    _instances.removeWhere((reference) => reference.target == null);
    for (final reference in _instances) {
      final api = reference.target;
      if (api == null) continue;
      api._releaseFuture = null;
      api._releaseId = null;
      api._releaseRetryAt = null;
    }
  }

  static final _releasePins = <String, String>{};
  Uri asset(String path) {
    final uri = Uri.parse(origin).resolve(path);
    final parts = uri.pathSegments;
    if (!const {'http', 'https'}.contains(uri.scheme) ||
        uri.origin != Uri.parse(origin).origin ||
        parts.length < 2 ||
        !const {'assets', 'runtime'}.contains(parts.first) ||
        uri.queryParameters.containsKey('release')) {
      return uri;
    }
    final pin = _releasePins['$origin:${parts[1]}'];
    if (pin == null || pin == 'offline') return uri;
    return uri.replace(
      queryParameters: {...uri.queryParameters, 'release': pin},
    );
  }

  /// The release identity; data is cached under it so a new release refetches.
  Future<String>? _releaseFuture;
  DateTime? _releaseRetryAt;

  Future<String> release() {
    if (_releaseId == 'offline' &&
        _releaseRetryAt != null &&
        DateTime.now().isAfter(_releaseRetryAt!)) {
      _releaseId = null;
      _releaseFuture = null;
    }
    return _releaseFuture ??= _release();
  }

  Future<String> _release() async {
    if (_releaseId != null) return _releaseId!;
    try {
      final body = await _get(
        '/api/v1/servers/$server/release?projection=identity',
      ) as Map<String, Object?>;
      _releaseId = body['releaseId'] as String;
      _releasePins['$origin:$server'] = _releaseId!;
      return _releaseId!;
    } on Exception {
      _releaseRetryAt = DateTime.now().add(const Duration(minutes: 1));
      return _releaseId = 'offline';
    }
  }

  /// A catalogue resource (`songs`, `cards`, …) or one entity of it.
  Future<Object?> catalog(String resource, [String? id]) async {
    final path =
        '/api/v1/servers/$server/$resource${id == null ? '' : '/${Uri.encodeComponent(id)}'}'
        '${id == null && resource == 'songs' ? '?projection=4' : ''}';
    return json(path);
  }

  /// Live data (game records), never cached.
  Future<Object?> live(String path) async => (await _download(path)).$1;

  /// Any API path, through the per-release cache.
  Future<Object?> json(String path) =>
      _inFlight[path] ??= _cached(path).whenComplete(() {
        _inFlight.remove(path);
      });

  Future<Object?> _cached(String path) async {
    final storage = CacheStorage.instance;
    final requestGeneration = storage.generation;
    final release = await this.release();
    final dir = await getApplicationCacheDirectory();
    final file = File(
      p.join(
        dir.path,
        'api',
        server,
        release,
        '${base64Url.encode(utf8.encode(path)).replaceAll('=', '')}.json',
      ),
    );
    if (await file.exists() && storage.canRead(file.path)) {
      try {
        return await storage.protect([file.path], () => _decodeFile(file.path));
      } on FormatException {
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // Clearing a stale cache may race the initial existence check.
      }
    }
    try {
      final body = await _download(path);
      final temporary = File(
        '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      try {
        await storage.protect([file.path, temporary.path], () async {
          if (!storage.permitWrite(requestGeneration, file.path)) return;
          await file.parent.create(recursive: true);
          await temporary.writeAsBytes(body.$2, flush: true);
          if (storage.permitWrite(requestGeneration, file.path)) {
            await temporary.rename(file.path);
          }
        });
        storage.scheduleTrim();
      } on FileSystemException {
        // A full or read-only cache must not discard a downloaded document.
      } finally {
        try {
          if (await temporary.exists()) await temporary.delete();
        } on FileSystemException {
          // The next cache cleanup can remove the unfinished temporary file.
        }
      }
      return body.$1;
    } on Exception {
      final stale = await _latestStale(dir, path);
      if (stale != null) return stale;
      rethrow;
    }
  }

  /// The newest copy from an earlier release, for offline use.
  Future<Object?> _latestStale(Directory dir, String path) async {
    final root = Directory(p.join(dir.path, 'api', server));
    if (!await root.exists()) return null;
    final name =
        '${base64Url.encode(utf8.encode(path)).replaceAll('=', '')}.json';
    final candidates = <(File, DateTime)>[];
    await for (final release in root.list()) {
      if (release is! Directory) continue;
      final file = File(p.join(release.path, name));
      if (await file.exists()) {
        candidates.add((file, await file.lastModified()));
      }
    }
    candidates.sort((a, b) => b.$2.compareTo(a.$2));
    for (final (file, _) in candidates) {
      try {
        if (!CacheStorage.instance.canRead(file.path)) continue;
        return await CacheStorage.instance.protect([
          file.path,
        ], () => _decodeFile(file.path));
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  /// Large documents (the song list is half a megabyte) decode off the UI
  /// thread; `Isolate.run` hands the result back without copying it.
  static Future<Object?> _decodeFile(String path) =>
      Isolate.run(() => jsonDecode(utf8.decode(File(path).readAsBytesSync())));

  Future<(Object?, List<int>)> _download(String path) async {
    final response = await _client
        .get(Uri.parse('$origin$path'), headers: {'accept': 'application/json'})
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(path));
    }
    final bytes = response.bodyBytes;
    return (await _decodeResponse(bytes), bytes);
  }

  Future<Object?> _get(String path) async {
    final response = await _client
        .get(Uri.parse('$origin$path'), headers: {'accept': 'application/json'})
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(path));
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }
}

/// Failed loads leave the cache so a retry can make a fresh request.
Future<T> cachedResource<K, T>(
  Map<K, Future<T>> cache,
  K key,
  Future<T> Function() load,
) {
  HaneokaApi._resourceCaches.add(cache);
  if (cache[key] case final existing?) return existing;
  late final Future<T> request;
  request = load().catchError((Object error, StackTrace trace) {
    if (identical(cache[key], request)) cache.remove(key);
    Error.throwWithStackTrace(error, trace);
  });
  cache[key] = request;
  return request;
}
