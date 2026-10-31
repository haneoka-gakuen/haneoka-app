import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../save/game_save.dart';
import 'game_history_client.dart';

String historySaveKey(GameSave save) => sha256
    .convert(
      utf8.encode('${save.server ?? 'unknown'}:${save.profileId}'),
    )
    .toString();

String? historyPersistKey(Object? document) {
  if (SavedGameSession.fromPersist(document) == null || document is! Map) {
    return null;
  }
  final certification = document['_certification'] as Map;
  return sha256
      .convert(utf8.encode(certification['_playerId'] as String))
      .toString();
}

String historyPortableKey(String localKey, String server) =>
    sha256.convert(utf8.encode('$server:$localKey')).toString();
