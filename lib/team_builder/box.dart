/// The team box: owned cards, account bonuses, saved teams and settings as
/// one conflict-free document (`team-builder/sync/box-doc.ts`), kept on the
/// device and synced with the website through `/api/v1/team-box/{server}`
/// when the reader is signed in (`box-store.ts`). Every field is its own
/// key; the newest clock wins and ties break on the writer id.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/haneoka_account.dart';
import 'engine/api.dart';
import 'engine/box.dart';

class BoxEntry {
  BoxEntry(this.v, this.t, this.c, this.r);
  factory BoxEntry.fromJson(Map<String, Object?> json) => BoxEntry(
    json['v'],
    (json['t'] as num).toInt(),
    '${json['c']}',
    (json['r'] as num?)?.toInt() ?? 0,
  );

  /// The value; null deletes (a tombstone that keeps its clock).
  final Object? v;

  /// Hybrid logical clock: milliseconds since the epoch, bumped past any seen clock.
  final int t;

  /// Writer id, the tie break for equal clocks.
  final String c;

  /// Server revision of the last change; 0 for an entry not yet stored.
  int r;
  Map<String, Object?> toJson() => {'v': v, 't': t, 'c': c, 'r': r};
}

class BoxOp {
  BoxOp(this.k, this.v, this.t, this.c);
  factory BoxOp.fromJson(Map<String, Object?> json) => BoxOp(
    '${json['k']}',
    json['v'],
    (json['t'] as num).toInt(),
    '${json['c']}',
  );
  final String k;
  final Object? v;
  final int t;
  final String c;
  Map<String, Object?> toJson() => {'k': k, 'v': v, 't': t, 'c': c};
}

bool _newer(({int t, String c}) a, BoxEntry? b) =>
    b == null || a.t > b.t || (a.t == b.t && a.c.compareTo(b.c) > 0);

final _cardKey = RegExp(r'^(m|s)\.([1-9]\d{0,9})\.([a-z]{2,4})$');
final _accountKey = RegExp(r'^(cr|bi|br|cm|mm)\.([1-9]\d{0,9})$');
final _playerKey = RegExp(r'^p\.(total|vip)$');
final _structuredKey = RegExp(r'^(team|plan|pref)\.([a-z0-9][a-z0-9-]{0,47})$');
final _liveKey = RegExp(r'^l\.([1-9]\d{0,9})\.([0-9])$');

bool _integer(Object? value, int max) =>
    value is int && value >= 0 && value <= max;

/// Key grammar and value shape (`validEntry`).
bool validBoxEntry(String key, Object? value) {
  if (key.length > 64) return false;
  if (_cardKey.firstMatch(key) case final card?) {
    final field = card.group(3)!;
    if (const {'own', 'use', 'lock'}.contains(field)) {
      return value == null || value is bool;
    }
    if (const {'lvl', 'awk', 'rnk', 'sk', 'gsk'}.contains(field)) {
      return value == null || _integer(value, 1000000);
    }
    return false;
  }
  if (_accountKey.hasMatch(key) || _playerKey.hasMatch(key)) {
    return value == null || _integer(value, 2147483647);
  }
  if (_liveKey.hasMatch(key)) return value == null || _integer(value, 3);
  if (_structuredKey.hasMatch(key)) {
    if (value == null) return true;
    if (value is! Map && value is! List) return false;
    return utf8.encode(jsonEncode(value)).length <= 16 * 1024;
  }
  return false;
}

enum BoxSyncStatus {
  local,
  syncing,
  synced,
  pending,
  offline,
  signedOut,
  error,
}

class _Replica {
  _Replica(this.revision, this.entries, this.outbox);
  factory _Replica.empty() => _Replica(0, {}, []);
  factory _Replica.fromJson(Map<String, Object?> json) => _Replica(
    (json['revision'] as num?)?.toInt() ?? 0,
    {
      for (final entry in (json['entries'] as Map? ?? const {}).entries)
        '${entry.key}': BoxEntry.fromJson(
          (entry.value as Map).cast<String, Object?>(),
        ),
    },
    [
      for (final op in json['outbox'] as List? ?? const [])
        BoxOp.fromJson((op as Map).cast<String, Object?>()),
    ],
  );
  int revision;
  final Map<String, BoxEntry> entries;
  List<BoxOp> outbox;
  Map<String, Object?> toJson() => {
    'schema': 'haneoka-team-box-replica-v1',
    'revision': revision,
    'entries': {for (final e in entries.entries) e.key: e.value.toJson()},
    'outbox': [for (final op in outbox) op.toJson()],
  };
}

