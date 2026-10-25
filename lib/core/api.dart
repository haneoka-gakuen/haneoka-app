import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'document_cache.dart';
import 'net.dart';
import 'storage.dart';

final class _ReleasePin {
  const _ReleasePin(this.release, this.source);
  factory _ReleasePin.fromJson(Object? value) {
    if (value is! Map ||
        value['releaseId'] is! String ||
        (value['sourceId'] != null && value['sourceId'] is! String)) {
      throw const FormatException('Release identity');
    }
    final map = value;
    final release = map['releaseId'] as String;
    if (!RegExp(r'^r-[A-Za-z0-9_-]+$').hasMatch(release)) {
      throw const FormatException('Release identity');
    }
    return _ReleasePin(release, map['sourceId'] as String?);
  }
  final String release;
  final String? source;
  String get identity => '$release\u0000${source ?? ''}';
  Map<String, Object?> toJson() => {'releaseId': release, 'sourceId': source};
}

/// Public API consumer over the same document store used by generated pages.
/// Release changes are prepared before publishing one coherent new snapshot.
class HaneokaApi extends ChangeNotifier {
  HaneokaApi({
    this.origin = const String.fromEnvironment(
      'HANEOKA_API_ORIGIN',
      defaultValue: 'https://haneoka.org',
    ),
    required this.server,
    bool eagerRelease = true,
    this.offlineRelease,
    this.offlineSource,
  }) {
    _instances.add(WeakReference(this));
    final reference = WeakReference(this);
    _subscription = publicDocumentCache.changes.listen((change) {
      reference.target?._documentChanged(change);
    });
    if (eagerRelease) unawaited(release());
  }

  final String origin, server;
  final String? offlineRelease, offlineSource;
  _ReleasePin? _pin, _pendingPin;
  Future<String>? _opening;
  Future<void>? _promotion;
  DateTime? _releaseRetryAt, _promotionRetryAt;
  late final StreamSubscription<PublicDocumentChange> _subscription;
  int _generation = CacheStorage.instance.generation;
  int _epoch = 0, _revision = 0;
  bool _disposed = false;
  final _paths = <String>{};
  final _keys = <String, PublicDocumentKey>{};

  String? get sourceId => _pin?.source;
  int get revision => _revision;
  PublicDocumentKey get _identityKey => PublicDocumentKey(
    uri: Uri.parse(origin)
        .resolve('/api/v1/servers/$server/release?projection=identity'),
    server: server,
  );

  static final _instances = <WeakReference<HaneokaApi>>[];
  static final _resourceCaches = <Map<dynamic, dynamic>>{};
  static final _releasePins = <String, String>{};

  static void _clearResourceCaches() {
    for (final cache in _resourceCaches) {
      cache.clear();
    }
  }

  static void clearResourceViews() => _clearResourceCaches();

  static void invalidateCaches() {
    _clearResourceCaches();
    publicDocumentCache.invalidate();
    _releasePins.clear();
    _instances.removeWhere((reference) => reference.target == null);
    for (final reference in _instances) {
      reference.target?._reset();
    }
  }

  void _reset() {
    _generation = CacheStorage.instance.generation;
    _epoch++;
    _pin = _pendingPin = null;
    _opening = null;
    _promotion = null;
    _releaseRetryAt = _promotionRetryAt = null;
    _paths.clear();
    _keys.clear();
    _releasePins.remove('${Uri.parse(origin).origin}:$server');
    _changed();
  }

  void _syncGeneration() {
    if (_generation != CacheStorage.instance.generation) _reset();
  }

  void _changed() {
    if (_disposed) return;
    _clearResourceCaches();
    _revision++;
    notifyListeners();
  }

