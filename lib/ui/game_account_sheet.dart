import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../l10n/app_localizations.dart';
import '../save/account_store.dart';
import '../save/game_save.dart';
import 'import_screen.dart';

/// Reads new game accounts and returns them to the page that asked.
Future<List<GameSave>> addGameAccounts(BuildContext context) async =>
    await Navigator.of(context).push<List<GameSave>>(
      MaterialPageRoute(
        builder: (_) => const ImportScreen(returnResult: true),
        settings: const RouteSettings(name: '/account/import'),
      ),
    ) ??
    const [];

/// One more way to continue, below the game accounts (for example a file).
class GameAccountSheetAction {
  const GameAccountSheetAction(this.id, this.icon, this.label);
  final String id;
  final IconData icon;
  final String label;
}

/// What the player chose: a stored or newly added game account, or an
/// [GameAccountSheetAction] by its id.
typedef GameAccountChoice = ({GameSave? save, String? action});

/// The one place a page asks for a game account: the stored accounts of
/// [server] (all servers when null), then "Add game account", which reads
/// the save and comes back here with it.
Future<GameAccountChoice?> chooseGameAccount(
  BuildContext context, {
  String? server,
  List<GameAccountSheetAction> actions = const [],
}) async {
  await AccountStore.instance.load();
  if (!context.mounted) return null;
  final picked = await showModalBottomSheet<Object>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) {
      final t = AppLocalizations.of(context);
      final theme = Theme.of(context);
      final saves = [
        for (final save in AccountStore.instance.saves)
          if (server == null || save.server == server) save,
      ];
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  t.importedAccounts,
                  style: theme.textTheme.titleLarge,
                ),
              ),
              for (final save in saves)
                ListTile(
                  minTileHeight: 64,
                  leading: SvgPicture.asset(
                    releaseEmblem(save.release),
                    width: 32,
                    height: 32,
                  ),
                  title: Text(
                    save.name ?? save.profileId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [?save.regionName, 'ID ${save.profileId}'].join(' · '),
                  ),
                  trailing: const Icon(Symbols.chevron_right_rounded),
                  onTap: () => Navigator.pop(context, save),
                ),
              ListTile(
                minTileHeight: 56,
                leading: const Icon(Symbols.add_rounded),
                title: Text(t.importMore),
                onTap: () => Navigator.pop(context, #add),
              ),
              if (actions.isNotEmpty) const Divider(),
              for (final action in actions)
                ListTile(
                  minTileHeight: 56,
                  leading: Icon(action.icon),
                  title: Text(action.label),
                  onTap: () => Navigator.pop(context, action.id),
                ),
            ],
          ),
        ),
      );
    },
  );
  if (picked is GameSave) return (save: picked, action: null);
  if (picked is String) return (save: null, action: picked);
  if (picked != #add || !context.mounted) return null;
  final added = await addGameAccounts(context);
  final save =
      added
          .where((save) => server == null || save.server == server)
          .firstOrNull ??
      added.firstOrNull;
  return save == null ? null : (save: save, action: null);
}