const _backoff = [1500, 4000, 10000, 30000, 60000];

/// Local-first replica of the box with background cloud sync.
class BoxStore extends ChangeNotifier {
  BoxStore(this.server) {
    _stores.add(this);
  }
  static final _stores = <BoxStore>{};
  static final _replicas = <(String, String?), _Replica>{};
  static final _writeVersions = <(String, String?), int>{};
  static Future<void> _writing = Future.value();
  final String server;
  final _account = HaneokaAccount.instance;
  _Replica _replica = _Replica.empty();
  String? _owner;
  bool _ownerKnown = false;
  String _client = '';
  int _clock = 0;
  BoxSyncStatus status = BoxSyncStatus.local;
  int version = 0;
  Timer? _flushTimer;
  Timer? _pullTimer;
  bool _inflight = false;
  int _failures = 0;
  bool _disposed = false;
  int _ownerGeneration = 0;

  Map<String, BoxEntry> get entries => _replica.entries;
  String? get owner => _owner;
  int get pending => _replica.outbox.length;

  Future<void> start() async {
    if (_disposed) return;
    final prefs = await SharedPreferences.getInstance();
    var client = prefs.getString('haneoka:team-box:client');
    if (client == null || !RegExp(r'^[A-Za-z0-9_-]{6,40}$').hasMatch(client)) {
      final random = math.Random.secure();
      client = [
        for (var i = 0; i < 24; i++)
          'abcdefghijklmnopqrstuvwxyz0123456789'[random.nextInt(36)],
      ].join();
      await prefs.setString('haneoka:team-box:client', client);
    }
    _client = client;
    if (_disposed) return;
    await _account.load();
    if (_disposed) return;
    await _useOwner(_ownerOfAccount());
    if (_disposed) return;
    _account.addListener(_accountChanged);
    _pullTimer = Timer.periodic(const Duration(seconds: 90), (_) => pull());
    await refresh();
  }

  String? _ownerOfAccount() =>
      _account.signedIn ? '${_account.user?['id'] ?? ''}' : null;

