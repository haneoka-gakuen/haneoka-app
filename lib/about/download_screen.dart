import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../core/resource_file_cache.dart';
import '../shell/links.dart';
import '../shell/page.dart';
import '../ui/detail.dart';
import '../ui/tile.dart';

class DownloadScreen extends StatefulWidget {
  const DownloadScreen({super.key});
  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  Future<Map>? _release;
  String? _downloading;
  Completer<void>? _cancelled;
  String _platform = 'all';
  static const _platforms = [
    ('android', 'Android', Symbols.android_rounded),
    ('ios', 'iOS / iPadOS', Symbols.phone_iphone_rounded),
    ('windows', 'Windows', Symbols.window_rounded),
    ('macos', 'macOS', Symbols.laptop_mac_rounded),
    ('linux', 'Linux', Symbols.computer_rounded),
  ];
  String t(String key) => AppScope.of(context).text('download.$key');
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _release ??= _load();
  }

  Future<Map> _load() async =>
      await AppScope.of(context).api
              .live('https://haneoka.org/downloads/app/latest.json')
          as Map;
  Future<void> _download(Map asset) async {
    if (_downloading != null) return;
    final name = asset['name'] as String,
        url = Uri.parse(asset['browser_download_url'] as String);
    final cancelled = _cancelled = Completer<void>();
    setState(() => _downloading = name);
    ResourceFileLease? lease;
    try {
      lease = await resourceFileCache.acquire(
        url,
        kind: ResourceFileKind.media,
        cancelled: cancelled.future,
      );
      if (!mounted) return;
      final bytes = await lease.readBytes();
      if (!mounted) return;
      await FilePicker.saveFile(fileName: name, bytes: bytes);
    } on ResourceCacheCancelled {
      return;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppScope.of(context).text('common.states.error')),
          ),
        );
      }
    } finally {
      await lease?.release();
      if (mounted) setState(() => _downloading = null);
    }
  }

  String _format(String name) {
    if (name.endsWith('.pkg.tar.zst')) return 'Arch';
    if (name.endsWith('.tar.gz')) return 'tar.gz';
    if (name.endsWith('.tipa')) return 'TrollStore · TIPA';
    if (name.endsWith('.ipa')) return 'IPA';
    if (name.endsWith('.exe')) return 'EXE · ${t('installer')}';
    if (name.endsWith('.zip')) return 'ZIP · ${t('portable')}';
    if (name.endsWith('.aab')) return 'AAB · ${t('bundle')}';
    return name.split('.').last;
  }

  @override
  void dispose() {
    if (_cancelled != null && !_cancelled!.isCompleted) _cancelled!.complete();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = AppScope.of(context).text,
        theme = Theme.of(context),
        colors = theme.colorScheme;
    return FutureBuilder<Map>(
      future: _release,
      builder: (context, snapshot) {
        final release = snapshot.data,
            assets = (release?['assets'] as List? ?? const [])
                .whereType<Map>()
                .toList();
        final packages = assets
            .where(
              (a) => RegExp(
                r'\.(apk|aab|ipa|tipa|exe|msi|msix|zip|dmg|pkg|AppImage|deb|rpm|flatpak|snap|zst|gz)$',
              ).hasMatch('${a['name']}'),
            )
            .toList();
        String size(Map a) =>
            '${NumberFormat.decimalPatternDigits(locale: text.locale, decimalDigits: 1).format((a['size'] as num) / 1024 / 1024)} MB';
        Widget file(Map asset) => ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(_format('${asset['name']}')),
          subtitle: Text('${asset['name']} · ${size(asset)}'),
          trailing: _downloading == asset['name']
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Symbols.download_rounded),
          onTap: _downloading == null ? () => _download(asset) : null,
        );
        return ShellPage(
          title: t('title'),
          status: release == null ? null : Text('${release['tag_name']}'),
          actions: [
            BarAction(
              icon: Symbols.refresh_rounded,
              label: text('common.actions.refresh'),
              onPressed: () => setState(() => _release = _load()),
            ),
            if (release != null)
              BarAction(
                icon: Symbols.open_in_new_rounded,
                label: t('release'),
                onPressed: () => openLink(context, '${release['html_url']}'),
              ),
          ],
          body: release == null
              ? Center(
                  child: snapshot.hasError
                      ? FilledButton.tonal(
                          onPressed: () => setState(() => _release = _load()),
                          child: Text(text('common.actions.retry')),
                        )
                      : const CircularProgressIndicator(),
                )
              : ListView(
                  padding: pagePadding(context),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: colors.primaryContainer,
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t('hero'),
                            style: theme.textTheme.headlineLarge?.copyWith(
                              color: colors.onPrimaryContainer,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final (id, name, icon) in _platforms)
                                FilterChip(
                                  avatar: Icon(icon, size: 18),
                                  label: Text(name),
                                  selected: _platform == id,
                                  onSelected: (_) => setState(
                                    () => _platform = _platform == id
                                        ? 'all'
                                        : id,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    for (final (id, name, icon) in _platforms)
                      if (_platform == 'all' || _platform == id)
                        DetailSection(
                          icon: icon,
                          title: name,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (id == 'windows')
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: ActionChip(
                                    label: Text(t('windowsArmPackage')),
                                    onPressed: () => openLink(
                                      context,
                                      'https://learn.microsoft.com/windows/arm/apps-on-arm-x86-emulation',
                                    ),
                                  ),
                                ),
                              for (final arch
                                  in id == 'android'
                                      ? ['arm64-v8a', 'x86_64', 'universal']
                                      : id == 'ios'
                                      ? ['arm64']
                                      : ['x64', 'arm64']) ...[
                                if (packages.any(
                                  (a) => id == 'ios'
                                      ? '${a['name']}'.contains('-ios-')
                                      : arch == 'universal'
                                      ? RegExp(r'-android\.(apk|aab)$')
                                            .hasMatch('${a['name']}')
                                      : '${a['name']}'.contains('-$id-$arch'),
                                )) ...[
                                  Text(
                                    arch == 'universal'
                                        ? t('universal')
                                        : arch == 'arm64-v8a'
                                        ? 'ARM64 · arm64-v8a'
                                        : arch.toUpperCase(),
                                    style: theme.textTheme.titleSmall,
                                  ),
                                  for (final asset in packages.where(
                                    (a) => id == 'ios'
                                        ? '${a['name']}'.contains('-ios-')
                                        : arch == 'universal'
                                        ? RegExp(r'-android\.(apk|aab)$')
                                              .hasMatch('${a['name']}')
                                        : '${a['name']}'.contains('-$id-$arch'),
                                  ))
                                    file(asset),
                                ],
                              ],
                            ],
                          ),
                        ),
                    DetailSection(
                      icon: Symbols.verified_user_rounded,
                      title: t('extras'),
                      child: Column(
                        children: [
                          for (final asset in assets.where(
                            (a) =>
                                !packages.contains(a) &&
                                a['name'] != 'release-version.json',
                          ))
                            file(asset),
                        ],
                      ),
                    ),
                    DetailSection(
                      icon: Symbols.save_rounded,
                      title: t('saveTitle'),
                      child: OutlinedButton.icon(
                        onPressed: () => openLink(
                          context,
                          'https://github.com/haneoka-gakuen/haneoka-app#getting-the-save',
                        ),
                        icon: const Icon(Symbols.description_rounded),
                        label: Text(t('saveGuide')),
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}
