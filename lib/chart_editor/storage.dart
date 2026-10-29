import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'editing.dart';
import 'project.dart';

class ChartAudioRef {
  const ChartAudioRef({
    required this.sha,
    required this.name,
    required this.type,
    required this.duration,
  });
  factory ChartAudioRef.fromJson(Object? value) {
    final row = chartMap(value);
    final sha = row['sha256'],
        name = row['name'],
        type = row['type'],
        duration = row['duration'];
    if (sha is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha) ||
        name is! String ||
        name.length > 512 ||
        type is! String ||
        duration is! num ||
        !duration.isFinite ||
        duration <= 0 ||
        duration > 600) {
      throw const FormatException('archive_invalid');
    }
    return ChartAudioRef(
      sha: sha,
      name: name,
      type: type,
      duration: duration.toDouble(),
    );
  }
  final String sha, name, type;
  final double duration;
  ChartMap toJson() => {
    'sha256': sha,
    'name': name,
    'type': type,
    'duration': duration,
  };
}

class StoredChart {
  StoredChart(this.document, this.revision, this.audioFile);
  final ChartMap document, revision;
  final File audioFile;
  ChartProject get project => ChartProject(chartMap(revision['chart']));
  ChartProject get original => ChartProject(chartMap(document['original']));
  ChartAudioRef get audio => ChartAudioRef.fromJson(revision['audio']);
  String get id => document['id'] as String;
  int get head => document['head'] as int;
}

/// Native revisions use the same portable archive envelope as Web CreationStore.
/// SQLite commits the head and its revision together; audio is content addressed.
class ChartCreationStore {
  Directory? _root;
  Database? _database;
  Future<void>? _opening;
  Future<void> open() => _opening ??= () async {
    final support = await getApplicationSupportDirectory();
    final root = _root = await Directory(p.join(support.path, 'chart-creation'))
        .create(recursive: true);
    await Directory(p.join(root.path, 'audio')).create(recursive: true);
    final db = _database = sqlite3.open(p.join(root.path, 'projects.sqlite'));
    db.execute('PRAGMA journal_mode=WAL');
    db.execute(
      'CREATE TABLE IF NOT EXISTS patterns (id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, body TEXT NOT NULL)',
    );
    db.execute('PRAGMA busy_timeout=5000');
    db.execute(
      'CREATE TABLE IF NOT EXISTS documents (id TEXT PRIMARY KEY, head INTEGER NOT NULL, updated_at INTEGER NOT NULL, body TEXT NOT NULL)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS revisions (project_id TEXT NOT NULL, revision INTEGER NOT NULL, body TEXT NOT NULL, PRIMARY KEY(project_id, revision))',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS publications (project_id TEXT NOT NULL, owner TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY(project_id, owner))',
    );
  }();
  Future<List<ChartMap>> patterns() async {
    await open();
    return [
      for (final row in _database!.select(
        'SELECT body FROM patterns ORDER BY updated_at DESC',
      ))
        chartMap(jsonDecode(row['body'] as String)),
    ];
  }

  Future<void> savePattern(ChartMap pattern) async {
    await open();
    _database!.execute(
      'INSERT INTO patterns (id, updated_at, body) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET updated_at=excluded.updated_at, body=excluded.body',
      [
        pattern['id'],
        DateTime.now().millisecondsSinceEpoch,
        jsonEncode(pattern),
      ],
    );
  }

  Future<void> deletePattern(String id) async {
    await open();
    _database!.execute('DELETE FROM patterns WHERE id = ?', [id]);
  }

  File audioFile(ChartAudioRef ref) =>
      File(p.join(_root!.path, 'audio', ref.sha));
  Future<ChartAudioRef> importAudio(
    File file, {
    required String name,
    required String type,
    required double duration,
  }) async {
    await open();
    final size = await file.length();
    if (size < 1 ||
        size > 64 * 1024 * 1024 ||
        duration <= 0 ||
        duration > 600) {
      throw const FormatException('audio_size');
    }
    final hash = (await sha256.bind(file.openRead()).first).toString();
    final ref = ChartAudioRef(
      sha: hash,
      name: name,
      type: type,
      duration: duration,
    );
    final target = audioFile(ref);
    if (!await target.exists()) {
      final temporary = File('${target.path}.${chartId('write')}');
      await file.copy(temporary.path);
      await temporary.rename(target.path);
    }
    return ref;
  }

