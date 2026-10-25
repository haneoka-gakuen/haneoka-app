import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'net.dart';
import 'offline_files.dart';
import 'account_resource.dart';
import 'storage.dart';

enum ResourceFileKind { media, renderResource }

final resourceFileCache = ResourceFileCache();

final class ResourceCacheCancelled implements Exception {
  const ResourceCacheCancelled();
}

/// The original URI remains the resource identity; resource consumers use [file].
final class ResourceFileLease {
  ResourceFileLease._(this.uri, this.file, this._lease, [this._release]);
  final Uri uri;
  final File file;
  final StorageLease? _lease;
  final Future<void> Function()? _release;
  Future<Uint8List> readBytes() => file.readAsBytes();
  Future<void> release() async {
    await _lease?.release();
    await _release?.call();
  }
}

final class _ResourceDownload {
  final aborted = Completer<void>();
  late final Future<File> file;
  int users = 0;
  bool done = false;
}

final class _ResourceValidator {
  const _ResourceValidator(this.file, this.etag, this.bytes, this.lease);
  final File file;
  final String etag;
  final int bytes;
  final StorageLease lease;
}

/// Shared original resource files, independent of artwork and JSON documents.
/// Downloads are streamed to disk; memory is allocated only by explicit reads.
final class ResourceFileCache {
  static const _networkIdleTimeout = Duration(seconds: 30);
  final _downloads = <String, _ResourceDownload>{};
  int _temporaryId = 0;

  String? _family(Uri uri) {
    if (!(uri.queryParametersAll['release']?.any((value) => value.isNotEmpty) ??
        false)) {
      return null;
    }
    final query = uri.query
        .split('&')
        .where((entry) => entry.split('=').first != 'release')
        .join('&');
    return uri.replace(query: query, fragment: '').toString();
  }

  bool _strongEtag(String value) =>
      value.length >= 2 &&
      value.startsWith('"') &&
      value.endsWith('"') &&
      value.codeUnits
          .skip(1)
          .take(value.length - 2)
          .every(
            (unit) =>
                unit == 0x21 ||
                (unit >= 0x23 && unit <= 0x7e) ||
                (unit >= 0x80 && unit <= 0xff),
          );

  Future<_ResourceValidator?> _previous(Uri uri, File index) async {
    final storage = CacheStorage.instance;
    final indexLease = storage.lease([index.path]);
    StorageLease? sourceLease;
    try {
      if (!storage.canRead(index.path) || !await index.exists()) return null;
      final value = jsonDecode(await index.readAsString());
      if (value is! Map<String, dynamic> ||
          value['schema'] != 'haneoka-resource-validator-v1') {
        return null;
      }
      final sourceUri = value['uri'];
      final key = value['key'];
      final etag = value['etag'];
      final bytes = value['bytes'];
      if (sourceUri is! String ||
          key is! String ||
          etag is! String ||
          bytes is! int ||
          bytes < 1 ||
          !_strongEtag(etag) ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(key) ||
          sha256.convert(utf8.encode(sourceUri)).toString() != key ||
          _family(Uri.parse(sourceUri)) != _family(uri)) {
        return null;
      }
      final source = File(p.join(index.parent.path, '$key.resource'));
      sourceLease = storage.lease([source.path]);
      if (!storage.canRead(source.path) ||
          !await source.exists() ||
          await source.length() != bytes) {
        return null;
      }
      final previous = _ResourceValidator(source, etag, bytes, sourceLease);
      sourceLease = null;
      return previous;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } finally {
      await sourceLease?.release();
      await indexLease.release();
    }
  }

