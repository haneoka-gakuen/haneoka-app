import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart';
import 'package:sqlite3/sqlite3.dart';

import '../save/codec.dart';
import '../save/game_save.dart';
import 'plist.dart';

/// A local iPhone or iPad backup made by Finder (macOS), Apple Devices or
/// iTunes (Windows), or `idevicebackup2` (Linux).
class IosBackup {
  IosBackup._(
    this.path,
    this.deviceName,
    this.productType,
    this.date,
    this.encrypted,
    this._manifest,
  );
  final String path;
  final String? deviceName;
  final String? productType;
  final DateTime? date;
  final bool encrypted;
  final Map<String, Object?> _manifest;

  /// Where the system tools keep backups. macOS needs Full Disk Access for
  /// this folder; Linux backups live wherever `idevicebackup2` wrote them.
  static List<String> defaultFolders() {
    final env = Platform.environment;
    if (Platform.isMacOS) {
      return [
        p.join(
          env['HOME'] ?? '',
          'Library',
          'Application Support',
          'MobileSync',
          'Backup',
        ),
      ];
    }
    if (Platform.isWindows) {
      return [
        p.join(env['APPDATA'] ?? '', 'Apple Computer', 'MobileSync', 'Backup'),
        p.join(env['USERPROFILE'] ?? '', 'Apple', 'MobileSync', 'Backup'),
      ];
    }
    return [];
  }

  /// Every backup directly inside [folder], or [folder] itself if it is one.
  static Future<List<IosBackup>> find(String folder) async {
    final self = await open(folder);
    if (self != null) return [self];
    final directory = Directory(folder);
    if (!await directory.exists()) return [];
    final out = <IosBackup>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is Directory) {
        final backup = await open(entity.path);
        if (backup != null) out.add(backup);
      }
    }
    out.sort(
      (a, b) => (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0)),
    );
    return out;
  }

  static Future<IosBackup?> open(String path) async {
    final manifestPlist = File(p.join(path, 'Manifest.plist'));
    if (!await manifestPlist.exists() ||
        !await File(p.join(path, 'Manifest.db')).exists()) {
      return null;
    }
    final manifest =
        parsePlist(await manifestPlist.readAsBytes()) as Map<String, Object?>;
    final infoFile = File(p.join(path, 'Info.plist'));
    final info = await infoFile.exists()
        ? parsePlist(await infoFile.readAsBytes()) as Map<String, Object?>
        : const {};
    final lockdown = manifest['Lockdown'] as Map<String, Object?>? ?? const {};
    return IosBackup._(
      path,
      (info['Device Name'] ?? lockdown['DeviceName']) as String?,
      (info['Product Type'] ?? lockdown['ProductType']) as String?,
      (info['Last Backup Date'] ?? manifest['Date']) as DateTime?,
      manifest['IsEncrypted'] == true,
      manifest,
    );
  }

  /// Offers the game's files in this backup to [collector]. Returns how many
  /// of the game's files the backup holds; zero means the game is not in it.
  /// [password] is the backup's own password, needed only when [encrypted].
  Future<int> scan(SaveCollector collector, {String? password}) async {
    final keys = encrypted
        ? await _unlockBackup(_manifest, password ?? '')
        : null;
    final database = keys == null
        ? File(p.join(path, 'Manifest.db'))
        : await _decryptedManifest(keys);
    final db = sqlite3.open(database.path, mode: OpenMode.readOnly);
    try {
      final domains = {
        for (final release in GameRelease.values)
          'AppDomain-${release.packageId}': release,
      };
      final rows = db.select(
        'SELECT fileID, domain, relativePath, file FROM Files WHERE flags = 1 AND domain IN '
        '(${List.filled(domains.length, '?').join(',')})',
        domains.keys.toList(),
      );
      for (final row in rows) {
        final relative = row['relativePath'] as String;
        if (p.split(relative).any(_skipped.contains)) continue;
        final fileId = row['fileID'] as String;
        final stored = File(p.join(path, fileId.substring(0, 2), fileId));
        if (!await stored.exists()) continue;
        final meta = _FileMeta.read(row['file'] as Uint8List?);
        if (meta.size > SaveCodec.maxFileBytes) continue;
        var bytes = await stored.readAsBytes();
        if (keys != null) {
          if (meta.wrappedKey == null) continue;
          bytes = keys.decryptFile(
            bytes,
            meta.protectionClass,
            meta.wrappedKey!,
            meta.size,
          );
        }
        collector.offer(
          SaveCandidate(
            bytes: bytes,
            source: '${row['domain']}/$relative',
            modifiedAt: meta.modified,
            release: domains[row['domain']],
            group: '${row['domain']}/${p.dirname(relative)}',
          ),
        );
      }
      return rows.length;
    } finally {
      db.close();
      if (keys != null) await database.parent.delete(recursive: true);
    }
  }

  Future<File> _decryptedManifest(_BackupKeys keys) async {
    final manifestKey = _manifest['ManifestKey'] as Uint8List;
    final protectionClass = ByteData.sublistView(
      manifestKey,
      0,
      4,
    ).getUint32(0, Endian.little);
    final key = keys.unwrapForClass(
      protectionClass,
      Uint8List.sublistView(manifestKey, 4),
    );
    final plain = _aesCbcDecrypt(
      key,
      await File(p.join(path, 'Manifest.db')).readAsBytes(),
    );
    final dir = await Directory.systemTemp.createTemp('haneoka-backup-');
    final file = File(p.join(dir.path, 'Manifest.db'));
    await file.writeAsBytes(plain, flush: true);
    return file;
  }

  static const _skipped = {
    'Library',
    'tmp',
    'EncryptedBundles',
    'Addressables',
    'UnityCache',
    'il2cpp',
  };
}

