import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';
import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../account/account_widgets.dart';
import '../account/haneoka_account.dart';
import '../core/app_state.dart';
import '../core/storage.dart';
import '../l10n/app_localizations.dart';
import '../save/account_store.dart';
import '../save/game_save.dart';
import '../save/save_view.dart';
import '../shell/page.dart';
import '../sources/android.dart';
import '../sources/adb.dart';
import '../sources/files.dart';
import '../sources/ios_backup.dart';
import '../sources/ios_direct.dart';
import 'adb_sheet.dart';
import 'backup_sheet.dart';
import 'game_release_picker.dart';
import 'save_screen.dart';
import 'shapes.dart';
import 'theme.dart';
import 'tile.dart';

/// The emblem of a release's publisher, as the settings page shows it.
String releaseEmblem(GameRelease? release) => release == GameRelease.jp
    ? 'assets/settings/bushimo-circle.svg'
    : 'assets/settings/bilibili-circle.svg';

/// Adding a game account: every way this platform can reach the game's save,
/// each with what it needs and its steps. The game version is asked only for
/// files that do not name it.
///
/// With [returnResult] the screen pops with the accounts it read, so the page
/// that asked (gacha history, team builder) continues with them.
class ImportScreen extends StatefulWidget {
  const ImportScreen({
    super.key,
    this.initialPath,
    this.updateSave,
    this.onReadHistory,
    this.returnResult = false,
  });
  final SaveHistoryAction? onReadHistory;
  final String? initialPath;
  final GameSave? updateSave;
  final bool returnResult;
  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  SaveHistoryAction? get _historyAction =>
      widget.onReadHistory ?? SaveHistoryActionScope.maybeOf(context);
  bool _busy = false;
  ShizukuStatus? _shizuku;
  bool _canGrant = false;
  IosDirectAccess? _iosAccess;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) _refreshAndroid();
    if (Platform.isIOS) {
      IosDirectSaveSource.access().then((access) {
        if (mounted) setState(() => _iosAccess = access);
      });
    }
    if (widget.initialPath case final path?) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _run(
            (collector) => FileSaveSource(
              collector,
              release: widget.updateSave?.release,
            ).addPath(path),
          );
        }
      });
    }
  }

  Future<void> _refreshAndroid() async {
    final status = await AndroidSaveSource.shizukuStatus();
    final grant = await AndroidSaveSource.canGrantGameFolder();
    if (!mounted) return;
    setState(() {
      _shizuku = status;
      _canGrant = grant;
    });
  }

  AppLocalizations get t => AppLocalizations.of(context);
  GameRelease get _defaultRelease =>
      widget.updateSave?.release ??
      (AppScope.maybeOf(context)?.server == 'jp'
          ? GameRelease.jp
          : GameRelease.intlStore);

  /// A player ID names its region; only files without one ask the player.
  Future<List<GameSave>?> _withRelease(List<GameSave> saves) async {
    GameRelease? detected(GameSave save) =>
        switch (serverOfProfile(save.profileId)) {
          'jp' => GameRelease.jp,
          'intl' => GameRelease.intlStore,
          _ => null,
        };
    if (saves.every((save) => save.release != null || detected(save) != null)) {
      return [
        for (final save in saves)
          if (save.release != null)
            save
          else
            GameSave(
              profileId: save.profileId,
              name: save.name,
              release: detected(save),
              source: save.source,
            )..documents.addAll(save.documents),
      ];
    }
    final chosen =
        widget.updateSave?.release ??
        await chooseGameSaveRelease(context, initial: _defaultRelease);
    if (chosen == null) return null;
    return [
      for (final save in saves)
        if (save.release != null)
          save
        else
          GameSave(
            profileId: save.profileId,
            name: save.name,
            release: chosen,
            source: save.source,
          )..documents.addAll(save.documents),
    ];
  }

  void _say(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  /// Runs one import; every account found is kept, and one opens directly.
  Future<void> _run(Future<void> Function(SaveCollector collector) read) async {
    if (!mounted || _busy) return;
    setState(() => _busy = true);
    final collector = SaveCollector();
    CacheStorage.instance.beginImport();
    try {
      await read(collector);
      if (!mounted) return;
      if (collector.saves.isEmpty) {
        _say(t.noSaves);
        return;
      }
      final saves = await _withRelease(collector.saves);
      if (saves == null || !mounted) return;
      if (widget.updateSave case final previous?) {
        final replacement = saves
            .where(
              (save) =>
                  save.profileId == previous.profileId &&
                  save.server == previous.server,
            )
            .firstOrNull;
        if (replacement == null) {
          _say(t.saveAccountMismatch);
          return;
        }
        final updated = GameSave(
          profileId: replacement.profileId,
          name: replacement.name ?? previous.name,
          release: replacement.release,
          source: replacement.source,
        )..documents.addAll(replacement.documents);
        await AccountStore.instance.put(updated);
        unawaited(HaneokaAccount.instance.syncIfLinked(updated));
        if (mounted) Navigator.of(context).pop(updated);
        return;
      }
      for (final save in saves) {
        await AccountStore.instance.put(save);
        unawaited(HaneokaAccount.instance.syncIfLinked(save));
      }
      if (!mounted) return;
      if (widget.returnResult) {
        if (saves.length > 1) _say(t.foundAccounts(saves.length));
        Navigator.of(context).pop(saves);
      } else if (saves.length == 1) {
        final historyAction = _historyAction;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) =>
                SaveScreen(save: saves.single, onReadHistory: historyAction),
          ),
        );
      } else {
        _say(t.foundAccounts(saves.length));
        Navigator.of(context).pop();
      }
    } on IosDirectAccessException {
      if (mounted) {
        _say(
          AppScope.of(context).text(
            'app.import.iosDirectRestricted',
            'This installation cannot read another app’s private files. Export the Our Notes saves or backup on a computer, then import the exported files.',
          ),
        );
      }
    } on BackupPasswordException {
      if (mounted) _say(t.wrongPassword);
    } catch (error) {
      if (mounted) _say('$error');
    } finally {
      CacheStorage.instance.endImport();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _readShizuku() async {
    var status = await AndroidSaveSource.shizukuStatus();
    if (status == ShizukuStatus.needsPermission &&
        await AndroidSaveSource.requestShizuku()) {
      status = ShizukuStatus.ready;
    }
    if (!mounted) return;
    setState(() => _shizuku = status);
    if (status != ShizukuStatus.ready) {
      if (status == ShizukuStatus.notRunning) {
        await AndroidSaveSource.openShizuku();
      }
      return;
    }
    await _run((collector) async {
      for (final release in GameRelease.values.where(
        (value) =>
            widget.updateSave?.release == null ||
            value.server == widget.updateSave!.release!.server,
      )) {
        await AndroidSaveSource.readWithShizuku(release, collector);
      }
    });
  }

  Future<void> _grantFolder() async {
    final release =
        widget.updateSave?.release ??
        await chooseGameSaveRelease(context, initial: _defaultRelease);
    if (release == null || !mounted) return;
    final uri = await AndroidSaveSource.grantGameFolder(release);
    if (!mounted || uri == null) return;
    await _run(
      (collector) =>
          AndroidSaveSource.readFolder(uri, collector, release: release),
    );
  }

  Future<void> _readGranted() => _run((collector) async {
    for (final uri in await AndroidSaveSource.grantedFolders()) {
      await AndroidSaveSource.readFolder(uri, collector);
    }
  });

  Future<void> _pickFiles({bool folder = false}) async {
    if (folder) {
      final path = await FilePicker.getDirectoryPath();
      if (!mounted || path == null) return;
      await _run(
        (collector) => FileSaveSource(
          collector,
          release: widget.updateSave?.release,
        ).addPath(path),
      );
      return;
    }
    final picked = await FilePicker.pickFiles();
    if (!mounted || picked.isEmpty) return;
    await _run((collector) async {
      final source = FileSaveSource(
        collector,
        release: widget.updateSave?.release,
      );
      for (final file in picked) {
        final path = file.path;
        if (path != null) {
          await source.addPath(path);
        } else {
          source.addBytes(await file.readAsBytes(), file.name);
        }
      }
    });
  }

  Future<void> _readConnected() async {
    if (_busy) return;
    setState(() => _busy = true);
    AdbSaveSource? source;
    AdbDevice? device;
    List<GameRelease> installed = const [];
    try {
      final path = await AdbSaveSource.locate();
      if (path != null) {
        source = AdbSaveSource(path);
        final ready = (await source.devices())
            .where((device) => device.ready)
            .toList();
        if (ready.length == 1) {
          device = ready.single;
          installed = await source.installed(device.serial);
        }
      }
    } catch (error) {
      if (mounted) _say('$error');
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (source == null || device == null) {
      await showAdbSheet(context, onRead: _run);
      return;
    }
    if (installed.isEmpty) {
      _say(t.gameNotInstalled);
      return;
    }
    final adb = source, serial = device.serial;
    await _run((collector) async {
      for (final release in installed) {
        await adb.scan(serial, release, collector);
      }
    });
  }

  static bool get _hasPaths => !Platform.isIOS;
  static bool get _desktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final methods = <Widget>[
      if (Platform.isAndroid) ...[
        _Method(
          icon: Symbols.bolt_rounded,
          title: t.methodShizukuTitle,
          summary: t.methodShizukuSummary,
          steps: t.methodShizukuSteps,
          recommended: true,
          status: switch (_shizuku) {
            ShizukuStatus.notRunning => t.shizukuNotRunning,
            ShizukuStatus.unsupported => t.shizukuUnsupported,
            _ => null,
          },
          actions: [
            TextButton.icon(
              onPressed: () => launchUrl(
                Uri.parse('https://shizuku.rikka.app/download/'),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Symbols.open_in_new_rounded),
              label: Text(
                AppScope.of(context)
                    .text('app.import.downloadShizuku', 'Download Shizuku'),
              ),
            ),
            TextButton(
              onPressed: () => launchUrl(
                Uri.parse('https://shizuku.rikka.app/guide/setup/'),
                mode: LaunchMode.externalApplication,
              ),
              child: Text(
                AppScope.of(context)
                    .text('app.import.setupGuide', 'Setup guide'),
              ),
            ),
            if (_shizuku == ShizukuStatus.notRunning)
              TextButton(
                onPressed: AndroidSaveSource.openShizuku,
                child: Text(t.openShizuku),
              ),
            FilledButton.icon(
              onPressed: _busy ? null : _readShizuku,
              icon: const Icon(Symbols.download_rounded),
              label: Text(t.readSave),
            ),
          ],
        ),
        if (_canGrant)
          _Method(
            icon: Symbols.folder_special_rounded,
            title: t.methodFolderTitle,
            summary: t.methodFolderSummary,
            steps: t.methodFolderSteps,
            actions: [
              TextButton(
                onPressed: _busy ? null : _readGranted,
                child: Text(t.readAgain),
              ),
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _grantFolder,
                icon: const Icon(Symbols.folder_open_rounded),
                label: Text(t.chooseFolder),
              ),
            ],
          ),
      ],
      if (_desktop) ...[
        _Method(
          icon: Symbols.phone_android_rounded,
          title: t.methodAdbTitle,
          summary: t.methodAdbSummary,
          steps: t.methodAdbSteps,
          recommended: true,
          actions: [
            FilledButton.icon(
              onPressed: _busy ? null : _readConnected,
              icon: const Icon(Symbols.cable_rounded),
              label: Text(
                AppScope.of(context)
                    .text('app.import.readConnected', 'Read connected device'),
              ),
            ),
            TextButton.icon(
              onPressed: _busy
                  ? null
                  : () => showAdbSheet(context, onRead: _run),
              icon: const Icon(Symbols.devices_rounded),
              label: Text(
                AppScope.of(context).text(
                  'app.import.chooseDevice',
                  'Choose device / wireless pairing',
                ),
              ),
            ),
          ],
        ),
        _Method(
          icon: Symbols.phone_iphone_rounded,
          title: t.methodBackupTitle,
          summary: t.methodBackupSummary,
          steps: t.methodBackupSteps,
          actions: [
            if (Platform.isMacOS || Platform.isWindows) ...[
              TextButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse('https://imazing.com/download'),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Symbols.open_in_new_rounded),
                label: Text(
                  AppScope.of(context)
                      .text('app.import.downloadIMazing', 'Download iMazing'),
                ),
              ),
              TextButton(
                onPressed: () => launchUrl(
                  Uri.parse(
                    'https://imazing.com/guides/how-to-export-backup-and-transfer-ios-apps-data-and-settings',
                  ),
                  mode: LaunchMode.externalApplication,
                ),
                child: Text(
                  AppScope.of(context)
                      .text('app.import.exportGuide', 'Export app data'),
                ),
              ),
            ],
            if (Platform.isLinux)
              TextButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse(
                    'https://github.com/libimobiledevice/libimobiledevice',
                  ),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Symbols.open_in_new_rounded),
                label: const Text('libimobiledevice'),
              ),
            FilledButton.tonalIcon(
              onPressed: _busy
                  ? null
                  : () => showBackupSheet(context, onRead: _run),
              icon: const Icon(Symbols.backup_rounded),
              label: Text(t.openBackups),
            ),
          ],
        ),
      ],
      if (Platform.isIOS)
        _Method(
          icon: Symbols.phone_iphone_rounded,
          title: AppScope.of(context)
              .text('app.import.iosDirectTitle', 'Import from this device'),
          summary: AppScope.of(context).text(
            'app.import.iosDirectSummary',
            'Reads Our Notes Documents directly when this installation already has container access.',
          ),
          steps: AppScope.of(context).text(
            'app.import.iosDirectSteps',
            'Use the dedicated TrollStore build on a supported device, or an already-authorized jailbreak installation. Tap Read save. Haneoka reads the matching game containers and does not modify the game.',
          ),
          status: _iosAccess == IosDirectAccess.available
              ? AppScope.of(context).text(
                  'app.import.iosDirectAvailable',
                  'Container access available',
                )
              : AppScope.of(context).text(
                  'app.import.iosDirectRestricted',
                  'This installation cannot read another app’s private files. Export the Our Notes saves or backup on a computer, then import the exported files.',
                ),
          actions: [
            FilledButton.icon(
              onPressed: _busy ? null : () => _run(IosDirectSaveSource.read),
              icon: const Icon(Symbols.download_rounded),
              label: Text(t.readSave),
            ),
            TextButton.icon(
              onPressed: () => launchUrl(
                Uri.parse('https://github.com/opa334/TrollStore'),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Symbols.open_in_new_rounded),
              label: const Text('TrollStore'),
            ),
          ],
        ),
      if (Platform.isIOS)
        _Method(
          icon: Symbols.folder_special_rounded,
          title: AppScope.of(
            context,
          ).text('app.import.advancedTitle', 'TrollStore / jailbroken device'),
          summary: AppScope.of(context).text(
            'app.import.advancedSummary',
            'Export the game account folder using a compatible file manager.',
          ),
          steps: AppScope.of(context).text(
            'app.import.advancedSteps',
            'In Filza or Apps Manager, find Our Notes by its bundle ID, open its data container, and copy Documents/<account> to a ZIP in Files. Then choose that ZIP below or share it to Haneoka. For SFTP, copy the same folder to your computer. Check each tool’s supported device and iOS versions on its official page.',
          ),
          actions: [
            for (final (title, url) in const [
              ('TrollStore', 'https://github.com/opa334/TrollStore'),
              ('Filza', 'https://www.tigisoftware.com/default/?p=439'),
              ('Apps Manager', 'https://www.tigisoftware.com/default/?p=510'),
              ('Dopamine', 'https://ellekit.space/dopamine/'),
            ])
              TextButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse(url),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Symbols.open_in_new_rounded),
                label: Text(title),
              ),
          ],
        ),
      _Method(
        icon: Symbols.file_open_rounded,
        title: t.methodFilesTitle,
        summary: t.methodFilesSummary,
        steps: t.methodFilesSteps,
        recommended: Platform.isIOS,
        note: Platform.isIOS
            ? AppScope.of(context).text(
                'app.import.iosAccess',
                'Our Notes does not expose its saves in the Files app. Standard iOS installations require game data exported on a computer through iMazing or a local device backup. Transfer the exported save files, ZIP, or .imazingapp to this device, then select those files below or use Share → Haneoka.',
              )
            : null,
        actions: [
          if (_hasPaths)
            TextButton(
              onPressed: _busy ? null : () => _pickFiles(folder: true),
              child: Text(t.chooseFolder),
            ),
          FilledButton.tonalIcon(
            onPressed: _busy ? null : _pickFiles,
            icon: const Icon(Symbols.upload_file_rounded),
            label: Text(t.chooseFiles),
          ),
        ],
      ),
    ];
    return ShellPage(
      title: widget.updateSave == null ? t.importTitle : t.updateSave,
      body: Stack(
        children: [
          ListView(
            padding: pagePadding(context),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ShapedIcon(
                            shape: MaterialShapes.cookie9Sided,
                            size: 56,
                            child: const Icon(
                              Symbols.sd_card_rounded,
                              size: 28,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.updateSave == null
                                      ? t.importHeadline
                                      : t.updateSave,
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  widget.updateSave == null
                                      ? t.importIntro
                                      : '${widget.updateSave!.name ?? widget.updateSave!.profileId} · ${widget.updateSave!.profileId}\n${t.updateSaveHint}',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Text(
                        t.methodsTitle,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 12),
                      for (final method in methods)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: method,
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (_busy)
            const Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }
}

/// One way to reach the save: what it is, what it needs, its steps and its
/// button, as an M3 Expressive card.
class _Method extends StatelessWidget {
  const _Method({
    required this.icon,
    required this.title,
    required this.summary,
    required this.steps,
    required this.actions,
    this.recommended = false,
    this.status,
    this.note,
  });
  final IconData icon;
  final String title;
  final String summary;
  final String steps;
  final List<Widget> actions;
  final bool recommended;
  final String? status;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lines = steps.split('\n');
    return Material(
      color: recommended
          ? scheme.secondaryContainer.withValues(alpha: 0.55)
          : scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(Corner.extraLarge),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ShapedIcon(
                  shape: MaterialShapes.cookie9Sided,
                  size: 44,
                  color: recommended ? scheme.primary : null,
                  foreground: recommended ? scheme.onPrimary : null,
                  child: Icon(icon, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            title,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (recommended)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                borderRadius: BorderRadius.circular(
                                  Corner.full,
                                ),
                              ),
                              child: Text(
                                t.recommended,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onPrimary,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(summary, style: theme.textTheme.bodyMedium),
                      if (status != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            children: [
                              Icon(
                                Symbols.error_rounded,
                                size: 16,
                                color: scheme.error,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                status!,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: scheme.error,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.only(left: 58, right: 0),
                childrenPadding: const EdgeInsets.only(left: 58, bottom: 4),
                dense: true,
                title: Text(t.stepsShow, style: theme.textTheme.labelLarge),
                children: [
                  for (final (index, line) in lines.indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 22,
                            height: 22,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              '${index + 1}',
                              style: theme.textTheme.labelSmall,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              line,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (note != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        note!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: actions,
            ),
          ],
        ),
      ),
    );
  }
}

/// The imported accounts (`/account`): each player's card, opening their
/// profile; importing another account is the primary action.
class AccountsScreen extends StatefulWidget {
  const AccountsScreen({super.key, this.onReadHistory});
  final SaveHistoryAction? onReadHistory;
  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  SaveHistoryAction? get _historyAction =>
      widget.onReadHistory ?? SaveHistoryActionScope.maybeOf(context);
  @override
  void initState() {
    super.initState();
    AccountStore.instance.load();
  }

  void _import() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ImportScreen(onReadHistory: _historyAction),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final site = AppScope.of(context).text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ShellPage(
      title: site('navigation.account', 'Account'),
      actions: [
        BarAction(
          icon: Symbols.add_rounded,
          label: t.importMore,
          onPressed: _import,
        ),
      ],
      body: ListenableBuilder(
        listenable: AccountStore.instance,
        builder: (context, _) {
          final saves = AccountStore.instance.saves;
          return ListView(
            padding: pagePadding(context),
            children: [
              const HaneokaAccountCard(),
              const SizedBox(height: 24),
              Text(
                t.importedAccounts,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              if (saves.isEmpty)
                Material(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(Corner.extraLarge),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        ShapedIcon(
                          shape: MaterialShapes.cookie9Sided,
                          size: 64,
                          child: const Icon(Symbols.sd_card_rounded, size: 32),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          t.noAccountsYet,
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          t.importIntro,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _import,
                          icon: const Icon(Symbols.add_rounded),
                          label: Text(t.importMore),
                        ),
                      ],
                    ),
                  ),
                )
              else
                for (final save in saves)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: AccountCard(
                      save: save,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => SaveScreen(
                            save: save,
                            onReadHistory: _historyAction,
                          ),
                        ),
                      ),
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

/// An imported player opened by address (`/account/{server}/{id}`).
class StoredPlayerScreen extends StatefulWidget {
  const StoredPlayerScreen({
    super.key,
    required this.server,
    required this.profileId,
    this.onReadHistory,
  });
  final SaveHistoryAction? onReadHistory;
  final String server;
  final String profileId;
  @override
  State<StoredPlayerScreen> createState() => _StoredPlayerScreenState();
}

class _StoredPlayerScreenState extends State<StoredPlayerScreen> {
  @override
  void initState() {
    super.initState();
    AccountStore.instance.load();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AccountStore.instance,
    builder: (context, _) {
      final save = AccountStore.instance.saves
          .where(
            (s) => s.server == widget.server && s.profileId == widget.profileId,
          )
          .firstOrNull;
      final action =
          widget.onReadHistory ?? SaveHistoryActionScope.maybeOf(context);
      return save == null
          ? AccountsScreen(onReadHistory: action)
          : SaveScreen(save: save, onReadHistory: action);
    },
  );
}

/// A player as one card: name, version emblem, rank and ID, last saved.
class AccountCard extends StatelessWidget {
  const AccountCard({super.key, required this.save, this.onTap});
  final GameSave save;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final view = SaveView(save);
    final locale = Localizations.localeOf(context).toLanguageTag();
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(Corner.extraLarge),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              ShapedIcon(
                shape: MaterialShapes.sunny,
                size: 56,
                color: scheme.primaryContainer,
                foreground: scheme.onPrimaryContainer,
                child: Text(
                  '${view.playerRank ?? '—'}',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            save.name ?? save.profileId,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SvgPicture.asset(
                          releaseEmblem(save.release),
                          width: 18,
                          height: 18,
                        ),
                      ],
                    ),
                    Text(
                      [
                        if (save.regionName case final region?) region,
                        'ID ${save.profileId}',
                      ].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (save.modifiedAt != null)
                      Text(
                        t.savedOn(
                          DateFormat.yMMMd(locale)
                              .add_Hm()
                              .format(save.modifiedAt!.toLocal()),
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const Icon(Symbols.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}
