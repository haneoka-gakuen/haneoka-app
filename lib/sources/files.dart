import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../save/codec.dart';
import '../save/game_save.dart';
import 'plist.dart';

/// The game's asset caches sit next to the account directories and hold
/// gigabytes of bundles and no saves; a folder walk never enters them.
const skippedDirectories = {
  'EncryptedBundles',
  'Addressables',
  'Master',
  'RemoteCatalog',
  'il2cpp',
  'Unity',
  'UnityCache',
  'cache',
  'tmp',
  'com.unity3d.player',
};

/// Files, folders and ZIP archives the user picked: a copied account folder,
/// single save files, or an archive such as a desktop tool's account package.
class FileSaveSource {
  FileSaveSource(this.collector, {this.release});
  final SaveCollector collector;

  /// The release the user named; a picked file does not say which it came from.
  final GameRelease? release;
  static const _maxDepth = 6;

  Future<void> addPath(String path) async {
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.directory) {
      await _walk(Directory(path), 0);
    } else if (type == FileSystemEntityType.file) {
      await _file(File(path));
    }
  }

  /// A path under the game's own data folder names its package.
  static GameRelease? pathRelease(String path) {
    for (final release in GameRelease.values) {
      if (RegExp('(^|[\\\\/])${RegExp.escape(release.packageId)}([\\\\/]|\$)')
          .hasMatch(path)) {
        return release;
      }
    }
    return null;
  }

  void addBytes(Uint8List bytes, String name, {DateTime? modifiedAt}) {
    if (_isZip(bytes)) {
      _zip(bytes, name);
    } else {
      _offer(
        SaveCandidate(
          bytes: bytes,
          source: name,
          modifiedAt: modifiedAt,
          release: release ?? pathRelease(name),
          group: p.dirname(name),
        ),
      );
    }
  }

  Future<void> _walk(Directory directory, int depth) async {
    if (depth > _maxDepth) return;
    await for (final entity in directory.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        if (!skippedDirectories.contains(name)) await _walk(entity, depth + 1);
      } else if (entity is File) {
        await _file(entity);
      }
    }
  }

  Future<void> _file(File file) async {
    final stat = await file.stat();
    if (stat.size == 0) return;
    final handle = await file.open();
    final Uint8List header;
    try {
      header = await handle.read(4);
    } finally {
      await handle.close();
    }
    if (_isZip(header)) {
      final stream = InputFileStream(file.path);
      try {
        _archive(ZipDecoder().decodeStream(stream), file.path);
      } finally {
        await stream.close();
      }
      return;
    }
    if (stat.size > SaveCodec.maxFileBytes) return;
    _offer(
      SaveCandidate(
        bytes: await file.readAsBytes(),
        source: file.path,
        modifiedAt: stat.modified,
        release: release ?? pathRelease(file.path),
        group: p.dirname(file.path),
      ),
    );
  }

  void _zip(Uint8List bytes, String name) =>
      _archive(ZipDecoder().decodeBytes(bytes), name);

  void _archive(Archive archive, String name) {
    final release = _appRelease(archive) ?? this.release ?? pathRelease(name);
    for (final entry in archive.files) {
      if (!entry.isFile ||
          entry.size == 0 ||
          entry.size > SaveCodec.maxFileBytes) {
        continue;
      }
      if (p.split(entry.name).any(skippedDirectories.contains)) continue;
      final dos = entry.lastModDateTime;
      final modified = DateTime(
        dos.year,
        dos.month,
        dos.day,
        dos.hour,
        dos.minute,
        dos.second,
      );
      _offer(
        SaveCandidate(
          bytes: entry.content,
          source: '$name!${entry.name}',
          modifiedAt: modified,
          release: release ?? pathRelease(entry.name),
          group: '$name!${p.dirname(entry.name)}',
        ),
      );
      entry.clear();
    }
  }

  void _offer(SaveCandidate candidate) {
    if (collector.offer(candidate)) return;
    if (candidate.bytes.length > SaveCodec.maxFileBytes) return;
    Object? document;
    try {
      document = jsonDecode(utf8.decode(candidate.bytes));
    } on FormatException {
      return;
    }
    if (document is! Map<String, Object?> ||
        document['schema'] != 'haneoka-game-save-v1') {
      return;
    }
    final player = document['player'];
    if (player is! Map<String, Object?>) return;
    final metadata = SaveCandidate(
      bytes: candidate.bytes,
      source: candidate.source,
      group: candidate.group,
      release:
          GameRelease.fromPackage('${document['release']}') ??
          candidate.release,
      modifiedAt:
          DateTime.tryParse('${document['savedAt']}') ?? candidate.modifiedAt,
    );
    collector.offerDocument({
      if (document['settings'] case final Map<String, Object?> settings)
        ...settings,
      '_player': player,
    }, metadata);
    for (final key in ['persist', 'permanent']) {
      if (document[key] case final Map<String, Object?> data) {
        collector.offerDocument(data, metadata);
      }
    }
  }

  /// An app-container export (iMazing's `.imazingapp`) names its app in
  /// `iTunesMetadata.plist`.
  static GameRelease? _appRelease(Archive archive) {
    final metadata = archive.files
        .where((file) => p.posix.basename(file.name) == 'iTunesMetadata.plist')
        .firstOrNull;
    if (metadata == null || metadata.size > SaveCodec.maxFileBytes) return null;
    try {
      final plist = parsePlist(metadata.content);
      return plist is Map
          ? GameRelease.fromPackage('${plist['softwareVersionBundleId']}')
          : null;
    } on FormatException {
      return null;
    }
  }

  static bool _isZip(Uint8List bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4b &&
      bytes[2] == 3 &&
      bytes[3] == 4;
}