  Future<void> _remember(
    Uri uri,
    File file,
    File index,
    String? etag,
    int bytes,
    CacheCategory category,
    int generation,
  ) async {
    if (etag == null || !_strongEtag(etag)) return;
    final storage = CacheStorage.instance;
    final temporary = File(
      '${index.path}.${DateTime.now().microsecondsSinceEpoch}.${_temporaryId++}.tmp',
    );
    try {
      await storage.protect([index.path, temporary.path], () async {
        if (!storage.permitFileWrite(category, generation, index.path)) return;
        await temporary.writeAsString(
          jsonEncode({
            'schema': 'haneoka-resource-validator-v1',
            'uri': uri.toString(),
            'key': p.basenameWithoutExtension(file.path),
            'etag': etag,
            'bytes': bytes,
          }),
          flush: true,
        );
        if (storage.permitFileWrite(category, generation, index.path)) {
          await temporary.rename(index.path);
        }
      });
    } on FileSystemException {
      // The complete resource remains cached when its validator cannot be saved.
    } finally {
      try {
        if (await temporary.exists()) await temporary.delete();
      } on FileSystemException {
        // Storage cleanup also recognizes interrupted .tmp files.
      }
    }
  }

  Future<ResourceFileLease> acquire(
    Uri uri, {
    required ResourceFileKind kind,
    Future<void>? cancelled,
  }) async {
    var aborted = false;
    unawaited(
      cancelled?.then((_) {
        aborted = true;
      }),
    );
    if (cancelled != null) await Future<void>.value();
    if (aborted) throw const ResourceCacheCancelled();
    final offline = await OfflineFiles.instance.acquire(uri);
    if (aborted) {
      await offline?.release();
      throw const ResourceCacheCancelled();
    }
    if (offline != null) {
      return ResourceFileLease._(uri, offline.file, null, offline.release);
    }
    if (isAccountResource(uri)) {
      try {
        final lease = await AccountResources.instance.acquire(
          uri,
          cancelled: cancelled,
        );
        return ResourceFileLease._(uri, lease.file, null, lease.release);
      } on AccountResourceCancelled {
        throw const ResourceCacheCancelled();
      }
    }
    if (uri.scheme == 'file') {
      return ResourceFileLease._(uri, File.fromUri(uri), null);
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw UnsupportedError('resource_cache_uri:${uri.scheme}');
    }
    final storage = CacheStorage.instance;
    await storage.initialize();
    final category = kind == ResourceFileKind.media
        ? CacheCategory.media
        : CacheCategory.resources;
    final generation = storage.fileGeneration(category);
    final key = sha256.convert(utf8.encode(uri.toString())).toString();
    final directory = kind == ResourceFileKind.media
        ? await storage.mediaRoot
        : await storage.resourceRoot;
    final file = File(p.join(directory.path, '$generation', '$key.resource'));
    final lease = storage.lease([file.path]);
    final flightKey = '${kind.name}:$generation:$key';
    final download = _downloads.putIfAbsent(flightKey, () {
      final work = _ResourceDownload();
      work.file = _load(uri, file, category, generation, work).whenComplete(() {
        work.done = true;
        if (identical(_downloads[flightKey], work)) {
          _downloads.remove(flightKey);
        }
      });
      return work;
    });
    download.users++;
    try {
      await Future.any<File>([
        download.file,
        if (cancelled != null)
          cancelled.then<File>((_) => throw const ResourceCacheCancelled()),
      ]);
      return ResourceFileLease._(uri, file, lease);
    } catch (_) {
      await lease.release();
      rethrow;
    } finally {
      download.users--;
      if (download.users == 0 && !download.done) {
        if (identical(_downloads[flightKey], download)) {
          _downloads.remove(flightKey);
        }
        if (!download.aborted.isCompleted) download.aborted.complete();
      }
    }
  }

  Future<Uint8List> readBytes(
    Uri uri, {
    required ResourceFileKind kind,
    Future<void>? cancelled,
  }) async {
    var aborted = false;
    unawaited(
      cancelled?.then((_) {
        aborted = true;
      }),
    );
    if (cancelled != null) await Future<void>.value();
    if (aborted) throw const ResourceCacheCancelled();
    final offline = await OfflineFiles.instance.readBytes(uri);
    if (aborted) throw const ResourceCacheCancelled();
    if (offline != null) return offline;
    final lease = await acquire(uri, kind: kind, cancelled: cancelled);
    try {
      return await lease.readBytes();
    } finally {
      await lease.release();
    }
  }