  Future<List<ChartMap>> list() async {
    await open();
    return [
      for (final row in _database!.select(
        'SELECT body FROM documents ORDER BY updated_at DESC',
      ))
        chartMap(jsonDecode(row['body'] as String)),
    ];
  }

  Future<List<ChartMap>> versions(String id) async {
    await open();
    return [
      for (final row in _database!.select(
        'SELECT body FROM revisions WHERE project_id=? ORDER BY revision DESC',
        [id],
      ))
        chartMap(jsonDecode(row['body'] as String)),
    ];
  }

  Future<StoredChart> read(String id, {int? revision}) async {
    await open();
    final rows = _database!.select('SELECT body FROM documents WHERE id=?', [
      id,
    ]);
    if (rows.isEmpty) throw const FormatException('project_missing');
    final document = chartMap(jsonDecode(rows.single['body'] as String));
    final values = _database!.select(
      'SELECT body FROM revisions WHERE project_id=? AND revision=?',
      [id, revision ?? document['head']],
    );
    if (values.isEmpty) throw const FormatException('revision_missing');
    final value = chartMap(jsonDecode(values.single['body'] as String));
    final chart = ChartProject(chartMap(value['chart']))..requireValid();
    chartCollections(chart);
    final audio = ChartAudioRef.fromJson(value['audio']),
        file = audioFile(audio);
    if (!await file.exists()) throw const FormatException('audio_missing');
    return StoredChart(document, value, file);
  }

