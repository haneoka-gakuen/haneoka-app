import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../save/codec.dart';
import '../save/game_save.dart';

class AdbDevice {
  AdbDevice(this.serial, this.state, this.model);
  final String serial;

  /// `device`, `unauthorized` or `offline`.
  final String state;
  final String? model;
  bool get ready => state == 'device';
}

enum AdbScan { found, notInstalled, noSave }

/// Reads saves from an Android phone through the platform tools' `adb`, on
/// Windows, macOS and Linux. Only `pm list packages`, `ls`, `stat` and `cat`
/// run on the phone, and only under the game's own `Android/data` folder.
class AdbSaveSource {
  AdbSaveSource(this.adb);
  final String adb;

  Map<String, String>? get _environment {
    final libraries = p.join(p.dirname(adb), 'lib');
    if (!Platform.isLinux || !Directory(libraries).existsSync()) return null;
    return {
      'LD_LIBRARY_PATH': [
        libraries,
        Platform.environment['LD_LIBRARY_PATH'] ?? '',
      ].where((path) => path.isNotEmpty).join(':'),
    };
  }

  /// `adb` from the platform tools: on PATH, in the Android SDK, or where the
  /// user points. Null when none is found.
  static Future<String?> locate() async {
    final name = Platform.isWindows ? 'adb.exe' : 'adb';
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final candidates = <String>[
      p.join(p.dirname(Platform.resolvedExecutable), 'tools', 'adb', name),
      if (Platform.isMacOS)
        p.join(
          p.dirname(Platform.resolvedExecutable),
          '..',
          'Resources',
          'tools',
          'adb',
          name,
        ),
      for (final dir in (Platform.environment['PATH'] ?? '').split(
        Platform.isWindows ? ';' : ':',
      ))
        if (dir.isNotEmpty) p.join(dir, name),
      for (final sdk in [
        Platform.environment['ANDROID_HOME'],
        Platform.environment['ANDROID_SDK_ROOT'],
      ])
        if (sdk != null) p.join(sdk, 'platform-tools', name),
      if (Platform.isMacOS) ...[
        p.join(home, 'Library', 'Android', 'sdk', 'platform-tools', name),
        '/opt/homebrew/bin/adb',
        '/usr/local/bin/adb',
      ],
      if (Platform.isWindows)
        p.join(
          Platform.environment['LOCALAPPDATA'] ?? '',
          'Android',
          'Sdk',
          'platform-tools',
          name,
        ),
      if (Platform.isLinux)
        p.join(home, 'Android', 'Sdk', 'platform-tools', name),
    ];
    for (final candidate in candidates) {
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  Future<List<AdbDevice>> devices() async {
    final result = await _run(['devices', '-l']);
    if (result.exitCode != 0) throw AdbException('adb devices failed');
    return [
      for (final line in LineSplitter.split(result.stdout as String).skip(1))
        if (RegExp(r'^(\S+)\s+(\S+)(.*)$').firstMatch(line) case final match?)
          AdbDevice(
            match[1]!,
            match[2]!,
            RegExp(r'model:(\S+)').firstMatch(match[3]!)?[1],
          ),
    ];
  }

  /// Wireless debugging on Android 11+: pair once with the code the phone shows.
  Future<bool> pair(String hostPort, String code) async {
    final result = await _run(['pair', hostPort, code]);
    return result.exitCode == 0 &&
        (result.stdout as String).contains('Successfully');
  }

  Future<bool> connect(String hostPort) async {
    final result = await _run(['connect', hostPort]);
    return result.exitCode == 0 &&
        (result.stdout as String).contains('connected');
  }

  Future<List<GameRelease>> installed(String serial) async {
    final out = await _shell(serial, 'pm list packages');
    final packages = LineSplitter.split(out)
        .map((line) => line.replaceFirst('package:', '').trim())
        .toSet();
    return [
      for (final release in GameRelease.values)
        if (packages.contains(release.packageId)) release,
    ];
  }

  /// Offers every small file in the release's account directories.
  Future<AdbScan> scan(
    String serial,
    GameRelease release,
    SaveCollector collector, {
    void Function(String)? progress,
  }) async {
    final root = '/sdcard/Android/data/${release.packageId}/files';
    final top = await _shell(
      serial,
      'ls -1p ${_quote(root)}',
      allowFailure: true,
    );
    if (top.isEmpty) return AdbScan.notInstalled;
    final dirs = [
      for (final line in LineSplitter.split(top))
        if (line.endsWith('/') &&
            RegExp(r'^[0-9a-fA-F]{16,128}/$').hasMatch(line))
          line.substring(0, line.length - 1),
    ];
    var found = false;
    for (final dir in dirs) {
      final path = '$root/$dir';
      final listing = await _shell(
        serial,
        'ls -1p ${_quote(path)}',
        allowFailure: true,
      );
      for (final name in LineSplitter.split(listing)) {
        if (name.isEmpty || name.endsWith('/')) continue;
        final file = '$path/$name';
        final stat = (await _shell(
          serial,
          'stat -c "%s %Y" ${_quote(file)}',
          allowFailure: true,
        )).trim().split(' ');
        final size = int.tryParse(stat.first) ?? 0;
        if (size == 0 || size > SaveCodec.maxFileBytes) continue;
        progress?.call('${dir.substring(0, 8)}…/$name');
        final bytes = await _cat(serial, file);
        final seconds = stat.length > 1 ? int.tryParse(stat[1]) : null;
        found |= await collector.offerAsync(
          SaveCandidate(
            bytes: bytes,
            source: '${release.packageId}/$dir/$name',
            modifiedAt: seconds == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
            release: release,
            group: '${release.packageId}/$dir',
          ),
        );
      }
    }
    return found ? AdbScan.found : AdbScan.noSave;
  }

  Future<String> _shell(
    String serial,
    String command, {
    bool allowFailure = false,
  }) async {
    final result = await _run(['-s', serial, 'shell', command]);
    if (result.exitCode != 0 &&
        '${result.stderr}'.toLowerCase().contains('permission denied')) {
      throw AdbException(
        'game folder access denied; use Shizuku or import an exported folder',
      );
    }
    if (result.exitCode != 0 && !allowFailure) {
      throw AdbException(command.split(' ').first);
    }
    return result.exitCode == 0 ? result.stdout as String : '';
  }

  Future<Uint8List> _cat(String serial, String file) async {
    final process = await Process.start(adb, [
      '-s',
      serial,
      'exec-out',
      'cat ${_quote(file)}',
    ], environment: _environment);
    final builder = BytesBuilder(copy: false);
    final errors = process.stderr.drain<void>().catchError((Object _) {});
    final timer = Timer(const Duration(seconds: 30), () => process.kill());
    try {
      await for (final chunk in process.stdout) {
        builder.add(chunk);
        if (builder.length > SaveCodec.maxFileBytes) {
          process.kill();
          throw AdbException('save file exceeds the size limit');
        }
      }
      final status = await process.exitCode;
      await errors;
      if (status != 0) throw AdbException('read save');
      return builder.takeBytes();
    } finally {
      timer.cancel();
    }
  }

  Future<ProcessResult> _run(List<String> arguments) async {
    final process = await Process.start(
      adb,
      arguments,
      environment: _environment,
    );
    final output = const Utf8Decoder(allowMalformed: true)
        .bind(process.stdout)
        .join();
    final errors = const Utf8Decoder(allowMalformed: true)
        .bind(process.stderr)
        .join();
    try {
      final results = await Future.wait<Object>([
        process.exitCode,
        output,
        errors,
      ]).timeout(const Duration(seconds: 30));
      return ProcessResult(
        process.pid,
        results[0] as int,
        results[1] as String,
        results[2] as String,
      );
    } on TimeoutException {
      process.kill();
      throw AdbException('connection timed out');
    }
  }

  /// Single-quoted for the phone's shell; names come from the game's folder.
  static String _quote(String path) => "'${path.replaceAll("'", r"'\''")}'";
}

class AdbException implements Exception {
  AdbException(this.step);
  final String step;
  @override
  String toString() => 'adb: $step';
}