  void _setPin(_ReleasePin pin) {
    _pin = pin;
    _releasePins['${Uri.parse(origin).origin}:$server'] = pin.release;
  }

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
    final pin = parts[1] == server && offlineRelease != null
        ? offlineRelease
        : _releasePins['${uri.origin}:${parts[1]}'];
    if (pin == null) return uri;
    return uri.replace(
      queryParameters: {...uri.queryParameters, 'release': pin},
    );
  }

  /// Cached active identity is available without waiting for network freshness.
  Future<String> release() {
    if (offlineRelease case final release?) {
      _pin = _ReleasePin(release, offlineSource);
      return Future.value(release);
    }
    _syncGeneration();
    if (_pin case final pin?) {
      _checkIdentityLater();
      return Future.value(pin.release);
    }
    if (_releaseRetryAt != null && DateTime.now().isAfter(_releaseRetryAt!)) {
      _opening = null;
    }
    return _opening ??= _openPin();
  }

  Future<String> _openPin() async {
    final epoch = _epoch;
    try {
      final active = await readActiveApiPin(origin, server);
      if (epoch != _epoch) return await release();
      if (active != null) {
        try {
          _setPin(_ReleasePin.fromJson(active));
          _checkIdentityLater();
          return _pin!.release;
        } on FormatException {
          // Recover a usable identity from existing documents or the public API.
        }
      }
      final oldRelease = await legacyApiRelease(origin, server);
      if (epoch != _epoch) return await release();
      if (oldRelease != null) {
        _setPin(_ReleasePin(oldRelease, null));
        _checkIdentityLater();
        return oldRelease;
      }
      final pin = await _identity();
      if (epoch != _epoch) return await release();
      await writeActiveApiPin(origin, server, pin.toJson(), _generation);
      if (epoch != _epoch) return await release();
      _setPin(pin);
      return pin.release;
    } on Exception {
      if (epoch != _epoch) return await release();
      _releaseRetryAt = DateTime.now().add(const Duration(minutes: 1));
      return 'offline';
    }
  }

  Future<_ReleasePin> _identity() => publicDocumentCache.read<_ReleasePin>(
    key: _identityKey,
    decodeVariant: 'api.release.identity.v1',
    decode: (bytes) => _ReleasePin.fromJson(jsonDecode(utf8.decode(bytes))),
  );

  void _checkIdentityLater() {
    if (_disposed) return;
    unawaited(_identity().then(_adopt).catchError((Object _) {}));
  }

  Future<void> _adopt(_ReleasePin next) async {
    if (_disposed || _pin?.identity == next.identity) return;
    _pendingPin = next;
    if (_promotion case final current?) {
      await current;
      if (_pendingPin != null && !_disposed) await _adopt(_pendingPin!);
      return;
    }
    if (_promotionRetryAt?.isAfter(DateTime.now()) ?? false) {
      return;
    }
    final epoch = _epoch;
    late final Future<void> task;
    task = _prepareSnapshot(epoch).whenComplete(() {
      if (identical(_promotion, task)) _promotion = null;
    });
    _promotion = task;
    await task;
  }

  Future<void> _prepareSnapshot(int epoch) async {
    try {
      while (_pendingPin != null) {
        final next = _pendingPin!;
        _pendingPin = null;
        if (_pin?.identity == next.identity) continue;
        final loaded = <String>{};
        while (true) {
          final missing = _paths
              .where((path) => _isVersioned(path) && !loaded.contains(path))
              .take(3)
              .toList();
          if (missing.isEmpty) break;
          await Future.wait(missing.map((path) => _readAt(path, next)));
          loaded.addAll(missing);
          if (epoch != _epoch || _disposed) return;
        }
        if (epoch != _epoch || _disposed) return;
        if (_pendingPin != null && _pendingPin!.identity != next.identity) {
          continue;
        }
        await writeActiveApiPin(origin, server, next.toJson(), _generation);
        if (epoch != _epoch || _disposed) return;
        _setPin(next);
        for (final path in _paths) {
          _keys[path] = _key(path, next);
        }
        _promotionRetryAt = null;
        _changed();
      }
    } on Exception {
      _promotionRetryAt = DateTime.now().add(const Duration(minutes: 1));
      // The active release and its decoded data remain available.
    }
  }

  void _documentChanged(PublicDocumentChange change) {
    if (_disposed) return;
    _syncGeneration();
    if (change.key == _identityKey) {
      _checkIdentityLater();
    } else if (_keys.values.contains(change.key)) {
      _changed();
    }
  }

  bool _isVersioned(String path) {
    final uri = Uri.parse(origin).resolve(path);
    return uri.origin == Uri.parse(origin).origin &&
        (uri.path.startsWith('/api/v1/servers/$server/') ||
            uri.path.startsWith('/runtime/$server/') ||
            uri.path.startsWith('/assets/$server/'));
  }

  PublicDocumentKey _key(String path, _ReleasePin? pin) {
    var uri = Uri.parse(origin).resolve(path);
    final versioned = _isVersioned(path);
    if (versioned && pin != null) {
      uri = uri.replace(
        queryParameters: {...uri.queryParameters, 'release': pin.release},
      );
    }
    return PublicDocumentKey(
      uri: uri,
      server: server,
      releaseId: versioned ? pin?.release : null,
      sourceId: versioned ? pin?.source : null,
    );
  }

  Future<Object?> _readAt(String path, _ReleasePin? pin) =>
      publicDocumentCache.read<Object?>(
        key: _key(path, pin),
        decodeVariant: 'json.v1',
        decode: decodePublicJson,
        revalidateAfter: _isVersioned(path) ? null : const Duration(minutes: 5),
      );

  Future<Object?> json(String path) async {
    _syncGeneration();
    _paths.remove(path);
    _paths.add(path);
    while (_paths.length > 48) {
      _keys.remove(_paths.first);
      _paths.remove(_paths.first);
    }
    final epoch = _epoch;
    if (_isVersioned(path)) {
      await release();
      if (_pin == null) throw const HttpException('Release is unavailable');
    }
    if (epoch != _epoch) return json(path);
    final pin = _pin;
    _keys[path] = _key(path, pin);
    final value = await _readAt(path, pin);
    if (epoch != _epoch ||
        (_isVersioned(path) && pin?.identity != _pin?.identity)) {
      return json(path);
    }
    return value;
  }

  Future<Object?> catalog(String resource, [String? id]) {
    final projection = id == null
        ? const {'songs': 4, 'ui-marks': 2}[resource]
        : null;
    return json(
      '/api/v1/servers/$server/$resource${id == null ? '' : '/${Uri.encodeComponent(id)}'}'
      '${projection == null ? '' : '?projection=$projection'}',
    );
  }

  /// Account/live records remain outside the public cache.
  Future<Object?> live(String path) async {
    final response = await netClient
        .get(
          Uri.parse(origin).resolve(path),
          headers: {'accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(path));
    }
    return decodePublicJson(response.bodyBytes);
  }

  /// Explicit refresh retains the visible snapshot until a replacement is ready.
  Future<void> revalidate() async {
    if (_pin != null || _paths.any(_isVersioned)) {
      await publicDocumentCache.refresh(_identityKey);
      _promotionRetryAt = null;
      await _adopt(await _identity());
    }
    await Future.wait(
      _paths
          .where((path) => !_isVersioned(path))
          .map((path) => publicDocumentCache.refresh(_key(path, null))),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    unawaited(_subscription.cancel());
    super.dispose();
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
