import '../core/site_date.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';


import '../l10n/app_localizations.dart';
import '../sources/ios_backup.dart';
import 'adb_sheet.dart';

Future<void> showBackupSheet(
  BuildContext context, {
  required SaveRead onRead,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _BackupSheet(onRead: onRead),
);

/// Local iPhone and iPad backups: the system's backup folder, or one the user
/// chooses (Linux, or a copied backup).
class _BackupSheet extends StatefulWidget {
  const _BackupSheet({required this.onRead});
  final SaveRead onRead;
  @override
  State<_BackupSheet> createState() => _BackupSheetState();
}

class _BackupSheetState extends State<_BackupSheet> {
  List<IosBackup>? _backups;

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load(IosBackup.defaultFolders());
  }

  Future<void> _load(List<String> folders) async {
    final found = <IosBackup>[];
    for (final folder in folders) {
      try {
        found.addAll(await IosBackup.find(folder));
      } on Exception {
        // A folder the app may not read (macOS without Full Disk Access) lists nothing.
      }
    }
    if (mounted) {
      setState(
        () => _backups = [
          ...?_backups?.where((b) => !found.any((f) => f.path == b.path)),
          ...found,
        ],
      );
    }
  }

  Future<void> _choose() async {
    final folder = await FilePicker.getDirectoryPath();
    if (folder != null) await _load([folder]);
  }

  Future<void> _read(IosBackup backup) async {
    String? password;
    if (backup.encrypted) {
      password = await _askPassword();
      if (password == null) return;
    }
    if (!mounted) return;
    Navigator.pop(context);
    await widget.onRead((collector) async {
      await backup.scan(collector, password: password);
    });
  }

  Future<String?> _askPassword() async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t.backupPassword),
          content: TextField(
            controller: controller,
            obscureText: true,
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: Text(t.read),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final backups = _backups;
    final date = SiteDate.day(
      Localizations.localeOf(context).toLanguageTag(),
    ).withTime();
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            title: Text(
              t.sourceIosBackup,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            trailing: IconButton(
              tooltip: t.chooseBackupFolder,
              onPressed: _choose,
              icon: const Icon(Symbols.folder_open_rounded),
            ),
          ),
          if (backups == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (backups.isEmpty)
            ListTile(
              leading: const Icon(Symbols.inbox_rounded),
              title: Text(t.noBackups),
            )
          else
            for (final backup in backups)
              ListTile(
                leading: Icon(
                  backup.encrypted
                      ? Symbols.lock_rounded
                      : Symbols.phone_iphone_rounded,
                ),
                title: Text(
                  backup.deviceName ?? backup.productType ?? backup.path,
                ),
                subtitle: Text(
                  [
                    if (backup.date != null)
                      date.format(backup.date!.toLocal()),
                    if (backup.encrypted) t.encrypted,
                  ].join(' · '),
                ),
                onTap: () => _read(backup),
              ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