Future<_BackupKeys> _unlockBackup(
  Map<String, Object?> manifest,
  String password,
) => Isolate.run(() => _BackupKeys.unlock(manifest, password));

class BackupPasswordException implements Exception {}

/// The per-file record Manifest.db keeps as an NSKeyedArchiver blob.
class _FileMeta {
  _FileMeta(this.size, this.protectionClass, this.wrappedKey, this.modified);
  final int size;
  final int protectionClass;
  final Uint8List? wrappedKey;
  final DateTime? modified;

  static _FileMeta read(Uint8List? blob) {
    if (blob == null) return _FileMeta(0, 0, null, null);
    final archive = parsePlist(blob) as Map<String, Object?>;
    final objects = archive['\$objects'] as List<Object?>;
    final top = archive['\$top'] as Map<String, Object?>;
    final root =
        objects[(top['root'] as PlistUid).index] as Map<String, Object?>;
    Uint8List? key;
    if (root['EncryptionKey'] case PlistUid ref) {
      final data =
          (objects[ref.index] as Map<String, Object?>)['NS.data'] as Uint8List;
      key = Uint8List.sublistView(data, 4);
    }
    final modified = root['LastModified'];
    return _FileMeta(
      (root['Size'] as int?) ?? 0,
      (root['ProtectionClass'] as int?) ?? 0,
      key,
      modified is int
          ? DateTime.fromMillisecondsSinceEpoch(modified * 1000)
          : null,
    );
  }
}

/// The backup keybag, unlocked with the backup password: class keys that
/// unwrap each file's own key.
class _BackupKeys {
  _BackupKeys(this._classKeys);
  final Map<int, Uint8List> _classKeys;

