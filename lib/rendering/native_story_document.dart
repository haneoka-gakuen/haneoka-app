import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:vega_plugin_haneoka/vega_plugin_haneoka.dart';

import '../core/api.dart';
import '../core/document_cache.dart';
import '../core/account_resource.dart';
import '../core/resource_file_cache.dart';

Future<(Map<String, Object?>, String)> _decodeStoryInput(Uint8List bytes) =>
    Isolate.run(
      () => (
        (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>(),
        sha256.convert(bytes).toString(),
      ),
    );

/// A normal selected episode, pinned before any command or media dispatch.
final class NativeStoryDocument {
  NativeStoryDocument._(
    this.chapter,
    this.assets,
    this.runtime,
    this.runtimeHash,
  );
  final StoryChapterDocument chapter;
  final NativeStoryAssets assets;
  final Map<String, Object?> runtime;
  final String runtimeHash;

  static Future<NativeStoryDocument> load(HaneokaApi api, String id) async {
    await api.release();
    if (api.sourceId == null || api.sourceId!.isEmpty) {
      await api.revalidate();
    }
    final release = await api.release();
    final sourceId = api.sourceId;
    if (release == 'offline' || sourceId == null || sourceId.isEmpty) {
      throw StateError('story_source_identity_unavailable');
    }
    final uri = api
        .asset(
          '/api/v1/servers/${api.server}/stories/'
          '${Uri.encodeComponent(id)}',
        )
        .replace(queryParameters: {'release': release});
    final runtimeUri = api
        .asset('/api/v1/servers/${api.server}/story-runtime')
        .replace(queryParameters: {'release': release});
    Future<(Map<String, Object?>, String)> input(Uri uri) async {
      if (isAccountResource(uri)) {
        return _decodeStoryInput(
          await resourceFileCache.readBytes(
            uri,
            kind: ResourceFileKind.renderResource,
          ),
        );
      }
      return publicDocumentCache.read<(Map<String, Object?>, String)>(
        key: PublicDocumentKey(
          uri: uri,
          server: api.server,
          releaseId: release,
          sourceId: sourceId,
        ),
        decodeVariant: 'json.sha256.v1',
        decode: _decodeStoryInput,
        revalidateAfter: null,
      );
    }

    final (selected, runtimeInput) = await (input(uri), input(runtimeUri)).wait;
    final (entity, entityHash) = selected;
    final source = StorySourceIdentity(
      namespace: api.server,
      revision: release,
      resourceScope: sourceId,
      document: id,
      contentIdentity: entityHash,
    );
    final chapter = HaneokaStoryCatalogDecoder.decode(entity, source);
    final runtime = Map<String, Object?>.unmodifiable(runtimeInput.$1);
    return NativeStoryDocument._(
      chapter,
      NativeStoryAssets(
        chapter.assets,
        api.asset,
        release,
        server: api.server,
        commands: chapter.commands,
      ),
      runtime,
      runtimeInput.$2,
    );
  }
}

/// Resolves exact native cue references through actual catalog rows.
/// Missing resources stay explicit; cue identities never become guessed URLs.
final class NativeStoryAssets {
  NativeStoryAssets(
    Map<String, Object?> assets,
    this.assetUri,
    this.release, {
    required this.server,
    required Iterable<StoryDecodedCommand> commands,
  }) {
    final voiceReferences = {
      for (final command in commands) ...command.voiceRefs,
    };
    for (final record in (assets['sounds'] as List? ?? const []).cast<Map>()) {
      final kind = switch (record['categoryName']) {
        'Bgm' => StoryMediaKind.bgm,
        'Voice' => StoryMediaKind.voice,
        'Se' => StoryMediaKind.sfx,
        _ => null,
      };
      if (kind != null) _insert(kind, record, 'soundId');
      if (kind != StoryMediaKind.voice &&
          voiceReferences.contains(record['resourceRef'])) {
        _insert(StoryMediaKind.voice, record, 'soundId');
      }
    }
    for (final record in (assets['videos'] as List? ?? const []).cast<Map>()) {
      _insert(StoryMediaKind.movie, record, 'videoId');
    }
    for (final record in (assets['stills'] as List? ?? const []).cast<Map>()) {
      final reference = record['assetName'];
      final presentation = record['presentation'];
      if (reference is String && presentation is Map) {
        stills[reference] = Map<String, Object?>.from(presentation);
      }
    }
    for (final record
        in (assets['backgrounds'] as List? ?? const []).cast<Map>()) {
      if (record['stageRef'] is String) {
        backgrounds[record['stageRef'] as String] = Map<String, Object?>.from(
          record,
        );
      }
    }
    for (final record in (assets['frames'] as List? ?? const []).cast<Map>()) {
      if (record['assetName'] is String) {
        frames[record['assetName'] as String] = Map<String, Object?>.from(
          record,
        );
      }
    }
  }
  final Uri Function(String) assetUri;
  final String release, server;
  final _media = <String, Map>{};
  final _ids = <String, String>{};
  final stills = <String, Map<String, Object?>>{};
  final backgrounds = <String, Map<String, Object?>>{};
  final frames = <String, Map<String, Object?>>{};
  Set<Uri>? _mediaUris;

  bool isMediaUri(Uri uri) => (_mediaUris ??= {
    for (final record in _media.values)
      if (record['playableUrl'] case final String path when path.isNotEmpty)
        pinned(path),
  }).contains(uri);

  void _insert(StoryMediaKind kind, Map record, String idField) {
    final reference = record['resourceRef'];
    if (reference is! String || reference.isEmpty) {
      throw FormatException('story_media_catalog_ref:${record[idField]}');
    }
    final key = '${kind.name}:$reference';
    final idKey = '${kind.name}:${record[idField]}';
    if (_ids[idKey] case final String oldReference
        when oldReference != reference) {
      throw FormatException('story_conflicting_cue_id:$idKey');
    }
    final previous = _media[key];
    if (previous != null &&
        !haneokaStoryMediaBindingsEqual(previous, record, idField)) {
      throw FormatException('story_duplicate_cue:$key');
    }
    _media.putIfAbsent(key, () => record);
    _ids[idKey] = reference;
  }

  String referenceFor(StoryMediaKind kind, String actualCueId) {
    final reference = _ids['${kind.name}:$actualCueId'];
    if (reference == null) {
      throw StateError('story_cue_catalog_missing:$actualCueId');
    }
    return reference;
  }

  Map mediaRecord(String reference, StoryMediaKind kind) {
    final record = _media['${kind.name}:$reference'];
    if (record == null || record['missing'] == true) {
      throw StateError('story_actual_cue_missing:${kind.name}:$reference');
    }
    return record;
  }

  Uri resolve(String reference, StoryMediaKind kind) {
    final record = mediaRecord(reference, kind);
    final url = record['playableUrl'];
    if (url is! String || url.isEmpty) {
      throw StateError('story_cue_playable_url_missing:$reference');
    }
    return pinned(url);
  }

  /// The source on this release; another server's files (the shared story UI
  /// frames come from Global) follow that server's own current release.
  Uri pinned(String sourcePath) {
    final uri = assetUri(sourcePath);
    final segments = uri.pathSegments;
    if (segments.length > 1 &&
        const {'runtime', 'assets', 'objects'}.contains(segments[0]) &&
        segments[1] != server) {
      return uri;
    }
    return uri.replace(
      queryParameters: {...uri.queryParameters, 'release': release},
    );
  }
}