  void _accountChanged() {
    final owner = _ownerOfAccount();
    if (owner != _owner) {
      _useOwner(owner).then((_) => refresh());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ownerGeneration++;
    _stores.remove(this);
    _flushTimer?.cancel();
    _pullTimer?.cancel();
    _account.removeListener(_accountChanged);
    super.dispose();
  }

  Future<File> _file(String? owner) async {
    final dir = await getApplicationSupportDirectory();
    final who = owner == null
        ? 'anonymous'
        : 'account-${Uri.encodeComponent(owner)}';
    return File(p.join(dir.path, 'team-box', '$who-$server.json'));
  }

  Future<_Replica> _read(String? owner) async {
    try {
      await _writing;
      final file = await _file(owner);
      if (!await file.exists()) return _Replica.empty();
      final json = jsonDecode(await file.readAsString());
      if (json is! Map || json['schema'] != 'haneoka-team-box-replica-v1') {
        return _Replica.empty();
      }
      return _Replica.fromJson(json.cast<String, Object?>());
    } catch (_) {
      return _Replica.empty();
    }
  }

  /// Capture the owner and snapshot before queueing the device write.
  Future<void> _persist() {
    if (!_ownerKnown) return Future.value();
    final owner = _owner, key = (server, _owner);
    final version = (_writeVersions[key] ?? 0) + 1;
    _writeVersions[key] = version;
    final payload = jsonEncode(_replica.toJson());
    return _writing = _writing
        .then((_) async {
          if (_writeVersions[key] != version) return;
          final file = await _file(owner);
          await file.parent.create(recursive: true);
          final temp = File('${file.path}.tmp');
          await temp.writeAsString(payload, flush: true);
          await temp.rename(file.path);
        })
        .catchError((Object _) {});
  }

  void _observe(int time) => _clock = math.max(_clock, time);
  int _next() =>
      _clock = math.max(DateTime.now().millisecondsSinceEpoch, _clock + 1);

  Future<void> _useOwner(String? owner) async {
    final generation = ++_ownerGeneration;
    final previous = _owner;
    final wasKnown = _ownerKnown;
    _owner = owner;
    _ownerKnown = true;
    final key = (server, owner);
    var replica = _replicas[key];
    if (replica == null) {
      final loaded = await _read(owner);
      replica = _replicas.putIfAbsent(key, () => loaded);
    }
    if (_disposed || generation != _ownerGeneration) return;
    _replica = replica;
    for (final entry in _replica.entries.values) {
      _observe(entry.t);
    }
    // Signing in merges what was edited signed out; clocks decide every key.
    if (owner != null && wasKnown && previous == null) {
      final anonymous = await _read(null);
      if (_disposed || generation != _ownerGeneration) return;
      _applyMigration([
        for (final e in anonymous.entries.entries)
          BoxOp(e.key, e.value.v, e.value.t, e.value.c),
      ]);
    }
    _failures = 0;
    _setStatus(
      owner == null
          ? BoxSyncStatus.local
          : (_replica.outbox.isNotEmpty
                ? BoxSyncStatus.pending
                : BoxSyncStatus.syncing),
    );
    _changed();
  }

  void _applyMigration(List<BoxOp> ops) {
    final accepted = <BoxOp>[];
    for (final op in ops) {
      if (!validBoxEntry(op.k, op.v)) continue;
      if (!_newer((t: op.t, c: op.c), _replica.entries[op.k])) continue;
      _replica.entries[op.k] = BoxEntry(op.v, op.t, op.c, 0);
      _observe(op.t);
      accepted.add(op);
    }
    if (accepted.isEmpty) return;
    final keys = {for (final op in accepted) op.k};
    _replica.outbox = [
      ..._replica.outbox.where((op) => !keys.contains(op.k)),
      ...accepted,
    ];
    _persist();
    _scheduleFlush();
  }

  /// Applies local writes at once and queues them for the cloud.
  void set(List<(String, Object?)> changes) {
    final ops = <BoxOp>[];
    for (final (key, value) in changes) {
      if (!validBoxEntry(key, value)) {
        throw RangeError('invalid-box-entry:$key');
      }
      final current = _replica.entries[key];
      if (current != null && jsonEncode(current.v) == jsonEncode(value)) {
        continue;
      }
      final op = BoxOp(key, value, _next(), _client);
      _replica.entries[key] = BoxEntry(value, op.t, op.c, current?.r ?? 0);
      ops.add(op);
    }
    if (ops.isEmpty) return;
    final replaced = {for (final op in ops) op.k};
    _replica.outbox = [
      ..._replica.outbox.where((op) => !replaced.contains(op.k)),
      ...ops,
    ];
    _persist();
    _changed();
    _scheduleFlush();
  }

  Object? value(String key) => _replica.entries[key]?.v;

  /// Syncs both ways.
  Future<void> refresh() async {
    await pull();
    flush();
  }

  void _scheduleFlush() {
    if (_owner == null) return;
    _flushTimer?.cancel();
    _setStatus(BoxSyncStatus.pending);
    _flushTimer = Timer(const Duration(milliseconds: 700), flush);
  }

  Map<String, String> get _headers => {'X-Haneoka-Expected-User': _owner ?? ''};

  /// Sends the outbox.
  void flush() {
    _flushTimer?.cancel();
    final owner = _owner;
    if (owner == null || _replica.outbox.isEmpty || _disposed || _inflight) {
      return;
    }
    final sent = _replica.outbox.take(4000).toList();
    final since = _replica.revision;
    _inflight = true;
    _setStatus(BoxSyncStatus.syncing);
    () async {
      try {
        final body = await _account.request(
          'POST',
          '/api/v1/team-box/${Uri.encodeComponent(server)}',
          body: {
            'since': since,
            'ops': [for (final op in sent) op.toJson()],
          },
          headers: _headers,
        );
        if (owner != _owner) return;
        _receive(body);
        // Acknowledge exactly what was sent; edits made meanwhile stay queued.
        final acknowledged = {for (final op in sent) op.k: op.t};
        _replica.outbox = [
          for (final op in _replica.outbox)
            if (acknowledged[op.k] != op.t) op,
        ];
        _failures = 0;
        await _persist();
        _setStatus(
          _replica.outbox.isNotEmpty
              ? BoxSyncStatus.pending
              : BoxSyncStatus.synced,
        );
        if (_replica.outbox.isNotEmpty) _scheduleFlush();
      } on AccountError catch (error) {
        if (owner != _owner) return;
        _setStatus(
          error.code == 'unauthenticated' || error.code.startsWith('account_')
              ? BoxSyncStatus.signedOut
              : BoxSyncStatus.error,
        );
      } catch (_) {
        if (owner != _owner) return;
        _setStatus(BoxSyncStatus.offline);
        final delay = _backoff[math.min(_failures++, _backoff.length - 1)];
        _flushTimer?.cancel();
        _flushTimer = Timer(Duration(milliseconds: delay), flush);
      } finally {
        _inflight = false;
      }
    }();
  }

  Future<void> pull() async {
    final owner = _owner;
    if (owner == null || _disposed) return;
    try {
      final body = await _account.request(
        'GET',
        '/api/v1/team-box/${Uri.encodeComponent(server)}?since=${_replica.revision}',
        headers: _headers,
      );
      if (owner != _owner) return;
      _receive(body);
      await _persist();
      _setStatus(
        _replica.outbox.isNotEmpty
            ? BoxSyncStatus.pending
            : BoxSyncStatus.synced,
      );
    } on AccountError catch (error) {
      if (owner != _owner) return;
      _setStatus(
        error.code == 'unauthenticated' || error.code.startsWith('account_')
            ? BoxSyncStatus.signedOut
            : BoxSyncStatus.error,
      );
    } catch (_) {
      if (owner == _owner) _setStatus(BoxSyncStatus.offline);
    }
  }

  void _receive(Object? payload) {
    if (payload is! Map ||
        payload['revision'] is! num ||
        payload['entries'] is! Map) {
      throw const FormatException('invalid-box-response');
    }
    final revision = (payload['revision'] as num).toInt();
    // A server behind this replica (restored backup) gets everything again.
    if (revision < _replica.revision) {
      _replica.outbox = [
        for (final e in _replica.entries.entries)
          BoxOp(e.key, e.value.v, e.value.t, e.value.c),
      ];
    }
    var changed = false;
    for (final entry in (payload['entries'] as Map).entries) {
      final incoming = BoxEntry.fromJson(
        (entry.value as Map).cast<String, Object?>(),
      );
      _observe(incoming.t);
      final current = _replica.entries['${entry.key}'];
      if (current != null && !_newer((t: incoming.t, c: incoming.c), current)) {
        if (current.t == incoming.t &&
            current.c == incoming.c &&
            current.r < incoming.r) {
          current.r = incoming.r;
        }
        continue;
      }
      _replica.entries['${entry.key}'] = incoming;
      changed = true;
    }
    _replica.revision = revision;
    if (changed) _changed();
  }

  void _setStatus(BoxSyncStatus next) {
    if (status == next) return;
    status = next;
    _changed();
  }

  void _changed() {
    if (_disposed) return;
    for (final store in _stores.toList()) {
      if (store._disposed ||
          !store._ownerKnown ||
          store._owner != _owner ||
          !identical(store._replica, _replica)) {
        continue;
      }
      store._observe(_clock);
      store.version++;
      store.notifyListeners();
    }
  }
}

class OwnedMember {
  OwnedMember(this.cardId);
  final int cardId;
  bool use = true;
  bool lock = false;
  int? level;
  int? awake;
  int? rank;
  int? skill;
  int? gekisoSkill;
}

class OwnedSnap {
  OwnedSnap(this.cardId);
  final int cardId;
  bool use = true;
  bool lock = false;
  int? level;
  int? rank;
}

class SavedTeam {
  SavedTeam({
    required this.id,
    required this.name,
    required this.members,
    required this.snaps,
    required this.leader,
    required this.song,
    required this.createdAt,
    this.note,
  });
  final String id;
  final String name;
  final List<int> members;
  final List<int?> snaps;
  final int? leader;
  final SongRef? song;
  final String? note;
  final int createdAt;
  Map<String, Object?> toJson() => {
    'name': name,
    'members': members,
    'snaps': snaps,
    'leader': leader,
    'song': song?.toJson(),
    'note': ?note,
    'createdAt': createdAt,
  };
}

/// Typed reads of box entries (`box-view.ts`).
class BoxView {
  BoxView._(
    this.members,
    this.snaps,
    this.player,
    this.bandRanks,
    this.teams,
    this.prefs,
  );
  final Map<int, OwnedMember> members;
  final Map<int, OwnedSnap> snaps;
  final PlayerInput player;
  final Map<String, int?> bandRanks;
  final List<SavedTeam> teams;
  final Map<String, Object?> prefs;