  Future<File> _load(
    Uri uri,
    File file,
    CacheCategory category,
    int generation,
    _ResourceDownload work,
  ) async {
    final storage = CacheStorage.instance;
    if (storage.canRead(file.path) &&
        await file.exists() &&
        await file.length() > 0) {
      try {
        await file.setLastAccessed(DateTime.now());
      } on FileSystemException {
        // A readable cached file remains usable when timestamps are read-only.
      }
      return file;
    }
    final temporary = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.${_temporaryId++}.tmp',
    );
    final family = _family(uri);
    final index = family == null
        ? null
        : File(
            p.join(
              file.parent.path,
              '${sha256.convert(utf8.encode(family))}.family.json',
            ),
          );
    _ResourceValidator? previous;
    try {
      return await storage.protect([file.path, temporary.path], () async {
        if (index != null) previous = await _previous(uri, index);
        for (var attempt = 0; ; attempt++) {
          try {
            return await _download(
              uri,
              file,
              temporary,
              category,
              generation,
              work,
              index,
              previous,
            );
          } on TimeoutException {
            if (attempt >= 2 || work.aborted.isCompleted) rethrow;
          }
        }
      });
    } finally {
      await previous?.lease.release();
      try {
        if (await temporary.exists()) await temporary.delete();
      } on FileSystemException {
        // Storage cleanup also recognizes interrupted .tmp files.
      }
    }
  }

  Future<File> _download(
    Uri uri,
    File file,
    File temporary,
    CacheCategory category,
    int generation,
    _ResourceDownload work,
    File? index,
    _ResourceValidator? previous,
  ) async {
    final storage = CacheStorage.instance;
    final attemptAborted = Completer<void>();
    StreamIterator<List<int>>? body;
    RandomAccessFile? output;
    try {
      if (work.aborted.isCompleted) throw const ResourceCacheCancelled();
      if (!storage.permitFileWrite(category, generation, file.path)) {
        throw const ResourceCacheCancelled();
      }
      final request = http.AbortableRequest(
        'GET',
        uri,
        abortTrigger: Future.any([work.aborted.future, attemptAborted.future]),
      );
      if (previous case final validator?) {
        request.headers[HttpHeaders.ifNoneMatchHeader] = validator.etag;
      }
      final response = await sendFileRequest(request)
          .timeout(_networkIdleTimeout);
      final retained = previous;
      final reuse =
          response.statusCode == HttpStatus.notModified && retained != null;
      if (response.statusCode != HttpStatus.ok && !reuse) {
        await response.stream.listen(null).cancel();
        throw http.ClientException('Resource HTTP ${response.statusCode}', uri);
      }
      var length = 0;
      await file.parent.create(recursive: true);
      if (reuse) {
        await response.stream.timeout(_networkIdleTimeout).drain<void>();
        if (work.aborted.isCompleted ||
            !storage.permitFileWrite(category, generation, file.path)) {
          throw const ResourceCacheCancelled();
        }
        await retained.file.copy(temporary.path);
        length = await temporary.length();
        if (length != retained.bytes) {
          throw http.ClientException('Incomplete cached resource', uri);
        }
      } else {
        body = StreamIterator(response.stream);
        output = await temporary.open(mode: FileMode.write);
        while (await body.moveNext().timeout(_networkIdleTimeout)) {
          final bytes = body.current;
          await output.writeFrom(bytes);
          length += bytes.length;
        }
        await output.flush();
        await body.cancel();
        body = null;
        await output.close();
        output = null;
      }
      final encoding = response.headers['content-encoding'];
      final expected = !reuse && (encoding == null || encoding == 'identity')
          ? response.contentLength
          : null;
      if (length == 0 || (expected != null && length != expected)) {
        throw http.ClientException('Incomplete resource response', uri);
      }
      if (work.aborted.isCompleted ||
          !storage.permitFileWrite(category, generation, file.path)) {
        throw const ResourceCacheCancelled();
      }
      await temporary.rename(file.path);
      if (index != null) {
        await _remember(
          uri,
          file,
          index,
          reuse ? retained.etag : response.headers[HttpHeaders.etagHeader],
          length,
          category,
          generation,
        );
      }
      storage.scheduleTrim();
      return file;
    } on TimeoutException {
      if (!attemptAborted.isCompleted) attemptAborted.complete();
      rethrow;
    } finally {
      await body?.cancel();
      await output?.close();
    }
  }
}
