import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'game_save.dart';

/// Fields that identify the person or let someone act as them. They never
/// leave the device in an export.
const identityFields = {
  '_name',
  '_accountid',
  '_accountId',
  '_password',
  '_hasPassword',
  '_friendInvitationCode',
  '_linkedAccountTypes',
  '_specialFocusAccountIds',
  '_certification',
  '_grantedIapTransactions',
  '_cpServerId',
  '_cpServerName',
  '_world_room_id',
  '_reportedPlayerIds',
  '_friendProfile',
  '_sendingRequestProfile',
  '_pendingApprovalProfile',
  '_externalPaymentNotifications',
  '_chatRead',
};

Object? _withoutIdentity(Object? value) => switch (value) {
  Map<String, Object?>() => {
    for (final entry in value.entries)
      if (!identityFields.contains(entry.key))
        entry.key: _withoutIdentity(entry.value),
  },
  List() => [for (final item in value) _withoutIdentity(item)],
  _ => value,
};

/// The whole save, minus identity: every progress, collection, result and
/// setting the game keeps. Readable by Haneoka and by anything that reads JSON.
Uint8List exportSave(GameSave save) {
  final cache = save.documents[SaveDocumentKind.cache]?.data ?? const {};
  final document = {
    'schema': 'haneoka-game-save-v1',
    'server': save.server,
    'release': save.release?.packageId,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'savedAt': save.modifiedAt?.toUtc().toIso8601String(),
    'player': _withoutIdentity(cache['_player']),
    'settings': _withoutIdentity({
      for (final e in cache.entries)
        if (e.key != '_player') e.key: e.value,
    }),
    'persist': _withoutIdentity(save.documents[SaveDocumentKind.persist]?.data),
    'permanent': _withoutIdentity(
      save.documents[SaveDocumentKind.permanent]?.data,
    ),
  };
  return Uint8List.fromList(
    utf8.encode(const JsonEncoder.withIndent('  ').convert(document)),
  );
}

/// `ONPKG1:` text for Haneoka's team builder: card, character and band item
/// progress as positional rows. Experience stays a decimal string.
String exportTeamPackage(GameSave save) {
  final player = save.player;
  List<Map<String, Object?>> rows(String key) =>
      (player[key] as List?)?.whereType<Map<String, Object?>>().toList() ??
      const [];
  String? decimal(Object? v) => v == null ? null : '$v';
  final package = {
    'v': 1,
    'm': [
      for (final row in rows('_memberCards'))
        [
          row['_masterId'],
          decimal(row['_exp']),
          row['_awakeCount'],
          row['_rank'],
          row['_liveSkillLevel'],
          row['_performanceSkillLevel'],
        ],
    ],
    's': [
      for (final row in rows('_supportCards'))
        [row['_masterId'], decimal(row['_exp']), row['_rank']],
    ],
    'c': [
      for (final row in rows('_characters'))
        [row['_masterId'], decimal(row['_exp'])],
    ],
    'b': [
      for (final row in rows('_bandItems')) [row['_masterId'], row['_level']],
    ],
  };
  final zipped = GZipEncoder().encodeBytes(utf8.encode(jsonEncode(package)));
  return 'ONPKG1:${base64.encode(zipped)}';
}