  Future<ChartMap> save(
    String id,
    int head,
    ChartProject chart,
    ChartAudioRef audio,
    ChartProject original, {
    ChartMap? source,
    ChartAudioRef? originalAudio,
  }) async {
    chart.requireValid();
    original.requireValid();
    chartCollections(chart);
    chartCollections(original);
    await open();
    final db = _database!, now = DateTime.now().millisecondsSinceEpoch;
    final value = {
      'projectId': id,
      'revision': head + 1,
      'savedAt': now,
      'chart': chart.data,
      'audio': audio.toJson(),
    };
    final encoded = jsonEncode(value);
    if (utf8.encode(encoded).length > 4 * 1024 * 1024) {
      throw const FormatException('archive_size');
    }
    db.execute('BEGIN IMMEDIATE');
    try {
      final old = db.select('SELECT head, body FROM documents WHERE id=?', [
        id,
      ]);
      final previousHead = old.isEmpty ? 0 : old.single['head'];
      if (previousHead != head) throw const FormatException('save_conflict');
      final previous = old.isEmpty
          ? <String, Object?>{}
          : chartMap(jsonDecode(old.single['body'] as String));
      final document = <String, Object?>{
        'id': id,
        'title': chart.meta['title'],
        'head': head + 1,
        'updatedAt': now,
        'original': previous['original'] ?? original.data,
        'originalAudio':
            previous['originalAudio'] ?? (originalAudio ?? audio).toJson(),
        if (source != null || previous['source'] != null)
          'source': source ?? previous['source'],
      };
      db.execute(
        'INSERT INTO revisions(project_id, revision, body) VALUES(?,?,?)',
        [id, head + 1, encoded],
      );
      db.execute(
        'INSERT INTO documents(id,head,updated_at,body) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET head=excluded.head,updated_at=excluded.updated_at,body=excluded.body',
        [id, head + 1, now, jsonEncode(document)],
      );
      db.execute('COMMIT');
      return document;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<ChartMap?> publication(String id, String owner) async {
    await open();
    final rows = _database!.select(
      'SELECT body FROM publications WHERE project_id=? AND owner=?',
      [id, owner],
    );
    return rows.isEmpty
        ? null
        : chartMap(jsonDecode(rows.single['body'] as String));
  }

  Future<void> savePublication(String id, String owner, ChartMap value) async {
    await open();
    _database!.execute(
      'INSERT INTO publications(project_id,owner,body) VALUES(?,?,?) ON CONFLICT(project_id,owner) DO UPDATE SET body=excluded.body',
      [id, owner, jsonEncode(value)],
    );
  }

  Future<File> saveCover(String id, Uint8List bytes, String extension) async {
    await open();
    final folder = await Directory(p.join(_root!.path, 'covers'))
        .create(recursive: true);
    return File(p.join(folder.path, '$id-${chartId('cover')}.$extension'))
        .writeAsBytes(bytes, flush: true);
  }

  Future<void> delete(String id) async {
    await open();
    final db = _database!;
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final table in ['revisions', 'publications']) {
        db.execute('DELETE FROM $table WHERE project_id=?', [id]);
      }
      db.execute('DELETE FROM documents WHERE id=?', [id]);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    // Hashes remain shared by original audio and every retained revision.
    final used = <String>{};
    for (final row in db.select('SELECT body FROM documents')) {
      used.add(
        ChartAudioRef.fromJson(
          chartMap(jsonDecode(row['body'] as String))['originalAudio'],
        ).sha,
      );
    }
    for (final row in db.select('SELECT body FROM revisions')) {
      used.add(
        ChartAudioRef.fromJson(
          chartMap(jsonDecode(row['body'] as String))['audio'],
        ).sha,
      );
    }
    await for (final file in Directory(p.join(_root!.path, 'audio')).list()) {
      if (file is File && !used.contains(p.basename(file.path))) {
        await file.delete();
      }
    }
  }

  Future<Uint8List> exportArchive(
    String id, {
    int? revision,
    ChartMap? publication,
    File? cover,
  }) async {
    final opened = await read(id, revision: revision);
    final document = cloneChartMap(opened.document), value = opened.revision;
    document.addAll({
      'title': opened.project.meta['title'],
      'head': value['revision'],
      'updatedAt': value['savedAt'],
    });
    final envelope = {
      'format': 'haneoka.chart-creation',
      'version': 1,
      'document': document,
      'value': value,
      if (publication != null)
        'publication': portableChartPublication(publication),
      if (cover != null)
        'cover': {
          'name': p.basename(cover.path),
          'type': _imageType(cover.path),
        },
    };
    final manifest = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(envelope),
    );
    if (manifest.length > 4 * 1024 * 1024) {
      throw const FormatException('archive_size');
    }
    final archive = Archive()
      ..addFile(ArchiveFile('project.yaml', manifest.length, manifest));
    final refs = {
      opened.audio.sha: opened.audio,
      ChartAudioRef.fromJson(document['originalAudio'])
          .sha: ChartAudioRef.fromJson(
        document['originalAudio'],
      ),
    };
    for (final ref in refs.values) {
      final bytes = await audioFile(ref).readAsBytes();
      archive.addFile(ArchiveFile('audio/${ref.sha}', bytes.length, bytes));
    }
    if (cover != null) {
      if (await cover.length() > 10 * 1024 * 1024) {
        throw const FormatException('archive_size');
      }
      final bytes = await cover.readAsBytes();
      archive.addFile(ArchiveFile('cover/image', bytes.length, bytes));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  Future<String> importArchive(Uint8List bytes) async {
    if (bytes.length > 142 * 1024 * 1024) {
      throw const FormatException('archive_size');
    }
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    if (archive.files.where((f) => f.isFile).length > 4) {
      throw const FormatException('archive_invalid');
    }
    var total = 0;
    for (final file in archive.files) {
      final limit = file.name == 'project.yaml'
          ? 4 * 1024 * 1024
          : file.name == 'cover/image'
          ? 10 * 1024 * 1024
          : RegExp(r'^audio/[0-9a-f]{64}$').hasMatch(file.name)
          ? 64 * 1024 * 1024
          : 0;
      total += file.size;
      if (!file.isFile ||
          limit == 0 ||
          file.size > limit ||
          total > 142 * 1024 * 1024) {
        throw const FormatException('archive_invalid');
      }
    }
    final manifest = archive.findFile('project.yaml');
    if (manifest == null) throw const FormatException('archive_invalid');
    final envelope = chartMap(jsonDecode(utf8.decode(manifest.content))),
        document = chartMap(envelope['document']),
        value = chartMap(envelope['value']);
    if (envelope['format'] != 'haneoka.chart-creation' ||
        envelope['version'] != 1) {
      throw const FormatException('archive_invalid');
    }
    final original = ChartProject(chartMap(document['original']))
          ..requireValid(),
        chart = ChartProject(chartMap(value['chart']))..requireValid();
    chartCollections(original);
    chartCollections(chart);
    final originalAudio = ChartAudioRef.fromJson(document['originalAudio']),
        audio = ChartAudioRef.fromJson(value['audio']);
    await open();
    for (final ref in [originalAudio, audio]) {
      final entry = archive.findFile('audio/${ref.sha}');
      if (entry == null || entry.size == 0) {
        throw const FormatException('audio_missing');
      }
      final content = entry.content;
      if (sha256.convert(content).toString() != ref.sha) {
        throw const FormatException('audio_hash');
      }
      final target = audioFile(ref);
      if (!await target.exists()) {
        await target.writeAsBytes(content, flush: true);
      }
    }
    final source = document['source'];
    if (source != null &&
        (source is! Map ||
            source['name'] is! String ||
            source['text'] is! String ||
            (source['text'] as String).length > 2 * 1024 * 1024)) {
      throw const FormatException('archive_invalid');
    }
    final id = chartId('project');
    final publication = portableChartPublication(envelope['publication']);
    final cover = archive.findFile('cover/image');
    if (cover != null) {
      final type = chartMap(envelope['cover'])['type'];
      if (!const {'image/png', 'image/jpeg', 'image/webp'}.contains(type)) {
        throw const FormatException('archive_invalid');
      }
      final file = File(
        p.join(
          _root!.path,
          '$id-cover${type == 'image/jpeg'
              ? '.jpg'
              : type == 'image/webp'
              ? '.webp'
              : '.png'}',
        ),
      );
      await file.writeAsBytes(cover.content, flush: true);
      publication['coverFile'] = file.path;
    }
    await save(
      id,
      0,
      chart,
      audio,
      original,
      originalAudio: originalAudio,
      source: source == null ? null : chartMap(source),
    );
    await savePublication(id, 'portable', publication);
    return id;
  }

  Future<File> previewFile(String id, String text) async {
    await open();
    final root = await Directory(p.join(_root!.path, 'preview'))
        .create(recursive: true);
    return File(p.join(root.path, '$id.json')).writeAsString(text, flush: true);
  }

  Future<void> close() async {
    await _opening;
    _database?.close();
    _database = null;
    _opening = null;
  }
}

String _imageType(String name) => switch (p.extension(name).toLowerCase()) {
  '.jpg' || '.jpeg' => 'image/jpeg',
  '.webp' => 'image/webp',
  _ => 'image/png',
};
ChartMap portableChartPublication(Object? input) {
  final value = input is Map ? chartMap(input) : const <String, Object?>{};
  ChartMap? media(Object? raw) {
    if (raw is! Map ||
        raw['kind'] != 'server' ||
        !const {'our-notes', 'bestdori'}.contains(raw['provider']) ||
        raw['server'] is! String ||
        !RegExp(r'^[a-z]{2,4}$').hasMatch(raw['server'] as String) ||
        raw['songId'] is! String ||
        !RegExp(r'^\d+$').hasMatch(raw['songId'] as String) ||
        raw['provider'] == 'our-notes' &&
            (raw['releaseId'] is! String ||
                !RegExp(r'^r-[a-f0-9]{20}$')
                    .hasMatch(raw['releaseId'] as String))) {
      return null;
    }
    return {
      'kind': 'server',
      'provider': raw['provider'],
      'server': raw['server'],
      'songId': raw['songId'],
      if (raw['provider'] == 'our-notes') 'releaseId': raw['releaseId'],
      if (raw['sha256'] is String &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['sha256'] as String))
        'sha256': raw['sha256'],
    };
  }

  final summary = value['summary'] is String ? value['summary'] as String : '';
  return {
    'audio': media(value['audio']),
    'cover': media(value['cover']),
    'summary': summary.substring(0, summary.length.clamp(0, 1000)),
    'visibility': value['visibility'] == 'unlisted' ? 'unlisted' : 'public',
    'remix': value['remix'] != false,
    if (value['audioSha'] is String &&
        RegExp(r'^[a-f0-9]{64}$').hasMatch(value['audioSha'] as String))
      'audioSha': value['audioSha'],
    if (value['upstreamId'] is String &&
        RegExp(r'^[a-f0-9-]{36}$').hasMatch(value['upstreamId'] as String))
      'upstreamId': value['upstreamId'],
  };
}
