import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../core/net.dart';
import '../save/game_save.dart';
import '../save/save_view.dart';

const _origin = 'https://haneoka.org';
const _tokenKey = 'haneoka-session';

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

/// The reader's Haneoka account in the app: a session of its own, obtained
/// through the website's sign-in (`/account/app/`, PKCE) and sent as a bearer
/// token, plus the Our Notes players linked to it.
class HaneokaAccount extends ChangeNotifier {
  HaneokaAccount._();
  static final HaneokaAccount instance = HaneokaAccount._();

  static const _storage = FlutterSecureStorage();

  String? _token;
  Map<String, Object?>? _user;
  List<LinkedPlayer> _players = const [];
  bool _loaded = false;

  bool get signedIn => _token != null && _user != null;
  Map<String, Object?>? get user => _user;

  /// The haneoka profile (`/api/v1/account/profile`): display name, handle,
  /// bio, public UID and its version.
  Map<String, Object?>? profile;

  /// Saves the profile's display name, handle and bio.
  Future<void> updateProfile({
    required String displayName,
    String? handle,
    String? bio,
  }) async {
    final body = await request(
      'PATCH',
      '/api/v1/account/profile',
      body: {
        'displayName': displayName.trim(),
        'handle': (handle?.trim().isEmpty ?? true) ? null : handle!.trim(),
        'bio': (bio?.trim().isEmpty ?? true) ? null : bio!.trim(),
        'version': profile?['version'],
      },
    );
    if ((body as Map?)?['profile'] case final Map updated) {
      profile = updated.cast<String, Object?>();
      _user = {
        ...?_user,
        if (updated['displayName'] case final String name when name.isNotEmpty)
          'name': name,
      };
      notifyListeners();
    }
  }

  List<LinkedPlayer> get players => _players;

