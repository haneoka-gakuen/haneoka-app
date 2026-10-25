import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'net.dart';
import 'offline_files.dart';
import 'public_document_cache.dart';
import 'storage.dart';

export 'public_document_cache.dart';

/// JSON and HTML decoders can share HTTP bytes without sharing model types.
Future<Object?> decodePublicJson(Uint8List bytes) =>
    Isolate.run(() => jsonDecode(utf8.decode(bytes)));

/// One store for public API JSON, generated HTML, and all their decoders.
final _documentStorage = _AppDocumentStorage();
final publicDocumentCache = PublicDocumentCache(
  client: netClient,
  storage: _documentStorage,
);

Future<Directory>? _cacheDirectory;
Future<Directory> _directory() =>
    _cacheDirectory ??= getApplicationCacheDirectory();
String _hash(String value) => sha256.convert(utf8.encode(value)).toString();

// Static isolate entry points capture only transferable paths/identity strings.
Future<StoredPublicDocument> _readStoredFile(String path, String identity) =>
    Isolate.run(() {
      final bytes = File(path).readAsBytesSync();
      if (bytes.length < 4) throw const FormatException('Cache header');
      final size = ByteData.sublistView(bytes).getUint32(0);
      if (size > 65536 || size + 4 > bytes.length) {
        throw const FormatException('Cache header length');
      }
      final meta = jsonDecode(utf8.decode(bytes.sublist(4, size + 4)));
      final body = Uint8List.sublistView(bytes, size + 4);
      if (meta is! Map ||
          meta['v'] != 1 ||
          meta['identity'] != identity ||
          meta['validatedAt'] is! String ||
          (meta['etag'] != null && meta['etag'] is! String) ||
          (meta['lastModified'] != null && meta['lastModified'] is! String) ||
          sha256.convert(body).toString() != meta['digest']) {
        throw const FormatException('Cache identity');
      }
      return StoredPublicDocument(
        bytes: body,
        digest: meta['digest'] as String,
        validatedAt: DateTime.parse(meta['validatedAt'] as String),
        etag: meta['etag'] as String?,
        lastModified: meta['lastModified'] as String?,
      );
    });

Future<StoredPublicDocument> _readLegacyFile(String path) => Isolate.run(() {
  final bytes = File(path).readAsBytesSync();
  jsonDecode(utf8.decode(bytes));
  return StoredPublicDocument(
    bytes: bytes,
    digest: sha256.convert(bytes).toString(),
    validatedAt: DateTime.fromMillisecondsSinceEpoch(0),
  );
});

PublicDocumentKey _activePinKey(String origin, String server) =>
    PublicDocumentKey(
      uri: Uri.parse(origin).resolve('/.haneoka-app-cache/active-release'),
      server: server,
    );

/// Local active identity is separate from the latest HTTP identity: an
/// interrupted background preparation cannot promote an incomplete snapshot.
Future<Map<String, Object?>?> readActiveApiPin(
  String origin,
  String server,
) async {
  try {
    final document = await _documentStorage.read(_activePinKey(origin, server));
    if (document == null) return null;
    final decoded = jsonDecode(utf8.decode(document.bytes));
    return decoded is Map<String, Object?> ? decoded : null;
  } on Exception {
    return null;
  }
}

Future<void> writeActiveApiPin(
  String origin,
  String server,
  Map<String, Object?> pin,
  int generation,
) async {
  final bytes = Uint8List.fromList(utf8.encode(jsonEncode(pin)));
  try {
    await _documentStorage.write(
      _activePinKey(origin, server),
      StoredPublicDocument(
        bytes: bytes,
        digest: sha256.convert(bytes).toString(),
        validatedAt: DateTime.now(),
      ),
      generation,
    );
  } on Exception {
    // A working network snapshot is usable even when pin persistence is full.
  }
}

final class _AppDocumentStorage implements PublicDocumentStorage {
  @override
  int get generation => CacheStorage.instance.generation;

  Future<File> _file(PublicDocumentKey key) async => File(
    p.join(
      (await _directory()).path,
      'api',
      'v2',
      _hash(key.origin),
      _hash(key.server),
      _hash('${key.releaseId ?? ''}\u0000${key.sourceId ?? ''}'),
      '${_hash(key.uri.toString())}.cache',
    ),
  );

