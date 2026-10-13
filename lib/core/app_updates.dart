import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net.dart';

const appReleasesUrl = 'https://github.com/haneoka-gakuen/haneoka-app/releases';

class AppRelease {
  const AppRelease(
    this.version,
    this.notes,
    this.url,
    this.download, {
    this.buildNumber,
  });
  final String version;
  final String notes;
  final Uri url;
  final Uri? download;
  final int? buildNumber;
  String get identity =>
      buildNumber == null ? version : '$version+$buildNumber';
}

/// Checks published stable releases, sharing a request across startup and Settings.
class AppUpdates extends ChangeNotifier {
  AppUpdates._();
  static final instance = AppUpdates._();
  bool checking = false;
  bool automatic = true;
  bool checked = false;
  String? currentVersion;
  AppRelease? available;
  Object? error;
  Future<void>? _pending;

  Future<void> setAutomatic(bool value) async {
    automatic = value;
    await (await SharedPreferences.getInstance()).setBool(
      'updates.automatic',
      value,
    );
    notifyListeners();
  }

  Future<void> check({bool manual = false}) =>
      _pending ??= _check(manual).whenComplete(() => _pending = null);

  Future<void> _check(bool manual) async {
    final prefs = await SharedPreferences.getInstance();
    automatic = prefs.getBool('updates.automatic') ?? true;
    final last = prefs.getInt('updates.lastCheck') ?? 0;
    final attempt = prefs.getInt('updates.lastAttempt') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!manual &&
        (!automatic ||
            now - attempt < const Duration(hours: 1).inMilliseconds ||
            now - last < const Duration(hours: 24).inMilliseconds)) {
      notifyListeners();
      return;
    }
    await prefs.setInt('updates.lastAttempt', now);
    checking = true;
    error = null;
    notifyListeners();
    try {
      final package = await PackageInfo.fromPlatform();
      currentVersion = package.version;
      final response = await netClient
          .get(
            Uri.parse(
              'https://api.github.com/repos/haneoka-gakuen/haneoka-app/releases/latest',
            ),
            headers: {
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2026-03-10',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 404) {
        available = null;
      } else {
        if (response.statusCode != 200) {
          throw HttpException('HTTP ${response.statusCode}');
        }
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final version = '${data['tag_name'] ?? ''}'.replaceFirst(
          RegExp(r'^v'),
          '',
        );
        final url = _releaseLink(data['html_url']);
        int? buildNumber;
        var newer = _newer(version, package.version);
        if (!newer &&
            version == package.version &&
            data['draft'] == false &&
            data['prerelease'] == false &&
            url != null) {
          final metadata = (data['assets'] as List? ?? const [])
              .whereType<Map>()
              .where(
                (asset) =>
                    asset['name'] == 'release-version.json' &&
                    asset['state'] == 'uploaded',
              )
              .firstOrNull;
          final metadataUrl = _releaseLink(metadata?['browser_download_url']);
          if (metadataUrl != null) {
            final response = await netClient
                .get(metadataUrl)
                .timeout(const Duration(seconds: 15));
            if (response.statusCode == 200) {
              final metadata = jsonDecode(response.body);
              if (metadata is Map && metadata['version'] == version) {
                buildNumber = int.tryParse('${metadata['buildNumber']}');
                var installedBuild = int.tryParse(package.buildNumber) ?? 0;
                // Flutter's split APKs add 1000 * ABI_VERSION to versionCode.
                if (Platform.isAndroid && installedBuild >= 1000) {
                  installedBuild %= 1000;
                }
                newer = (buildNumber ?? 0) > installedBuild;
              }
            }
          }
        }
        if (data['draft'] != false ||
            data['prerelease'] != false ||
            url == null ||
            !newer) {
          available = null;
        } else {
          final arch = Platform.version.toLowerCase().contains('arm64')
              ? 'arm64'
              : 'x64';
          final assetNames = switch (Platform.operatingSystem) {
            'android' => ['haneoka-android.apk'],
            'linux' => [
              'haneoka-linux-$arch.AppImage',
              'haneoka-linux-$arch.tar.gz',
            ],
            'windows' => [
              'haneoka-windows-$arch-setup.exe',
              'haneoka-windows-$arch.msi',
              'haneoka-windows-$arch.zip',
            ],
            'macos' => [
              'haneoka-macos-$arch.dmg',
              'haneoka-macos-$arch.pkg',
              'haneoka-macos-$arch.zip',
              'haneoka-macos.dmg',
              'haneoka-macos.pkg',
              'haneoka-macos.zip',
            ],
            'ios' => ['haneoka-ios-unsigned.ipa'],
            _ => <String>[],
          };
          Uri? download;
          final assets = (data['assets'] as List? ?? const []).whereType<Map>();
          for (final name in assetNames) {
            for (final asset in assets) {
              final versioned = name.replaceFirst(
                'haneoka-',
                'haneoka-$version-',
              );
              if ((asset['name'] == versioned || asset['name'] == name) &&
                  asset['state'] == 'uploaded') {
                download = _releaseLink(asset['browser_download_url']);
                if (download != null) break;
              }
            }
            if (download != null) break;
          }
          available = AppRelease(
            version,
            '${data['body'] ?? ''}',
            url,
            download,
            buildNumber: buildNumber,
          );
        }
      }
      checked = true;
      await prefs.setInt(
        'updates.lastCheck',
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      error = e;
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  Future<bool> shouldNotify() async {
    if (available == null) return false;
    return (await SharedPreferences.getInstance()).getString(
          'updates.dismissed',
        ) !=
        available!.identity;
  }

  Future<void> dismiss() async {
    if (available != null) {
      await (await SharedPreferences.getInstance()).setString(
        'updates.dismissed',
        available!.identity,
      );
    }
  }

  static Uri? _releaseLink(Object? value) {
    final uri = value is String ? Uri.tryParse(value) : null;
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host == 'github.com' &&
            uri.path.startsWith('/haneoka-gakuen/haneoka-app/releases/')
        ? uri
        : null;
  }

  static bool _newer(String candidate, String current) {
    final stable = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:\+[^ ]+)?$')
        .firstMatch(candidate);
    final installed = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:([-+]).*)?$')
        .firstMatch(current);
    if (stable == null || installed == null) return false;
    for (var i = 1; i <= 3; i++) {
      final comparison = int.parse(stable[i]!)
          .compareTo(int.parse(installed[i]!));
      if (comparison != 0) return comparison > 0;
    }
    return installed[4] == '-';
  }
}
