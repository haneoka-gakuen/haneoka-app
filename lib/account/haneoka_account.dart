import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/net.dart';
import '../core/site_origin.dart';
import '../save/game_save.dart';
import '../save/save_view.dart';

/// A player linked to the Haneoka account (`community_game_account`).
class LinkedPlayer {
  const LinkedPlayer({
    required this.server,
    required this.profileId,
    required this.visibility,
    this.name,
    this.syncedAt,
  });
  final String server;
  final String profileId;
  final String? name;
  final String visibility;
  final DateTime? syncedAt;

  bool get public => visibility == 'public';

  static LinkedPlayer? fromJson(Object? json) {
    if (json is! Map) return null;
    final synced = json['lastSyncedAt'];
    return LinkedPlayer(
      server: '${json['region']}',
      profileId: '${json['playerUid']}',
      name: json['displayName'] as String?,
      visibility: '${json['visibility'] ?? 'private'}',
      syncedAt: synced is num
          ? DateTime.fromMillisecondsSinceEpoch(synced.toInt())
          : null,
    );
  }
}

/// Why a request to the account API failed.
class AccountError implements Exception {
  const AccountError(this.code);
  final String code;
  @override
  String toString() => 'AccountError($code)';
}

/// The reader's Haneoka account in the app: the website's own session, read
/// from the web view's cookies so native screens are always signed in exactly
/// when the site is, plus the Our Notes players linked to it.
class HaneokaAccount extends ChangeNotifier {
  HaneokaAccount._() {
    SiteOrigin.instance.addListener(() {
      _token = null;
      _user = null;
      profile = null;
      _players = const [];
      notifyListeners();
    });
  }
  static final HaneokaAccount instance = HaneokaAccount._();

  /// The web view's cookies for the site, provided by the web shell.
  static Future<String?> Function()? siteCookies;

  /// The `Cookie` header carrying the site's session.
  String? _token;
  Map<String, Object?>? _user;
  List<LinkedPlayer> _players = const [];
  bool _loaded = false;

  bool get signedIn => _user != null;
  Map<String, Object?>? get user => _user;

  /// The haneoka profile (`/api/v1/account/profile`): display name, handle,
  /// bio, public UID and its version.
  Map<String, Object?>? profile;

  List<LinkedPlayer> get players => _players;

  /// The session cookie for requests made outside [request] to the site.
  Map<String, String> get authorization => {
    if (_token != null) 'Cookie': _token!,
  };