  factory BoxView.read(Map<String, BoxEntry> entries) {
    final members = <int, OwnedMember>{};
    final snaps = <int, OwnedSnap>{};
    final characterRanks = <String, int?>{};
    final bandItems = <String, int?>{};
    final characterMemory = <String, int?>{};
    final musicMemory = <String, int?>{};
    int? vip;
    final bandRanks = <String, int?>{};
    final teams = <SavedTeam>[];
    final prefs = <String, Object?>{};
    final ownedMembers = <int>{}, ownedSnaps = <int>{};
    int? number(Object? value) => value is int ? value : null;
    for (final MapEntry(:key, value: entry) in entries.entries) {
      final parts = key.split('.');
      final head = parts.first;
      if (head == 'm' || head == 's') {
        final id = int.tryParse(parts.elementAtOrNull(1) ?? '') ?? 0;
        final field = parts.elementAtOrNull(2) ?? '';
        if (field == 'own') {
          if (entry.v == true) {
            (head == 'm' ? ownedMembers : ownedSnaps).add(id);
          }
          continue;
        }
        if (head == 'm') {
          final row = members[id] ??= OwnedMember(id);
          switch (field) {
            case 'use':
              row.use = entry.v != false;
            case 'lock':
              row.lock = entry.v == true;
            case 'lvl':
              row.level = number(entry.v);
            case 'awk':
              row.awake = number(entry.v);
            case 'rnk':
              row.rank = number(entry.v);
            case 'sk':
              row.skill = number(entry.v);
            case 'gsk':
              row.gekisoSkill = number(entry.v);
          }
        } else {
          final row = snaps[id] ??= OwnedSnap(id);
          switch (field) {
            case 'use':
              row.use = entry.v != false;
            case 'lock':
              row.lock = entry.v == true;
            case 'lvl':
              row.level = number(entry.v);
            case 'rnk':
              row.rank = number(entry.v);
          }
        }
      } else if (head == 'cr') {
        characterRanks[parts[1]] = number(entry.v);
      } else if (head == 'bi') {
        bandItems[parts[1]] = number(entry.v);
      } else if (head == 'br') {
        bandRanks[parts[1]] = number(entry.v);
      } else if (head == 'cm') {
        characterMemory[parts[1]] = number(entry.v);
      } else if (head == 'mm') {
        musicMemory[parts[1]] = number(entry.v);
      } else if (key == 'p.vip') {
        vip = number(entry.v);
      } else if (head == 'team' && entry.v is Map) {
        final value = (entry.v as Map).cast<String, Object?>();
        final song = value['song'];
        teams.add(
          SavedTeam(
            id: parts.skip(1).join('.'),
            name: '${value['name'] ?? ''}',
            members: [
              for (final id in value['members'] as List? ?? const [])
                (id as num).toInt(),
            ],
            snaps: [
              for (final id in value['snaps'] as List? ?? const [])
                (id as num?)?.toInt(),
            ],
            leader: (value['leader'] as num?)?.toInt(),
            song: song is Map
                ? SongRef.fromJson(song.cast<String, Object?>())
                : null,
            note: value['note'] is String ? value['note'] as String : null,
            createdAt: (value['createdAt'] as num?)?.toInt() ?? entry.t,
          ),
        );
      } else if (head == 'pref') {
        prefs[parts.skip(1).join('.')] = entry.v;
      }
    }
    members.removeWhere((id, _) => !ownedMembers.contains(id));
    snaps.removeWhere((id, _) => !ownedSnaps.contains(id));
    for (final id in ownedMembers) {
      members[id] ??= OwnedMember(id);
    }
    for (final id in ownedSnaps) {
      snaps[id] ??= OwnedSnap(id);
    }
    teams.sort((a, b) => b.createdAt - a.createdAt);
    return BoxView._(
      members,
      snaps,
      PlayerInput(
        characterRanks: characterRanks,
        characterTotalRank: null,
        bandItems: bandItems,
        vipRank: vip,
        characterMemory: characterMemory,
        musicMemory: musicMemory,
      ),
      bandRanks,
      teams,
      prefs,
    );
  }

  /// Engine inputs for the cards taking part (or all owned when [all]).
  ({List<MemberInput> members, List<SnapInput> snaps}) engineInputs([
    bool all = false,
  ]) => (
    members: [
      for (final row in members.values)
        if (all || row.use)
          MemberInput(
            key: 'm${row.cardId}',
            cardId: row.cardId,
            level: row.level,
            awake: row.awake,
            rank: row.rank,
            liveSkillLevel: row.skill,
            gekisoSkillLevel: row.gekisoSkill,
          ),
    ],
    snaps: [
      for (final row in snaps.values)
        if (all || row.use)
          SnapInput(
            key: 's${row.cardId}',
            cardId: row.cardId,
            level: row.level,
            rank: row.rank,
          ),
    ],
  );
}

int cardIdOf(String key) => int.parse(key.substring(1));
