/// Refreshes an imported account's card, character and band item progress
/// from the game server with the certification its save already holds, so a
/// once-imported save (e.g. from a local iPhone backup) stays current
/// without exporting again.
library;

import 'package:game_data_exporter/gacha_history.dart';

import '../core/system_proxy.dart';
import 'account_store.dart';
import 'game_save.dart';

class PlayerRefreshError implements Exception {
  const PlayerRefreshError(this.code);

  /// `no_session`, `player_data_unrecognized`, or a `history_*` code from
  /// the game client.
  final String code;
  @override
  String toString() => code;
}

const _lists = ['_memberCards', '_supportCards', '_characters', '_bandItems'];

final _client = GameHistoryClient(
  proxyFor: (uri) => systemProxyFor(uri).httpProxy,
);

GameHistoryRegion? _region(GameSave save) => switch (save.region) {
  'jp' => GameHistoryRegion.jp,
  'tw' => GameHistoryRegion.hmt,
  'en' => GameHistoryRegion.en,
  'kr' => GameHistoryRegion.ko,
  _ => null,
};

SavedGameSession? _session(GameSave save) => SavedGameSession.fromPersist(
  save.documents[SaveDocumentKind.persist]?.data,
);

/// Whether [save] carries a certification the game server can accept.
bool canRefreshFromGame(GameSave save) =>
    _session(save) != null && _region(save) != null;

Set<Object?> _ids(Object? rows) => {
  for (final row in rows is List ? rows : const []) (row as Map)['_masterId'],
};

/// Reads the account's current progress and stores it in place of the
/// save's lists. Cards are never lost in the game, so a response missing
/// cards the save already has is refused rather than stored.
Future<GameSave> refreshFromGame(GameSave save) async {
  final session = _session(save), region = _region(save);
  if (session == null || region == null) {
    throw const PlayerRefreshError('no_session');
  }
  final Map<String, List<Map<String, Object?>>> fresh;
  try {
    fresh = await _client.readPlayerData(session, region);
  } on GameHistoryException catch (error) {
    throw PlayerRefreshError(error.code);
  }
  final player = save.player;
  for (final key in const ['_memberCards', '_supportCards']) {
    final known = _ids(player[key]);
    if (known.isNotEmpty && !_ids(fresh[key]).containsAll(known)) {
      throw const PlayerRefreshError('player_data_unrecognized');
    }
  }
  if (fresh['_memberCards']!.isEmpty) {
    throw const PlayerRefreshError('player_data_unrecognized');
  }
  final cache = save.documents[SaveDocumentKind.cache]?.data ?? const {};
  final updated = GameSave(
    profileId: save.profileId,
    name: save.name,
    release: save.release,
    source: save.source,
  )..documents.addAll(save.documents);
  updated.documents[SaveDocumentKind.cache] = SaveDocument(
    SaveDocumentKind.cache,
    {
      ...cache,
      '_player': {...player, for (final key in _lists) key: fresh[key]},
    },
    DateTime.now(),
  );
  await AccountStore.instance.put(updated);
  return updated;
}
