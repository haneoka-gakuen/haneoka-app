import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net.dart';

enum CacheCategory { data, media, resources, images, temporary, all }

class StorageUsage {
  const StorageUsage(
    this.data,
    this.images,
    this.accounts,
    this.other,
    this.temporary,
    this.memory, {
    this.media = 0,
    this.resources = 0,
  });
  final int data, images, accounts, other, temporary, memory, media, resources;
  int get cache => data + images + media + resources;
  int get total => cache + accounts + other + temporary;
}

final class StorageLease {
  StorageLease._(this._release);
  final Future<void> Function() _release;
  Future<void>? _released;
  Future<void> release() => _released ??= _release();
}

final class OwnedTemporaryDirectory {
  OwnedTemporaryDirectory._(this.directory, this._lease);
  final Directory directory;
  final StorageLease _lease;
  Future<void>? _disposing;

  Future<void> dispose() => _disposing ??= () async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException {
      if (await directory.exists()) rethrow;
    } finally {
      await _lease.release();
    }
  }();
}

class _CacheFile {
  const _CacheFile(this.file, this.bytes, this.touched, [this.imageKey]);
  final File file;
  final int bytes;
  final DateTime touched;
  final String? imageKey;
}

/// Own app caches only. Imported accounts, preferences and secure credentials
/// are measured separately and are never included in cache eviction.
class CacheStorage extends ChangeNotifier {
  CacheStorage._();
  static final instance = CacheStorage._();
  int generation = 0;
  int mediaGeneration = 0;
  int resourceGeneration = 0;
  int limitMb = 0;
  bool automatic = true;
  bool busy = false;
  int activeImports = 0;
  void beginImport() {
    activeImports++;
    notifyListeners();
  }

  void endImport() {
    activeImports = (activeImports - 1).clamp(0, 1 << 30);
    notifyListeners();
  }

  final _active = <String, int>{};
  final _deleteWhenIdle = <String>{};
  Future<void>? _initialized;
  Future<void> _operations = Future.value();
  Timer? _scheduled;
  DateTime? _lastTrim;

