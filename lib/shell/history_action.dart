import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../gacha_history/game_history_client.dart';
import '../gacha_history/history_read.dart';
import '../l10n/app_localizations.dart';
import '../save/game_save.dart';
import 'links.dart';
import 'pending_import.dart';

/// "Read gacha history" on a save's page: the game server's history, shown on
/// the website's gacha history page.
Future<void> readHistoryToSite(BuildContext context, GameSave save) async {
  final t = AppLocalizations.of(context);
  final locale = AppScope.of(context).text.locale;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final file = await readHistory(save);
    PendingHistory.set([file]);
    if (context.mounted) await openLink(context, '/$locale/gacha-history/');
  } on GameHistoryException catch (error) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          error.code == 'history_missing_session'
              ? t.syncSessionExpired
              : t.syncFailed,
        ),
      ),
    );
  }
}
