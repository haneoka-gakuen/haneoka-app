import 'dart:io';

import 'package:flutter/services.dart';

import '../save/game_save.dart';

enum ShizukuStatus { notRunning, needsPermission, unsupported, ready }

/// The phone's own access to the game's folder: Shizuku on any version, or a
/// one-time folder grant on Android 8–12.
class AndroidSaveSource {
  static const _channel = MethodChannel('org.haneoka/saves');

  static Future<ShizukuStatus> shizukuStatus() async =>
      ShizukuStatus.values.byName(
        await _channel.invokeMethod<String>('shizukuStatus') ?? 'notRunning',
      );

  static Future<bool> requestShizuku() async =>
      await _channel.invokeMethod<bool>('shizukuRequest') ?? false;

  static Future<bool> openShizuku() async =>
      await _channel.invokeMethod<bool>('openShizuku') ?? false;

  static Future<bool> canGrantGameFolder() async =>
      await _channel.invokeMethod<bool>('canGrantGameFolder') ?? false;

  /// The granted folder, or null when the user backed out.
  static Future<String?> grantGameFolder(GameRelease release) => _channel
      .invokeMethod<String>('grantGameFolder', {'package': release.packageId});

  static Future<List<String>> grantedFolders() async =>
      (await _channel.invokeListMethod<String>('grantedFolders')) ?? const [];

  static Future<int> readWithShizuku(
    GameRelease release,
    SaveCollector collector,
  ) => _read('shizukuRead', {'package': release.packageId}, collector);

  static Future<int> readFolder(
    String uri,
    SaveCollector collector, {
    GameRelease? release,
  }) => _read('readFolder', {'uri': uri}, collector, release);

  static Future<int> _read(
    String method,
    Map<String, String> arguments,
    SaveCollector collector, [
    GameRelease? fallback,
  ]) async {
    final batch = await _channel.invokeMapMethod<String, Object?>(
      method,
      arguments,
    );
    if (batch == null) return 0;
    var saves = 0;
    try {
      for (final item in batch['files'] as List) {
        final file = item as Map;
        final staged = File(file['path'] as String);
        try {
          final modified = file['modified'] as int?;
          final found = await collector.offerAsync(
            SaveCandidate(
              bytes: await staged.readAsBytes(),
              source: file['source'] as String,
              group: file['group'] as String,
              modifiedAt: modified == null || modified == 0
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(modified),
              release:
                  GameRelease.fromPackage(file['package'] as String? ?? '') ??
                  fallback,
            ),
          );
          if (found) saves++;
        } finally {
          await staged.delete();
        }
      }
      return saves;
    } finally {
      await _channel.invokeMethod<void>('releaseRead', {'id': batch['id']});
    }
  }
}