  static _BackupKeys unlock(Map<String, Object?> manifest, String password) {
    final bag = manifest['BackupKeyBag'] as Uint8List;
    final attrs = <String, Uint8List>{};
    final classes = <Map<String, Uint8List>>[];
    Map<String, Uint8List>? current;
    final view = ByteData.sublistView(bag);
    for (var at = 0; at + 8 <= bag.length;) {
      final tag = String.fromCharCodes(bag.sublist(at, at + 4));
      final length = view.getUint32(at + 4);
      final value = Uint8List.sublistView(bag, at + 8, at + 8 + length);
      at += 8 + length;
      if (tag == 'UUID' && attrs.containsKey('UUID')) {
        if (current != null) classes.add(current);
        current = {'UUID': value};
      } else if (current != null) {
        current[tag] = value;
      } else {
        attrs[tag] = value;
      }
    }
    if (current != null) classes.add(current);
    int number(Uint8List b) => b.fold(0, (v, x) => (v << 8) | x);

    var secret = Uint8List.fromList(utf8.encode(password));
    if (attrs['DPSL'] != null) {
      secret = _pbkdf2(
        Digest('SHA-256'),
        secret,
        attrs['DPSL']!,
        number(attrs['DPIC']!),
      );
    }
    final key = _pbkdf2(
      Digest('SHA-1'),
      secret,
      attrs['SALT']!,
      number(attrs['ITER']!),
    );
    final keys = <int, Uint8List>{};
    for (final entry in classes) {
      final wrapped = entry['WPKY'];
      final cls = entry['CLAS'];
      if (wrapped == null ||
          cls == null ||
          entry['WRAP'] == null ||
          number(entry['WRAP']!) & 2 == 0) {
        continue;
      }
      final unwrapped = _aesUnwrap(key, wrapped);
      if (unwrapped == null) throw BackupPasswordException();
      keys[number(cls)] = unwrapped;
    }
    if (keys.isEmpty) throw BackupPasswordException();
    return _BackupKeys(keys);
  }

  Uint8List unwrapForClass(int protectionClass, Uint8List wrapped) {
    final classKey = _classKeys[protectionClass];
    final key = classKey == null ? null : _aesUnwrap(classKey, wrapped);
    if (key == null) throw BackupPasswordException();
    return key;
  }

  Uint8List decryptFile(
    Uint8List data,
    int protectionClass,
    Uint8List wrapped,
    int size,
  ) {
    final plain = _aesCbcDecrypt(
      unwrapForClass(protectionClass, wrapped),
      data,
    );
    return size > 0 && size <= plain.length
        ? Uint8List.sublistView(plain, 0, size)
        : plain;
  }

  static Uint8List _pbkdf2(
    Digest digest,
    Uint8List secret,
    Uint8List salt,
    int iterations,
  ) {
    final derivator = PBKDF2KeyDerivator(HMac(digest, 64))
      ..init(Pbkdf2Parameters(salt, iterations, 32));
    return derivator.process(secret);
  }
}

/// RFC 3394 AES key unwrap; null when the integrity check fails (wrong password).
Uint8List? _aesUnwrap(Uint8List kek, Uint8List wrapped) {
  final n = wrapped.length ~/ 8 - 1;
  final aes = AESEngine()..init(false, KeyParameter(kek));
  final a = Uint8List.fromList(wrapped.sublist(0, 8));
  final r = [
    for (var i = 0; i < n; i++)
      Uint8List.fromList(wrapped.sublist(8 + i * 8, 16 + i * 8)),
  ];
  final block = Uint8List(16), out = Uint8List(16);
  for (var j = 5; j >= 0; j--) {
    for (var i = n; i >= 1; i--) {
      final t = n * j + i;
      for (var k = 0; k < 8; k++) {
        block[k] = a[k] ^ ((t >> (8 * (7 - k))) & 0xff);
      }
      block.setRange(8, 16, r[i - 1]);
      aes.processBlock(block, 0, out, 0);
      a.setRange(0, 8, out);
      r[i - 1].setRange(0, 8, out, 8);
    }
  }
  if (a.any((b) => b != 0xa6)) return null;
  return Uint8List.fromList([for (final part in r) ...part]);
}

/// AES-256-CBC with a zero IV, as backups use; trailing PKCS#7 padding removed.
Uint8List _aesCbcDecrypt(Uint8List key, Uint8List data) {
  final cipher = CBCBlockCipher(AESEngine())
    ..init(false, ParametersWithIV(KeyParameter(key), Uint8List(16)));
  final out = Uint8List(data.length - data.length % 16);
  for (var offset = 0; offset < out.length; offset += 16) {
    cipher.processBlock(data, offset, out, offset);
  }
  final pad = out.isEmpty ? 0 : out.last;
  if (pad >= 1 &&
      pad <= 16 &&
      out.sublist(out.length - pad).every((b) => b == pad)) {
    return Uint8List.sublistView(out, 0, out.length - pad);
  }
  return out;
}