  @override
  Future<StoredPublicDocument?> read(PublicDocumentKey key) async {
    final offline = await OfflineFiles.instance.readBytes(key.uri);
    if (offline != null) {
      return StoredPublicDocument(
        bytes: offline,
        digest: sha256.convert(offline).toString(),
        validatedAt: DateTime.now(),
      );
    }
    final storage = CacheStorage.instance;
    final file = await _file(key);
    if (storage.canRead(file.path) && await file.exists()) {
      try {
        return await storage.protect([
          file.path,
        ], () => _readStoredFile(file.path, key.identity));
      } on FormatException {
        // A damaged document can be downloaded again without clearing others.
      } on FileSystemException {
        // Data clearing can race an existence check.
      }
    }
    return _legacy(key);
  }

  /// Earlier releases used raw JSON under api/server/release. Only the
  /// historical default origin may migrate this origin-less namespace.
  Future<StoredPublicDocument?> _legacy(PublicDocumentKey key) async {
    if (key.origin != 'https://haneoka.org' ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(key.server)) {
      return null;
    }
    final path = key.uri.path;
    if (!path.startsWith('/api/v1/servers/${key.server}/') &&
        !path.startsWith('/api/v1/garupa/') &&
        !path.startsWith('/api/v1/sekai/') &&
        !path.startsWith('/runtime/${key.server}/')) {
      return null;
    }
    final query = {...key.uri.queryParameters}..remove('release');
    final rawPath = key.uri
        .toString()
        .substring(key.uri.origin.length)
        .split('?')
        .first
        .split('#')
        .first;
    final remainingQuery = Uri(queryParameters: query).query;
    final oldPath =
        '$rawPath${remainingQuery.isEmpty ? '' : '?$remainingQuery'}';
    final name =
        '${base64Url.encode(utf8.encode(oldPath)).replaceAll('=', '')}.json';
    if (name.length > 255) return null;
    final storage = CacheStorage.instance;
    final root = Directory(
      p.join((await _directory()).path, 'api', key.server),
    );
    final files = <File>[];
    if (key.releaseId case final release?) {
      files.add(File(p.join(root.path, release, name)));
    } else if (await root.exists()) {
      final candidates = <(File, DateTime)>[];
      await for (final entry in root.list(followLinks: false)) {
        if (entry is! Directory) continue;
        final file = File(p.join(entry.path, name));
        if (storage.canRead(file.path) && await file.exists()) {
          candidates.add((file, await file.lastModified()));
        }
      }
      candidates.sort((a, b) => b.$2.compareTo(a.$2));
      files.addAll(candidates.map((entry) => entry.$1));
    }
    for (final file in files) {
      if (!storage.canRead(file.path) || !await file.exists()) continue;
      try {
        return await storage.protect([
          file.path,
        ], () => _readLegacyFile(file.path));
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  @override
  Future<void> write(
    PublicDocumentKey key,
    StoredPublicDocument document,
    int requestGeneration,
  ) async {
    final storage = CacheStorage.instance;
    final file = await _file(key);
    final temporary = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await storage.protect([file.path, temporary.path], () async {
        if (!storage.permitWrite(requestGeneration, file.path)) return;
        final header = utf8.encode(
          jsonEncode({
            'v': 1,
            'identity': key.identity,
            'digest': document.digest,
            'validatedAt': document.validatedAt.toUtc().toIso8601String(),
            'etag': document.etag,
            'lastModified': document.lastModified,
          }),
        );
        final prefix = Uint8List(4);
        ByteData.sublistView(prefix).setUint32(0, header.length);
        final bytes = BytesBuilder(copy: false)
          ..add(prefix)
          ..add(header)
          ..add(document.bytes);
        await file.parent.create(recursive: true);
        await temporary.writeAsBytes(bytes.takeBytes(), flush: true);
        if (storage.permitWrite(requestGeneration, file.path)) {
          await temporary.rename(file.path);
        }
      });
      storage.scheduleTrim();
    } on FileSystemException {
      // The memory result remains usable when cache storage is unavailable.
    } finally {
      try {
        if (await temporary.exists()) await temporary.delete();
      } on FileSystemException {
        // Storage cleanup also recognizes unfinished .tmp files.
      }
    }
  }
}

/// Recover one coherent historical release before going online. Choosing a
/// release once avoids mixing the newest cached copy of each separate path.
Future<String?> legacyApiRelease(String origin, String server) async {
  if (Uri.parse(origin).origin != 'https://haneoka.org') return null;
  try {
    final root = Directory(p.join((await _directory()).path, 'api', server));
    if (!await root.exists()) return null;
    final entries = <(String, DateTime)>[];
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory) continue;
      final release = p.basename(entry.path);
      if (!RegExp(r'^r-[A-Za-z0-9_-]+$').hasMatch(release)) continue;
      final stat = await entry.stat();
      entries.add((release, stat.modified));
    }
    entries.sort((a, b) => b.$2.compareTo(a.$2));
    return entries.firstOrNull?.$1;
  } on Exception {
    return null;
  }
}
