import 'dart:convert';

import '../save/game_save.dart';
import '../save/player_refresh.dart';
import 'game_history_client.dart';
import 'history_identity.dart';

/// The key the website files an account's history under: the companion
/// export's `{saveKey}-{region}`.
String? historyKey(GameSave save) => switch (gameHistoryRegion(save)) {
  final region? => '${historySaveKey(save)}-${region.id}',
  null => null,
};

/// The account's gacha history as the game server has it now, as the
/// companion file the website imports.
Future<({String name, String text})> readHistory(GameSave save) async {
  final session = gameSession(save), region = gameHistoryRegion(save);
  if (session == null || region == null) {
    throw const GameHistoryException('history_missing_session');
  }
  final key = historyKey(save)!;
  final snapshot = (await gameClient.read(
    session,
    region,
  )).forAccount(historyPortableKey(key, region.id));
  return (name: '$key.json', text: jsonEncode(snapshot.toJson()));
}