  Future<void> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    final result = objectOf(
      await request(
        'POST',
        '/api/auth/change-password',
        body: {
          'currentPassword': currentPassword,
          'newPassword': newPassword,
          'revokeOtherSessions': true,
        },
      ),
    );
    if (result['token'] case final String token when token.isNotEmpty) {
      await _useSession(token);
    } else {
      await refresh();
    }
  }

  Future<void> deleteAccount(String confirmation) async {
    await request(
      'DELETE',
      '/api/v1/account/profile',
      body: {'confirmation': confirmation},
    );
    await _forget();
    notifyListeners();
  }

  /// The bearer header for requests made outside [request] (uploads).
  Map<String, String> get authorization => {
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  LinkedPlayer? linkOf(GameSave save) => _players
      .where(
        (p) =>
            p.server == save.release?.server && p.profileId == save.profileId,
      )
      .firstOrNull;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      _token = await _storage.read(key: _tokenKey);
    } catch (_) {
      _token = null;
    }
    if (_token == null) return;
    await refresh();
  }

  /// Reads the session and the linked players again.
  Future<void> refresh() async {
    if (_token == null) return;
    try {
      final session = await request('GET', '/api/auth/get-session');
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
      await _readPlayers();
    } on AccountError catch (error) {
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

  /// Email and password sign-in, straight against the website's account
  /// service; the session it returns is this app's bearer session.
  Future<void> signInWithEmail(String email, String password) async {
    final body = objectOf(
      await request(
        'POST',
        '/api/auth/sign-in/email',
        body: {'email': email, 'password': password, 'rememberMe': true},
        authorized: false,
      ),
    );
    final session = body['token'];
    if (session is! String) throw const AccountError('invalid_grant');
    await _useSession(session);
  }

  /// Email-only registration: the website mails a link to set the password.
  Future<void> register(String email) => request(
    'POST',
    '/api/v1/account/register',
    body: {'email': email},
    authorized: false,
  );

  Future<void> requestPasswordReset(String email) => request(
    'POST',
    '/api/auth/request-password-reset',
    body: {'email': email, 'redirectTo': '/account/reset-password'},
    authorized: false,
  );

  Future<void> _useSession(String session) async {
    _token = session;
    try {
      await _storage.write(key: _tokenKey, value: session);
    } catch (_) {
      // Without a keychain the session lasts until the app closes.
    }
    await refresh();
  }

  /// Provider sign-in: the provider's own page opens in the system browser
  /// and hands a one-time code back to the app (PKCE), with no website page
  /// in between.
  Future<void> signInWithProvider(String provider) async {
    final random = Random.secure();
    String token(int bytes) => base64Url
        .encode(List.generate(bytes, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    final verifier = token(48);
    final state = token(16);
    final challenge = challengeOf(verifier);
    final query = <String, String>{'challenge': challenge, 'state': state};
    final returned = Completer<Uri>();
    HttpServer? loopback;
    StreamSubscription<Uri>? links;
    if (Platform.isAndroid || Platform.isIOS) {
      // The website hands the code back to `haneoka://auth`.
      links = AppLinks().uriLinkStream.listen((uri) {
        if (uri.scheme == 'haneoka' &&
            uri.host == 'auth' &&
            !returned.isCompleted) {
          returned.complete(uri);
        }
      });
    } else {
      // Desktop builds receive it on a loopback listener (RFC 8252).
      loopback = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      query['redirect'] = 'http://127.0.0.1:${loopback.port}/auth';
      loopback.listen((request) async {
        if (request.uri.path != '/auth') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<!doctype html><meta charset="utf-8"><title>Haneoka</title>'
          '<body style="font:16px system-ui;text-align:center;padding:48px">'
          '&#10003;</body>',
        );
        await request.response.close();
        if (!returned.isCompleted) returned.complete(request.uri);
      });
    }
    final Uri result;
    try {
      final opened = await launchUrl(
        Uri.parse('$_origin/api/v1/account/app/oauth')
            .replace(queryParameters: {...query, 'provider': provider}),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) throw const AccountError('cancelled');
      result = await returned.future.timeout(const Duration(minutes: 10));
    } on TimeoutException {
      throw const AccountError('cancelled');
    } finally {
      await links?.cancel();
      await loopback?.close(force: true);
    }
    final callback = result.queryParameters;
    if (callback['state'] != state) throw const AccountError('invalid_state');
    final code = callback['code'];
    if (code == null) throw AccountError(callback['error'] ?? 'cancelled');
    final body = await request(
      'POST',
      '/api/v1/account/app/token',
      body: {'code': code, 'verifier': verifier},
      authorized: false,
    );
    final session = (body as Map?)?['token'];
    if (session is! String) throw const AccountError('invalid_grant');
    await _useSession(session);
  }

  Future<void> signOut() async {
    try {
      await request('POST', '/api/auth/sign-out', body: const {});
    } catch (_) {
      // The session is forgotten here either way.
    }
    await _forget();
    notifyListeners();
  }

  /// Links [save]'s player, or updates its summary and visibility.
  Future<void> link(GameSave save, {bool? public}) async {
    final view = SaveView(save);
    final current = linkOf(save);
    final body = await request(
      'PUT',
      '/api/v1/account/game-accounts',
      body: {
        'server': save.release?.server,
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
      '/api/v1/account/game-accounts/${save.release?.server}/${save.profileId}',
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
    try {
      await _storage.delete(key: _tokenKey);
    } catch (_) {}
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
    final request = http.Request(method, Uri.parse('$_origin$path'))
      ..headers.addAll({
        'Accept': 'application/json',
        'Origin': _origin,
        if (authorized && _token != null) 'Authorization': 'Bearer $_token',
        if (body != null) 'Content-Type': 'application/json',
        ...headers,
      });
    if (body != null) request.body = jsonEncode(body);
    if (bytes != null) request.bodyBytes = bytes;
    final response = await http.Response.fromStream(
      await netClient.send(request),
    );
    if (authorized && (owner != _user?['id'] || token != _token)) {
      throw const AccountError('session_changed');
    }
    final text = utf8.decode(response.bodyBytes);
    final json = text.isEmpty ? null : jsonDecode(text);
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
