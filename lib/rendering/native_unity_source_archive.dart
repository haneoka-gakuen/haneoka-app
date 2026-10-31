import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:vega_plugin_haneoka/render_profile.dart';

import '../core/api.dart';
import '../core/background_work.dart';
import '../core/resource_file_cache.dart';

/// Sources the game stopped shipping, kept from the last client that had them.
const _bundledSources = {
  'Assets/AddressableResources/Common/Prefab/CameraManager.prefab':
      'assets/render/camera-manager',
};

Future<Uint8List> _assetBytes(String path) async =>
    (await rootBundle.load(path)).buffer.asUint8List();

/// A verified actual source archive. Only requested typed records are retained;
/// callers never execute Material or Shader programs from an archive.
final class NativeUnitySourceArchive {
  NativeUnitySourceArchive._(
    this.identity,
    this.sourcePath,
    this.descriptor,
    this.archiveHash,
    this.records,
    this.preparedRecords,
  );
  final StorySourceIdentity identity;
  final String sourcePath, archiveHash;
  final Map descriptor;
  final List<Map> records;
  final Object? preparedRecords;

  static Future<NativeUnitySourceArchive> load({
    required HaneokaApi api,
    required StorySourceIdentity identity,
    required String sourcePath,
    required bool Function() current,
    required bool Function(Map) retain,
    bool decodeOffThread = false,
    Object? Function(List<Map>)? prepareRecords,
    void Function(String phase, int microseconds)? onTiming,
  }) async {
    final timer = Stopwatch()..start();
    if (api.server != identity.server ||
        !sourcePath.startsWith('Assets/') ||
        sourcePath.contains('..')) {
      throw const FormatException('unity_archive_source');
    }
    final descriptorUri = api
        .asset(
          '/api/v1/servers/${identity.server}/sources/'
          '${sourcePath.split('/').map(Uri.encodeComponent).join('/')}',
        )
        .replace(queryParameters: {'release': identity.release});
    Uint8List descriptorBytes;
    Uint8List? bundledArchive;
    try {
      descriptorBytes = await resourceFileCache.readBytes(
        descriptorUri,
        kind: ResourceFileKind.renderResource,
      );
    } on http.ClientException catch (error) {
      final bundled = _bundledSources[sourcePath];
      if (bundled == null || !error.message.endsWith('HTTP 404')) rethrow;
      descriptorBytes = await _assetBytes('$bundled.json');
      bundledArchive = await _assetBytes('$bundled.jsonl.gz');
    }
    if (!current()) throw StateError('unity_archive_cancelled');
    final descriptor = jsonDecode(utf8.decode(descriptorBytes)) as Map;
    onTiming?.call('descriptor', timer.elapsedMicroseconds);
    timer.reset();
    if (descriptor['basePath'] != sourcePath) {
      throw const FormatException('unity_descriptor_source');
    }
    final archive = descriptor['objectArchive'] as Map;
    final path = archive['path'], hash = archive['sha256'];
    if (archive['format'] != 'haneoka-unity-objects-jsonl-v1' ||
        path is! String ||
        !path.startsWith('objects/unity/') ||
        !path.endsWith('.jsonl.gz') ||
        path.contains('..') ||
        hash is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const FormatException('unity_archive_descriptor');
    }
    final uri = api
        .asset(
          '/objects/${identity.server}/${path.substring('objects/'.length)}',
        )
        .replace(queryParameters: {'release': identity.release});
    final bytes =
        bundledArchive ??
        await resourceFileCache.readBytes(
          uri,
          kind: ResourceFileKind.renderResource,
        );
    if (!current()) throw StateError('unity_archive_cancelled');
    if (bytes.length > 32 * 1024 * 1024 ||
        (!decodeOffThread && sha256.convert(bytes).toString() != hash)) {
      throw const FormatException('unity_archive_bytes');
    }
    onTiming?.call(
      decodeOffThread ? 'fetch' : 'fetchVerify',
      timer.elapsedMicroseconds,
    );
    timer.reset();
    final bundles = (descriptor['candidateBundles'] as List)
        .cast<Map>()
        .map((entry) => entry['sha256'])
        .toSet();
    final files = (archive['serializedFiles'] as List).cast<String>().toSet();
    final input = _ArchiveDecodeInput(
      bytes,
      bundles,
      files,
      retain,
      expectedHash: decodeOffThread ? hash : null,
      prepareRecords: prepareRecords,
    );
    final decoded = decodeOffThread
        ? await _decodeArchiveOffMain(input, current)
        : input.decode();
    if (!current()) throw StateError('unity_archive_cancelled');
    onTiming?.call('decodeTotal', timer.elapsedMicroseconds);
    onTiming?.call('hashVerify', decoded.verifyUs);
    onTiming?.call('decompress', decoded.decompressUs);
    onTiming?.call('records', decoded.recordsUs);
    if (prepareRecords != null) {
      onTiming?.call('prepareRecords', decoded.prepareUs);
    }
    return NativeUnitySourceArchive._(
      identity,
      sourcePath,
      Map.unmodifiable(descriptor),
      hash,
      List.unmodifiable(decoded.records),
      decoded.preparedRecords,
    );
  }