  LinkedPlayer? linkOf(GameSave save) => _players
      .where((p) => p.server == save.server && p.profileId == save.profileId)
      .firstOrNull;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    await refresh();
  }

  /// Reads the session and the linked players again.
  Future<void> refresh() async {
    final origin = SiteOrigin.instance.value;
    final token = await siteCookies?.call();
    if (origin != SiteOrigin.instance.value) return;
    _token = token;
    if (_token == null || _token!.isEmpty) {
      if (_user != null) {
        await _forget();
        notifyListeners();
      }
      return;
    }
    try {
      final session = await request('GET', '/api/auth/get-session');
      if (origin != SiteOrigin.instance.value) return;
      final user = (session as Map?)?['user'];
      if (user is! Map) {
        await _forget();
        return;
      }
      _user = user.cast<String, Object?>();
      try {
        final profile = (await request(
          'GET',
          '/api/v1/account/profile',
        ) as Map?)?['profile'];
        if (origin != SiteOrigin.instance.value) return;
        if (profile is Map) {
          this.profile = profile.cast<String, Object?>();
          _user = {
            ..._user!,
            'uid': profile['publicUid'],
            if (profile['displayName'] case final String name
                when name.isNotEmpty)
              'name': name,
            if (profile['avatarUrl'] case final String avatar) 'image': avatar,
          };
        }
      } on AccountError {
        // A profile not set up yet still signs in.
      }
      if (origin != SiteOrigin.instance.value) return;
      await _readPlayers();
    } on AccountError catch (error) {
      if (origin != SiteOrigin.instance.value) return;
      if (error.code == 'unauthenticated') await _forget();
    } catch (_) {
      // Offline: keep the stored session for next time.
    }
    notifyListeners();
  }

  /// The sign-in methods the website offers (`/api/v1/account/config`).
  Future<({bool available, bool signUp, List<String> providers})>
  config() async {
    final body = objectOf(
      await request('GET', '/api/v1/account/config', authorized: false),
    );
    return (
      available: body['available'] != false,
      signUp:
          body['emailSignUpEnabled'] != false &&
          body['emailDeliveryEnabled'] != false,
      providers: [
        for (final provider in body['providers'] as List? ?? const [])
          '$provider',
      ],
    );
  }

  /// Links [save]'s player, or updates its summary and visibility.
  Future<void> link(GameSave save, {bool? public}) async {
    final view = SaveView(save);
    final current = linkOf(save);
    final body = await request(
      'PUT',
      '/api/v1/account/game-accounts',
      body: {
        'server': save.server,
        'profileId': save.profileId,
        'name': save.name,
        'visibility': (public ?? current?.public ?? true)
            ? 'public'
            : 'private',
        'savedAt': save.modifiedAt?.millisecondsSinceEpoch,
        'summary': summaryOf(view),
      },
    );
    _readPlayersFrom(body);
  }

  /// Updates an already linked player after a new import.
  Future<void> syncIfLinked(GameSave save) async {
    if (!signedIn || linkOf(save) == null) return;
    try {
      await link(save);
    } catch (_) {
      // The next update from the player's page retries.
    }
  }

  Future<void> unlink(GameSave save) async {
    final body = await request(
      'DELETE',
      '/api/v1/account/game-accounts/${save.server}/${save.profileId}',
    );
    _readPlayersFrom(body);
  }

  /// The public numbers a linked player shows; never the save itself.
  static Map<String, Object?> summaryOf(SaveView view) {
    int count(String difficulty, int threshold) => view
        .rows(SaveSection.songs)
        .where(
          (row) =>
              ((row['_${difficulty}ClearedStatus'] as num?) ?? 0) >= threshold,
        )
        .length;
    final started = view.player['_tutorialFinishedAtUnixSeconds'];
    return {
      'rank': view.playerRank,
      'exp': view.exp,
      'rating': view.highScoreRating,
      'members': view.rows(SaveSection.memberCards).length,
      'snapshots': view.rows(SaveSection.snapshots).length,
      'favoriteMemberCardId': view.favoriteMemberCardId,
      'startedAt': started is num && started > 0 ? started.toInt() : null,
      'clears': {
        for (final difficulty in const ['easy', 'normal', 'hard', 'expert'])
          difficulty: [
            count(difficulty, 10),
            count(difficulty, 20),
            count(difficulty, 30),
          ],
      },
    };
  }

  Future<void> _readPlayers() async =>
      _readPlayersFrom(await request('GET', '/api/v1/account/game-accounts'));

  void _readPlayersFrom(Object? body) {
    _players = [
      for (final row in ((body as Map?)?['accounts'] as List? ?? const []))
        ?LinkedPlayer.fromJson(row),
    ];
    notifyListeners();
  }

  Future<void> _forget() async {
    _token = null;
    _user = null;
    profile = null;
    _players = const [];
  }

  Future<Object?> request(
    String method,
    String path, {
    Object? body,
    List<int>? bytes,
    bool authorized = true,
    Map<String, String> headers = const {},
  }) async {
    final owner = _user?['id'], token = _token;
    final origin = SiteOrigin.instance.value.origin;
    final request = http.Request(method, Uri.parse('$origin$path'))
      ..headers.addAll({
        'Accept': 'application/json',
        'Origin': origin,
        if (authorized && _token != null) 'Cookie': _token!,
        if (body != null) 'Content-Type': 'application/json',
        ...headers,
      });
    if (body != null) request.body = jsonEncode(body);
    if (bytes != null) request.bodyBytes = bytes;
    final response = await http.Response.fromStream(
      await netClient.send(request),
    ).timeout(const Duration(seconds: 30));
    if (origin != SiteOrigin.instance.value.origin ||
        (authorized && (owner != _user?['id'] || token != _token))) {
      throw const AccountError('session_changed');
    }
    Object? json;
    try {
      final text = utf8.decode(response.bodyBytes);
      json = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      // Gateway and challenge pages answer in HTML.
      throw AccountError(
        response.statusCode >= 400
            ? 'http_${response.statusCode}'
            : 'invalid_response',
      );
    }
    if (response.statusCode >= 400) {
      // Haneoka's API nests `{error: {code}}`; the account service answers
      // `{code, message}`.
      final error = (json as Map?)?['error'];
      final code = error is Map ? error['code'] : json?['code'];
      if (response.statusCode == 401 && (code == null || error is Map)) {
        throw const AccountError('unauthenticated');
      }
      throw AccountError(
        code != null
            ? '$code'
            : response.statusCode == 429
            ? 'too_many_requests'
            : 'http_${response.statusCode}',
      );
    }
    return json;
  }

  static String challengeOf(String verifier) => base64Url
      .encode(sha256.convert(ascii.encode(verifier)).bytes)
      .replaceAll('=', '');
}

Map<String, Object?> objectOf(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const {};