  Future<void> initialize() => _initialized ??= _initialize().catchError((
    Object error,
    StackTrace trace,
  ) {
    _initialized = null;
    Error.throwWithStackTrace(error, trace);
  });
  Future<void> _initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt('storage.limitMb');
    limitMb = saved == null || saved == 0
        ? 0
        : const {1024, 2048, 4096, 8192, 16384}.contains(saved)
        ? saved
        : 1024;
    automatic = prefs.getBool('storage.automatic') ?? true;
    mediaGeneration = prefs.getInt('storage.mediaGeneration') ?? 0;
    resourceGeneration = prefs.getInt('storage.resourceGeneration') ?? 0;
    PaintingBinding.instance.imageCache.maximumSizeBytes = 64 << 20;
  }

  Future<void> configure({int? limit, bool? auto}) async {
    await initialize();
    final prefs = await SharedPreferences.getInstance();
    if (limit != null) {
      if (!const {0, 1024, 2048, 4096, 8192, 16384}.contains(limit)) return;
      limitMb = limit;
      await prefs.setInt('storage.limitMb', limit);
    }
    if (auto != null) {
      automatic = auto;
      await prefs.setBool('storage.automatic', auto);
    }
    notifyListeners();
    if (automatic) await trim();
  }

  StorageLease lease(Iterable<String> paths) {
    final files = paths.toSet();
    for (final path in files) {
      _active.update(path, (count) => count + 1, ifAbsent: () => 1);
    }
    return StorageLease._(() async {
      for (final path in files) {
        final count = (_active[path] ?? 1) - 1;
        if (count > 0) {
          _active[path] = count;
          continue;
        }
        _active.remove(path);
        if (_deleteWhenIdle.remove(path)) await _delete(File(path));
      }
    });
  }

  Future<T> protect<T>(
    Iterable<String> paths,
    Future<T> Function() action,
  ) async {
    final held = lease(paths);
    try {
      return await action();
    } finally {
      await held.release();
    }
  }

  bool canRead(String path) => !_deleteWhenIdle.contains(path);

  Future<void> retire(File file) async {
    if ((_active[file.path] ?? 0) > 0) {
      _deleteWhenIdle.add(file.path);
    } else {
      await _delete(file);
    }
  }

  bool permitWrite(int requestGeneration, String path) {
    if (requestGeneration != generation) return false;
    _deleteWhenIdle.remove(path);
    return true;
  }

  int fileGeneration(CacheCategory category) => switch (category) {
    CacheCategory.media => mediaGeneration,
    CacheCategory.resources => resourceGeneration,
    _ => throw ArgumentError.value(category),
  };

  bool permitFileWrite(
    CacheCategory category,
    int requestGeneration,
    String path,
  ) {
    if (requestGeneration != fileGeneration(category)) return false;
    _deleteWhenIdle.remove(path);
    return true;
  }

  void scheduleTrim() {
    if (busy ||
        _scheduled != null ||
        (_lastTrim != null &&
            DateTime.now().difference(_lastTrim!) <
                const Duration(seconds: 30))) {
      return;
    }
    _scheduled = Timer(const Duration(seconds: 5), () {
      _scheduled = null;
      unawaited(trim().catchError((Object _) {}));
    });
  }

  Future<T> _exclusive<T>(Future<T> Function() operation) {
    final result = _operations.then((_) async {
      await initialize();
      busy = true;
      notifyListeners();
      try {
        return await operation();
      } finally {
        busy = false;
        notifyListeners();
      }
    });
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<Directory> get temporaryRoot async {
    final cache = (await getApplicationCacheDirectory()).absolute.path;
    final owner = sha256
        .convert(utf8.encode(cache))
        .toString()
        .substring(0, 12);
    return Directory(
      p.join((await getTemporaryDirectory()).path, 'haneoka-$owner'),
    );
  }

  Future<OwnedTemporaryDirectory> createTemporaryDirectory(
    String prefix,
  ) async {
    final root = await temporaryRoot;
    await root.create(recursive: true);
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FileSystemException(
        'Temporary cache root is not a directory',
      );
    }
    final directory = await root.createTemp(prefix);
    return OwnedTemporaryDirectory._(directory, lease([directory.path]));
  }

  Future<Directory> get _dataRoot async =>
      Directory(p.join((await getApplicationCacheDirectory()).path, 'api'));
  Future<Directory> get _imagesRoot async => Directory(
    p.join((await getTemporaryDirectory()).path, 'haneoka-artwork'),
  );

  Future<Directory> get mediaRoot async => Directory(
    p.join((await getApplicationCacheDirectory()).path, 'media', 'v1'),
  );

  Future<Directory> get resourceRoot async => Directory(
    p.join((await getApplicationCacheDirectory()).path, 'resources', 'v1'),
  );

  Future<List<File>> _files(
    Directory root, [
    Set<String> excluded = const {},
  ]) async {
    final result = <File>[];
    if (excluded.contains(root.path) ||
        await FileSystemEntity.type(root.path, followLinks: false) !=
            FileSystemEntityType.directory) {
      return result;
    }
    await for (final entry in root.list(followLinks: false)) {
      if (excluded.contains(entry.path)) continue;
      if (entry is File) result.add(entry);
      if (entry is Directory) result.addAll(await _files(entry, excluded));
    }
    return result;
  }

  Future<int> _size(Directory root, [Set<String> excluded = const {}]) async {
    var total = 0;
    for (final file in await _files(root, excluded)) {
      try {
        total += await file.length();
      } on FileSystemException {
        continue;
      }
    }
    return total;
  }

  Future<StorageUsage> usage() async {
    await initialize();
    final data = await _dataRoot, images = await _imagesRoot;
    final media = await mediaRoot, resources = await resourceRoot;
    final support = await getApplicationSupportDirectory();
    final accounts = Directory(p.join(support.path, 'accounts'));
    final roots = {
      support.path,
      (await temporaryRoot).path,
      (await getApplicationCacheDirectory()).path,
    }.toList();
    final distinct = roots.where(
      (root) => !roots.any((other) => other != root && p.isWithin(other, root)),
    );
    var other = 0;
    for (final root in distinct) {
      other += await _size(Directory(root), {
        data.path,
        images.path,
        media.path,
        resources.path,
        accounts.path,
      });
    }
    final temporary = await _size(await temporaryRoot, {
      data.path,
      images.path,
      media.path,
      resources.path,
      accounts.path,
    });
    return StorageUsage(
      await _size(data),
      await _size(images),
      await _size(accounts),
      (other - temporary).clamp(0, other),
      temporary,
      PaintingBinding.instance.imageCache.currentSizeBytes,
      media: await _size(media),
      resources: await _size(resources),
    );
  }

  Future<void> _delete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      /* A currently locked file can be retried later. */
    }
  }

  Future<int> clear(CacheCategory category) => _exclusive(() async {
    final before = await usage();
    if (const {CacheCategory.temporary, CacheCategory.all}.contains(category) &&
        activeImports > 0) {
      throw StateError(
        'An import is using temporary files. Finish it before clearing them.',
      );
    }
    if (const {CacheCategory.data, CacheCategory.all}.contains(category)) {
      generation++;
      for (final file in await _files(await _dataRoot)) {
        if ((_active[file.path] ?? 0) > 0) {
          _deleteWhenIdle.add(file.path);
        } else {
          await _delete(file);
        }
      }
    }
    if (const {CacheCategory.media, CacheCategory.all}.contains(category)) {
      mediaGeneration++;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('storage.mediaGeneration', mediaGeneration);
      for (final file in await _files(await mediaRoot)) {
        if ((_active[file.path] ?? 0) > 0) {
          _deleteWhenIdle.add(file.path);
        } else {
          await _delete(file);
        }
      }
    }
    if (const {CacheCategory.resources, CacheCategory.all}.contains(category)) {
      resourceGeneration++;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('storage.resourceGeneration', resourceGeneration);
      for (final file in await _files(await resourceRoot)) {
        if ((_active[file.path] ?? 0) > 0) {
          _deleteWhenIdle.add(file.path);
        } else {
          await _delete(file);
        }
      }
    }
    if (const {CacheCategory.images, CacheCategory.all}.contains(category)) {
      await artworkCache.emptyCache();
      for (final file in await _files(await _imagesRoot)) {
        final stat = await file.stat();
        if (DateTime.now().difference(stat.modified) >
            const Duration(minutes: 1)) {
          await _delete(file);
        }
      }
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    }
    if (const {CacheCategory.temporary, CacheCategory.all}.contains(category)) {
      final data = await _dataRoot, images = await _imagesRoot;
      final media = await mediaRoot, resources = await resourceRoot;
      for (final file in await _files(await temporaryRoot, {
        ..._active.keys,
        data.path,
        images.path,
        media.path,
        resources.path,
      })) {
        if ((_active[file.path] ?? 0) == 0) await _delete(file);
      }
    }
    final after = await usage();
    return (before.total - after.total).clamp(0, before.total);
  });

  Future<void> trim() => _exclusive(() async {
    _lastTrim = DateTime.now();
    if (!automatic || limitMb == 0) return;
    final files = <_CacheFile>[];
    for (final root in [await _dataRoot, await mediaRoot, await resourceRoot]) {
      for (final file in await _files(root)) {
        try {
          final stat = await file.stat();
          files.add(_CacheFile(file, stat.size, stat.accessed));
        } on FileSystemException {
          continue;
        }
      }
    }
    await artworkCache.config.repo.open();
    final images = await _imagesRoot;
    final registered = <String>{};
    for (final object in await artworkCache.config.repo.getAllObjects()) {
      final file = File(p.join(images.path, object.relativePath));
      registered.add(file.path);
      try {
        if (await file.exists()) {
          files.add(
            _CacheFile(
              file,
              await file.length(),
              object.touched ?? DateTime.fromMillisecondsSinceEpoch(0),
              object.key,
            ),
          );
        }
      } on FileSystemException {
        continue;
      }
    }
    for (final file in await _files(images)) {
      if (registered.contains(file.path)) continue;
      try {
        final stat = await file.stat();
        if (DateTime.now().difference(stat.modified) >
            const Duration(minutes: 5)) {
          files.add(_CacheFile(file, stat.size, stat.accessed));
        }
      } on FileSystemException {
        continue;
      }
    }
    var total = files.fold<int>(0, (sum, file) => sum + file.bytes);
    final budget = limitMb << 20;
    if (total <= budget) return;
    files.sort((a, b) => a.touched.compareTo(b.touched));
    for (final entry in files) {
      if (total <= budget * .85) break;
      if ((_active[entry.file.path] ?? 0) > 0 ||
          entry.file.path.endsWith('.tmp')) {
        continue;
      }
      if (entry.imageKey case final key?) {
        await artworkCache.removeFile(key);
      } else {
        await _delete(entry.file);
      }
      if (!await entry.file.exists()) total -= entry.bytes;
    }
  });
}
