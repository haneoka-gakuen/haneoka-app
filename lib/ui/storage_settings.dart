import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/api.dart';
import '../core/app_state.dart';
import '../core/storage.dart';
import '../shell/links.dart';
import '../stories/offline_stories.dart';

class StorageSettings extends StatefulWidget {
  const StorageSettings({super.key});
  @override
  State<StorageSettings> createState() => _StorageSettingsState();
}

class _StorageSettingsState extends State<StorageSettings> {
  late Future<StorageUsage> _usage = CacheStorage.instance.usage();
  bool _running = false;
  String _bytes(int bytes) {
    final number = NumberFormat.decimalPattern(
      AppScope.of(context).text.locale,
    );
    if (bytes < 1024) return '${number.format(bytes)} B';
    if (bytes < 1 << 20) return '${number.format((bytes / 1024).round())} KB';
    if (bytes < 1 << 30) {
      return '${number.format((bytes / (1 << 20) * 10).round() / 10)} MB';
    }
    return '${number.format((bytes / (1 << 30) * 100).round() / 100)} GB';
  }

  Future<void> _clear(CacheCategory category) async {
    if (_running) return;
    setState(() => _running = true);
    try {
      final reclaimed = await CacheStorage.instance.clear(category);
      if (const {CacheCategory.data, CacheCategory.all}.contains(category)) {
        HaneokaApi.invalidateCaches();
      }
      if (!mounted) return;
      setState(() => _usage = CacheStorage.instance.usage());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppScope.of(context).text('app.storage.cleared', 'Freed {size}', {
              'size': _bytes(reclaimed),
            }),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    final theme = Theme.of(context), storage = CacheStorage.instance;
    return ListenableBuilder(
      listenable: storage,
      builder: (context, _) => FutureBuilder(
        future: _usage,
        builder: (context, snapshot) {
          final usage = snapshot.data;
          final disabled = _running || storage.busy;
          Widget row(
            String label,
            int? size,
            IconData icon, [
            VoidCallback? clear,
          ]) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(icon),
            title: Text(label),
            subtitle: size == null ? null : Text(_bytes(size)),
            trailing: clear == null
                ? null
                : IconButton(
                    tooltip: t('app.storage.clear', 'Clear'),
                    onPressed: disabled ? null : clear,
                    icon: const Icon(Symbols.delete_sweep_rounded),
                  ),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Symbols.storage_rounded),
                title: Text(
                  t('app.storage.title', 'Storage and cache'),
                  style: theme.textTheme.titleLarge,
                ),
                subtitle: usage == null
                    ? null
                    : Text(
                        t('app.storage.total', 'Local app data: {size}', {
                          'size': _bytes(usage.total),
                        }),
                      ),
                trailing: IconButton(
                  tooltip: t('common.actions.refresh', 'Refresh'),
                  onPressed: disabled
                      ? null
                      : () => setState(() => _usage = storage.usage()),
                  icon: const Icon(Symbols.refresh_rounded),
                ),
              ),
              if (snapshot.hasError)
                FilledButton.tonalIcon(
                  onPressed: () => setState(() => _usage = storage.usage()),
                  icon: const Icon(Symbols.refresh_rounded),
                  label: Text(t('common.actions.retry', 'Retry')),
                )
              else if (usage == null)
                const LinearProgressIndicator()
              else ...[
                if (storage.limitMb > 0)
                  LinearProgressIndicator(
                    value: (usage.cache / (storage.limitMb << 20)).clamp(
                      0.0,
                      1.0,
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  t('app.storage.usedLimit', 'Cache: {used} / {limit}', {
                    'used': _bytes(usage.cache),
                    'limit': storage.limitMb == 0
                        ? t('app.storage.unlimited', 'Unlimited')
                        : _bytes(storage.limitMb << 20),
                  }),
                ),
              ],
              row(
                t('app.storage.data', 'Catalogue data cache'),
                usage?.data,
                Symbols.database_rounded,
                () => _clear(CacheCategory.data),
              ),
              row(
                t('app.storage.media', 'Audio and video cache'),
                usage?.media,
                Symbols.movie_rounded,
                () => _clear(CacheCategory.media),
              ),
              row(
                t('app.storage.resources', 'Player resource cache'),
                usage?.resources,
                Symbols.view_in_ar_rounded,
                () => _clear(CacheCategory.resources),
              ),
              row(
                t('app.storage.images', 'Image cache'),
                usage?.images,
                Symbols.image_rounded,
                () => _clear(CacheCategory.images),
              ),
              row(
                t('app.storage.memory', 'Memory image cache'),
                usage?.memory,
                Symbols.memory_rounded,
              ),
              row(
                t('app.storage.accounts', 'Imported save data'),
                usage?.accounts,
                Symbols.save_rounded,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => openLink(context, '/account'),
                  icon: const Icon(Symbols.manage_accounts_rounded),
                  label: Text(
                    t('app.storage.manageAccounts', 'Manage imported saves'),
                  ),
                ),
              ),
              row(
                t('app.storage.temporary', 'Import and other temporary files'),
                usage?.temporary,
                Symbols.folder_delete_rounded,
                storage.activeImports > 0
                    ? null
                    : () => _clear(CacheCategory.temporary),
              ),
              row(
                t('app.storage.other', 'Settings and other local data'),
                usage?.other,
                Symbols.folder_rounded,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Symbols.download_done_rounded),
                title: Text(t('app.offline.title')),
                trailing: const Icon(Symbols.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    settings: const RouteSettings(name: '/offline/stories'),
                    builder: (_) => const OfflineStoriesScreen(),
                  ),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  t(
                    'app.storage.automatic',
                    'Automatically remove older cache files',
                  ),
                ),
                value: storage.automatic && storage.limitMb > 0,
                subtitle: storage.limitMb == 0
                    ? Text(
                        t(
                          'app.storage.noLimit',
                          'Capacity cleanup is inactive with an unlimited cache.',
                        ),
                      )
                    : null,
                onChanged: disabled || storage.limitMb == 0
                    ? null
                    : (value) async {
                        try {
                          await storage.configure(auto: value);
                          if (mounted) setState(() => _usage = storage.usage());
                        } catch (error) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(SnackBar(content: Text('$error')));
                          }
                        }
                      },
              ),
              DropdownButtonFormField<int>(
                key: ValueKey(storage.limitMb),
                initialValue: storage.limitMb,
                decoration: InputDecoration(
                  labelText: t('app.storage.limit', 'Cache limit'),
                ),
                items: [
                  for (final value in const [0, 1024, 2048, 4096, 8192, 16384])
                    DropdownMenuItem(
                      value: value,
                      child: Text(
                        value == 0
                            ? t('app.storage.unlimited', 'Unlimited')
                            : _bytes(value << 20),
                      ),
                    ),
                ],
                onChanged: disabled
                    ? null
                    : (value) async {
                        if (value == null) return;
                        try {
                          await storage.configure(limit: value);
                          if (mounted) setState(() => _usage = storage.usage());
                        } catch (error) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(SnackBar(content: Text('$error')));
                          }
                        }
                      },
              ),
              const SizedBox(height: 12),
              Text(
                t(
                  'app.storage.preserved',
                  'Imported saves, sign-in and settings are retained.',
                ),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: disabled || storage.activeImports > 0
                      ? null
                      : () => _clear(CacheCategory.all),
                  icon: disabled
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Symbols.delete_sweep_rounded),
                  label: Text(t('app.storage.clearAll', 'Clear all cache')),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