  Map requireRecord(String id, String type) => records.singleWhere(
    (row) => row['pathId'] == id && row['type'] == type,
    orElse: () => throw FormatException('cubism_source_record:$type:$id'),
  );
  Map requireScript(String name) => records.singleWhere((row) {
    final data = row['data'];
    if (row['type'] != 'MonoBehaviour' || data is! Map) return false;
    final script = data['m_Script'],
        reference = script is Map ? script['reference'] : null;
    return reference is Map &&
        reference['status'] == 'resolved' &&
        reference['type'] == 'MonoScript' &&
        reference['pathId'] == script!['m_PathID'] &&
        reference['name'] == name;
  }, orElse: () => throw FormatException('cubism_source_script:$name'));
  Map<String, Object?> get proof => {
    'sourcePath': sourcePath,
    'archiveSHA256': archiveHash,
    'contentSHA256': descriptor['contentSha256'],
    'release': identity.release,
    'sourceId': identity.sourceId,
  };
}

Future<_ArchiveDecodeResult> _decodeArchiveOffMain(
  _ArchiveDecodeInput input,
  bool Function() current,
) => runBackgroundWork(
  input.decode,
  checkCurrent: () {
    if (!current()) throw StateError('unity_archive_cancelled');
  },
  debugName: 'unity-source-records',
);

final class _ArchiveDecodeResult {
  const _ArchiveDecodeResult(
    this.records,
    this.verifyUs,
    this.decompressUs,
    this.recordsUs,
    this.preparedRecords,
    this.prepareUs,
  );
  final List<Map> records;
  final int verifyUs, decompressUs, recordsUs;
  final Object? preparedRecords;
  final int prepareUs;
}

final class _ArchiveDecodeInput {
  const _ArchiveDecodeInput(
    this.bytes,
    this.bundles,
    this.files,
    this.retain, {
    this.expectedHash,
    this.prepareRecords,
  });
  final Uint8List bytes;
  final Set<Object?> bundles;
  final Set<String> files;
  final bool Function(Map) retain;
  final String? expectedHash;
  final Object? Function(List<Map>)? prepareRecords;

  _ArchiveDecodeResult decode() {
    final timer = Stopwatch()..start();
    if (expectedHash != null &&
        sha256.convert(bytes).toString() != expectedHash) {
      throw const FormatException('unity_archive_bytes');
    }
    final verifyUs = timer.elapsedMicroseconds;
    timer.reset();
    final decoded = gzip.decode(bytes);
    final decompressUs = timer.elapsedMicroseconds;
    timer.reset();
    if (decoded.length > 128 * 1024 * 1024) {
      throw const FormatException('unity_archive_size');
    }
    final kept = <Map>[];
    var hasHeader = false;
    for (final line in const LineSplitter().convert(utf8.decode(decoded))) {
      if (line.isEmpty) continue;
      final row = decodeUnitySourceArchiveJson(line) as Map;
      if (row['record'] == 'header') {
        if (hasHeader || !bundles.contains(row['bundleSha256'])) {
          throw const FormatException('unity_archive_header');
        }
        hasHeader = true;
      } else {
        if (!hasHeader ||
            row['record'] != 'object' ||
            !files.contains(row['serializedFile'])) {
          throw const FormatException('unity_archive_object');
        }
        if (retain(row)) kept.add(_ids(row) as Map);
      }
    }
    if (!hasHeader || kept.isEmpty) {
      throw const FormatException('unity_archive_empty');
    }
    final recordsUs = timer.elapsedMicroseconds;
    timer.reset();
    final prepared = prepareRecords?.call(kept);
    return _ArchiveDecodeResult(
      kept,
      verifyUs,
      decompressUs,
      recordsUs,
      prepared,
      timer.elapsedMicroseconds,
    );
  }
}

Object? _ids(Object? value) {
  if (value is List) return value.map(_ids).toList();
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key: const {'pathId', 'm_PathID'}.contains(entry.key)
            ? entry.value.toString()
            : _ids(entry.value),
    };
  }
  return value;
}
