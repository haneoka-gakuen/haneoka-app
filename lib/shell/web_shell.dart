import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_all_android/webview_all_android.dart';
import 'package:webview_all_windows/webview_all_windows.dart';

import '../ui/game_account_sheet.dart';
import '../ui/import_screen.dart';
import '../account/haneoka_account.dart';
import '../core/app_state.dart';
import '../core/site_origin.dart';
import '../save/game_save.dart';
import '../save/save_view.dart';
import '../save/song_marks.dart';
import '../ui/save_screen.dart';
import '../gacha_history/game_history_client.dart';
import '../gacha_history/history_read.dart';
import '../save/account_store.dart';
import '../save/export.dart';
import '../save/player_refresh.dart';
import 'bridge_script.dart';
import 'launch.dart';
import 'page_theme.dart';
import 'pending_import.dart';
import 'site.dart';
import 'sign_in.dart';
import 'strings.dart';

Uri get origin => SiteOrigin.instance.value;

/// The whole app: the live website, with native bars in its colours and the
/// app-only work (game accounts, game-server reads, provider sign-in, file
/// saving) answered over the bridge.
class WebShell extends StatefulWidget {
  const WebShell({super.key, required this.theme});
  final ValueNotifier<PageTheme> theme;
  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> {
  WebViewController? _web;
  WebViewController get _controller => _web!;
  bool _initialized = false;
  Future<void>? _starting;
  int _attempt = 0;
  int _document = 0;
  int _loadSerial = 0;
  Uri? _requestedPage;
  bool _isRequestedPage(Uri page) =>
      page.origin == _requestedPage?.origin &&
      page.path == _requestedPage?.path &&
      page.query == _requestedPage?.query;
  Timer? _deadline;
  Timer? _readiness;
  bool _checkingLoaded = false;
  final Set<String> _triedOrigins = {};
  String? _lastFailure;
  String _version = '';
  final _links = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;
  bool _loaded = false;
  bool _httpFailed = false;
  bool _launchVisible = true;

  /// The main frame's load error, shown on the launch page with Retry.
  String? _error;
  int _progress = 0;
  bool _slow = false;
  bool _fullscreen = false;
  Timer? _slowTimer;
  // ignore: unused_field
  NavigationDelegate? _navigation;

  PageTheme get _theme => widget.theme.value;
  Strings get _t => _theme.locale == null
      ? Strings.of(PlatformDispatcher.instance.locale)
      : Strings.forTag(_theme.locale!);

  @override
  void initState() {
    super.initState();
    SiteLinks.load = _loadPage;
    AccountStore.instance.addListener(_accountsChanged);
    HaneokaAccount.siteCookies = _siteCookies;
    unawaited(
      WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) async {
        if (mounted) await _start();
      }),
    );
  }

  @override
  void dispose() {
    SiteLinks.load = null;
    AccountStore.instance.removeListener(_accountsChanged);
    HaneokaAccount.siteCookies = null;
    _slowTimer?.cancel();
    _deadline?.cancel();
    _readiness?.cancel();
    _attempt++;
    _linkSubscription?.cancel();
    super.dispose();
  }

  Future<void> _start() => _starting ??= _startAttempt().whenComplete(() {
    _starting = null;
  });

  Future<void> _startAttempt() async {
    final attempt = ++_attempt;
    _initialized = false;
    _startLoading();
    try {
      await _configure(attempt).timeout(const Duration(seconds: 20));
    } catch (error, stack) {
      debugPrint('WebView startup: $error\n$stack');
      _lastFailure =
          'initialization: ${error is PlatformException ? error.code : error.runtimeType}';
      if (mounted && attempt == _attempt) {
        _attempt++;
        _initialized = false;
        _fail(_t['webviewFailed'], tryAlternative: false);
      }
    }
  }

  Future<void> _configure(int attempt) async {
    bool active() => mounted && attempt == _attempt;
    final controller = WebViewController();
    if (!active()) return;
    setState(() => _web = controller);
    final info = await PackageInfo.fromPlatform();
    _version = info.version;
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setBackgroundColor(_theme.background);
    final agent = await controller.getUserAgent();
    if (agent != null && agent.trim().isNotEmpty) {
      await controller.setUserAgent('$agent HaneokaApp/${info.version}');
    }
    final random = Random.secure();
    final token = base64UrlEncode(
      List.generate(32, (_) => random.nextInt(256)),
    );
    await controller.addJavaScriptChannel(
      bridgeChannel,
      onMessageReceived: (message) {
        if (active()) unawaited(_message(message, token));
      },
    );
    final script = bridgeScript(
      version: info.version,
      platform: Platform.operatingSystem,
      token: token,
      origins: SiteOrigin.instance.origins.map((site) => site.origin).toList(),
    );
    final userScript = await controller.isUserScriptInjectionSupported(
      WebViewUserScriptInjectionTime.documentStart,
    );
    if (userScript) {
      await controller.addUserScript(WebViewUserScript(source: script));
    }
    if (controller.platform case final AndroidWebViewController android) {
      await AndroidWebViewController.enableDebugging(kDebugMode);
      await android.setMediaPlaybackRequiresUserGesture(false);
      await android.setOnShowFileSelector(_chooseFiles);
    }
    if (!active()) return;
    // The Android plugin keeps only a weak reference to the delegate.
    await controller.setNavigationDelegate(
      _navigation = NavigationDelegate(
        onNavigationRequest: (request) =>
            active() ? _navigate(request) : NavigationDecision.prevent,
        onPageStarted: (url) {
          if (!active()) return;
          final page = Uri.tryParse(url);
          if (!SiteOrigin.instance.contains(page) ||
              page!.origin != origin.origin) {
            return;
          }
          if (_loaded) {
            _lastFailure = null;
            _triedOrigins
              ..clear()
              ..add(page.origin);
          }
          _document++;
          _requestedPage = page;
          _loaded = false;
          _httpFailed = false;
          _startLoading();
          if (!userScript) _inject(script);
        },
        onUrlChange: (change) {
          if (!active()) return;
          final page = Uri.tryParse(change.url ?? '');
          if (SiteOrigin.instance.contains(page) &&
              page!.origin == origin.origin) {
            _requestedPage = page;
          }
        },
        onProgress: (progress) {
          if (!active() || _loaded || _error != null) return;
          setState(() => _progress = progress);
          if (progress == 100) {
            _inject(script);
            unawaited(_checkLoaded());
          }
        },
        onPageFinished: (url) {
          if (!active()) return;
          _readSession(url);
          final server = Uri.tryParse(url)?.pathSegments.firstOrNull;
          if (server == 'jp' || server == 'intl') {
            AppScope.of(context).setServer(server!);
          }
          _inject(script);
          unawaited(_checkLoaded());
        },
        onWebResourceError: (error) {
          if (!active() || error.isForMainFrame == false) return;
          final failedPage = Uri.tryParse(error.url ?? '');
          if (SiteOrigin.instance.contains(failedPage) &&
              failedPage!.origin != origin.origin) {
            return;
          }
          if (error.isForMainFrame == true) {
            _lastFailure =
                'web ${error.errorCode}: ${error.errorType?.name ?? 'unknown'}';
            _fail(
              error.description.isEmpty
                  ? 'Error ${error.errorCode}'
                  : error.description,
            );
          } else if (!_loaded) {
            unawaited(_checkLoaded());
          }
        },
        onHttpError: (error) {
          if (!active() || error.request?.uri != _requestedPage) return;
          final status = error.response?.statusCode;
          _httpFailed = true;
          _lastFailure = 'HTTP $status';
          _fail(
            'HTTP ${status ?? ''}'.trim(),
            tryAlternative: status == 408 || (status != null && status >= 500),
          );
        },
      ),
    );
    final initial = await _links.getInitialLink().timeout(
      const Duration(seconds: 3),
      onTimeout: () => null,
    );
    if (!active()) return;
    _initialized = true;
    _requestedPage ??= _page(initial) ?? _home;
    await _linkSubscription?.cancel();
    if (!active()) return;
    _linkSubscription = _links.uriLinkStream.listen((uri) {
      if (uri.scheme == 'haneoka' && uri.host == 'saves') {
        _openSaves();
      } else if (_page(uri) case final page?) {
        unawaited(_loadPage(page));
      }
    });
    unawaited(_loadPage(_requestedPage!, resetOrigins: false));
    if (initial?.scheme == 'haneoka' && initial?.host == 'saves') _openSaves();
  }

  void _inject(String script) {
    unawaited(
      _controller.runJavaScript(script).catchError((Object error) {
        debugPrint('Page bridge: $error');
      }),
    );
  }

  Future<void> _checkLoaded() async {
    if (_checkingLoaded || !_initialized || _loaded || _web == null) return;
    _checkingLoaded = true;
    final attempt = _attempt, document = _document;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted ||
          _loaded ||
          _web == null ||
          attempt != _attempt ||
          document != _document) {
        return;
      }
      Object? answer = await _controller
          .runJavaScriptReturningResult(
            'JSON.stringify({url:location.href,locale:document.documentElement.dataset.locale || "",'
            'main:!!document.querySelector("main"),ready:document.readyState,'
            'status:performance.getEntriesByType("navigation")[0]?.responseStatus || 0,'
            'error:(document.body?.innerText.match(/net::ERR_[A-Z_]+/) || [""])[0]})',
          )
          .timeout(const Duration(seconds: 3));
      for (var i = 0; i < 2 && answer is String; i++) {
        answer = jsonDecode(answer);
      }
      if (!mounted ||
          _loaded ||
          attempt != _attempt ||
          document != _document ||
          answer is! Map) {
        return;
      }
      final page = Uri.tryParse('${answer['url'] ?? ''}');
      if (!SiteOrigin.instance.contains(page) ||
          page!.origin != origin.origin ||
          !_isRequestedPage(page)) {
        return;
      }
      final status = answer['status'];
      if (status is num && status >= 400) {
        _httpFailed = true;
        _lastFailure = 'HTTP $status';
        _fail('HTTP $status', tryAlternative: status == 408 || status >= 500);
        return;
      }
      if (answer['locale'] != '' && answer['main'] == true) {
        _showPage();
      } else if ('${answer['error'] ?? ''}'.isNotEmpty) {
        _fail('${answer['error']}');
      }
    } catch (error) {
      debugPrint('Page readiness: $error');
    } finally {
      _checkingLoaded = false;
    }
  }

  void _showPage() {
    if (_loaded || _httpFailed || !mounted) return;
    _slowTimer?.cancel();
    _deadline?.cancel();
    _readiness?.cancel();
    setState(() {
      _loaded = true;
      _error = null;
    });
    unawaited(
      SiteOrigin.instance.remember().catchError((Object error) {
        debugPrint('Site preference: $error');
      }),
    );
  }

  void _fail(String error, {bool tryAlternative = true}) {
    if (!mounted) return;
    final page = _requestedPage;
    final next = SiteOrigin.instance.untried(_triedOrigins);
    if (tryAlternative && _initialized && page != null && next != null) {
      _lastFailure ??= error;
      setState(() => _launchVisible = true);
      unawaited(
        _loadPage(SiteOrigin.instance.at(next, page), resetOrigins: false),
      );
      return;
    }
    _slowTimer?.cancel();
    _deadline?.cancel();
    _readiness?.cancel();
    setState(() {
      _error = error;
      _loaded = false;
      _launchVisible = true;
    });
  }

  void _startLoading() {
    _slowTimer?.cancel();
    _deadline?.cancel();
    _readiness?.cancel();
    _readiness = Timer.periodic(const Duration(milliseconds: 750), (_) {
      unawaited(_checkLoaded());
    });
    _slow = false;
    _slowTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && !_loaded) setState(() => _slow = true);
    });
    final attempt = _attempt, document = _document;
    _deadline = Timer(const Duration(seconds: 30), () async {
      await _checkLoaded();
      if (mounted && !_loaded && attempt == _attempt && document == _document) {
        _lastFailure ??= 'document readiness timeout';
        _fail(_t['loadTimeout']);
      }
    });
  }

  Future<void> _loadPage(Uri page, {bool resetOrigins = true}) async {
    final serial = ++_loadSerial;
    if (resetOrigins) {
      _triedOrigins.clear();
      _lastFailure = null;
    }
    _triedOrigins.add(page.origin);
    SiteOrigin.instance.select(page);
    _requestedPage = page;
    if (!_initialized) {
      await _start();
      return;
    }
    final attempt = _attempt;
    setState(() {
      _error = null;
      _progress = 0;
      _loaded = false;
      _httpFailed = false;
    });
    _document++;
    _startLoading();
    try {
      await _controller.loadRequest(page).timeout(const Duration(seconds: 15));
    } catch (error) {
      debugPrint('Page navigation: $error');
      if (mounted && attempt == _attempt && serial == _loadSerial) {
        _lastFailure = 'navigation: ${error.runtimeType}';
        _fail(_t.format('offline', {'host': origin.host}));
      }
    }
  }

  Future<void> _retry() async {
    _lastFailure = null;
    _triedOrigins.clear();
    setState(() {
      _error = null;
      _progress = 0;
    });
    if (!_initialized) {
      await _start();
    } else {
      await _loadPage(_requestedPage ?? _home);
    }
  }

  Future<void> _switchSite() async {
    final next = SiteOrigin.instance.alternative;
    if (next == null) return;
    _lastFailure = null;
    _triedOrigins
      ..clear()
      ..addAll(SiteOrigin.instance.origins.map((site) => site.origin));
    await _loadPage(
      SiteOrigin.instance.at(next, _requestedPage ?? _home),
      resetOrigins: false,
    );
  }

  Future<void> _copyDiagnostics() async {
    String? runtime;
    if (Platform.isWindows) {
      try {
        runtime = await WindowsWebViewController.getWebViewVersion().timeout(
          const Duration(seconds: 3),
        );
      } catch (_) {}
    }
    final page = _requestedPage ?? _home;
    final address = page.toString().split(RegExp(r'[?#]')).first;
    await Clipboard.setData(
      ClipboardData(
        text: [
          'Haneoka $_version',
          'Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
          if (runtime != null) 'WebView2: $runtime',
          'Page: $address',
          'Attempted: ${_triedOrigins.join(', ')}',
          'Progress: $_progress',
          'Failure: ${_lastFailure ?? _error ?? 'none'}',
        ].join('\n'),
      ),
    );
    if (mounted) _say(_t['copied']);
  }

  /// The site's cookies in the web view, for native requests that act as the
  /// signed-in reader.
  Future<String?> _siteCookies() async {
    try {
      final platform = WebViewCookieManager().platform as dynamic;
      final cookies = await platform.getCookies(origin) as List<WebViewCookie>;
      return cookies
          .map((cookie) => '${cookie.name}=${cookie.value}')
          .join('; ');
    } catch (_) {
      return null;
    }
  }

  DateTime _sessionRead = DateTime(0);

  /// Follows the site's sign-in: after account pages, and now and then.
  void _readSession(String url) {
    final now = DateTime.now();
    if (!url.contains('/account') &&
        now.difference(_sessionRead) < const Duration(minutes: 1)) {
      return;
    }
    _sessionRead = now;
    unawaited(HaneokaAccount.instance.refresh());
  }

  Uri get _home => origin.replace(
    path: '/${Strings.tag(PlatformDispatcher.instance.locale)}/',
  );

  /// The website page a link opens: haneoka.org links as they are, the old
  /// app's `haneoka://gacha-history` as the page.
  Uri? _page(Uri? link) {
    if (link == null) return null;
    if (SiteOrigin.instance.contains(link)) {
      return SiteOrigin.instance.local(link);
    }
    if (link.scheme == 'haneoka' && link.host == 'gacha-history') {
      return _home.resolve('gacha-history/');
    }
    return null;
  }

  FutureOr<NavigationDecision> _navigate(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    if (uri == null || !request.isMainFrame) return NavigationDecision.navigate;
    if (SiteOrigin.instance.contains(uri)) {
      final page = SiteOrigin.instance.local(uri);
      if (page != uri) {
        unawaited(_loadPage(page));
        return NavigationDecision.prevent;
      }
      return NavigationDecision.navigate;
    }
    if (const {'about', 'blob', 'data', 'javascript'}.contains(uri.scheme)) {
      return NavigationDecision.navigate;
    }
    if (uri.scheme != 'haneoka') {
      unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
    } else if (uri.host == 'saves') {
      _openSaves();
    }
    return NavigationDecision.prevent;
  }

  static String _saveKey(GameSave save) => '${save.server}-${save.profileId}';

  Future<List<Map<String, Object?>>> _gameAccounts() async {
    await AccountStore.instance.load();
    return [
      for (final save in AccountStore.instance.saves)
        {
          'key': _saveKey(save),
          'name': save.name,
          'profileId': save.profileId,
          'region': save.regionName,
          'rank': SaveView(save).playerRank,
          'savedAt': save.modifiedAt?.millisecondsSinceEpoch,
        },
    ];
  }

  Object? _openGameAccount(String key) {
    final save = AccountStore.instance.saves
        .where((save) => _saveKey(save) == key)
        .firstOrNull;
    if (save != null) {
      Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => SaveScreen(save: save)));
    }
    return null;
  }

  Object? _addGameAccount() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const ImportScreen()));
    return null;
  }

  /// The site's account page lists the device's saves; it hears of changes.
  void _accountsChanged() {
    if (!_initialized) return;
    unawaited(
      _controller
          .runJavaScript('dispatchEvent(new Event("haneoka-app-accounts"))')
          .catchError((Object error) {
            debugPrint('Account notification: $error');
          }),
    );
  }

  /// The game accounts read on this device and how to read more; works
  /// without the website.
  void _openSaves() => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const AccountsScreen()));

  Future<List<String>> _chooseFiles(FileSelectorParams params) async {
    final images =
        params.acceptTypes.isNotEmpty &&
        params.acceptTypes.every((type) => type.startsWith('image/'));
    final picked = await FilePicker.pickFiles(
      type: images ? FileType.image : FileType.any,
    );
    final files = params.mode == FileSelectorMode.openMultiple
        ? picked
        : picked.take(1);
    return [
      for (final file in files)
        if (file.path case final path?) Uri.file(path).toString(),
    ];
  }

  void _say(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  Future<void> _message(JavaScriptMessage incoming, String token) async {
    if (incoming.isMainFrame == false || incoming.sourceOrigin == 'null') {
      return;
    }
    final document = _document;
    final Map<String, Object?> message;
    try {
      final decoded = jsonDecode(incoming.message);
      if (decoded is! Map) return;
      message = decoded.cast<String, Object?>();
    } on FormatException {
      return;
    }
    if (message['bridge'] != token) return;
    final page = Uri.tryParse('${message['page'] ?? ''}');
    if (!SiteOrigin.instance.contains(page) || page!.origin != origin.origin) {
      return;
    }
    if (incoming.sourceUrl case final source?) {
      final uri = Uri.tryParse(source);
      if (!SiteOrigin.instance.contains(uri) || uri!.origin != page.origin) {
        return;
      }
    }
    if (incoming.sourceOrigin != null && incoming.sourceOrigin != page.origin) {
      return;
    }
    final status = message['status'];
    if (status is num && status >= 400) {
      _httpFailed = true;
      _lastFailure = 'HTTP $status';
      _fail('HTTP $status', tryAlternative: status == 408 || status >= 500);
      return;
    }
    final args = (message['args'] as Map?)?.cast<String, Object?>() ?? {};
    switch (message['method']) {
      case 'painted':
        if (_isRequestedPage(page)) _showPage();
        return;
      case 'theme':
        if (PageTheme.read(args, _theme) case final theme?) {
          if (_isRequestedPage(page)) _showPage();
          final state = AppScope.of(context);
          if (theme.locale case final locale?) {
            unawaited(state.setLocale(locale));
          }
          final backgroundChanged = theme.background != _theme.background;
          widget.theme.value = theme;
          if (backgroundChanged) {
            unawaited(_controller.setBackgroundColor(theme.background));
          }
        }
        return;
      case 'download':
        return _download(args);
      case 'fullscreen':
        return _setFullscreen(args['active'] == true);
      case 'orientation':
        return SystemChrome.setPreferredOrientations(
          switch (args['orientation']) {
            final String value when value.startsWith('landscape') => const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ],
            final String value when value.startsWith('portrait') => const [
              DeviceOrientation.portraitUp,
            ],
            _ => const [],
          },
        );
    }
    final id = message['id'];
    if (id is! int) return;
    Object? value;
    String? error;
    try {
      value = switch (message['method']) {
        'boxAccount' => await _boxAccount(args['server'] as String?),
        'gachaHistory' => await _gachaHistory(args['key'] as String?),
        'signIn' => await _signIn('${args['provider']}'),
        'gameAccounts' => await _gameAccounts(),
        'openGameAccount' => _openGameAccount('${args['key']}'),
        'addGameAccount' => _addGameAccount(),
        'pendingGachaHistory' => switch (PendingHistory.take()) {
          final files? => {
            'files': [
              for (final file in files) {'name': file.name, 'text': file.text},
            ],
          },
          null => null,
        },
        'songProgress' => await _songProgress(args['server'] as String?),
        'pendingSongProgress' => switch (PendingProgress.take()) {
          final marks? => {'marks': marks},
          null => null,
        },
        'pendingBoxImport' => switch (PendingImport.take()) {
          final value? => {'server': value.server, 'text': value.text},
          null => null,
        },
        _ => throw UnsupportedError('${message['method']}'),
      };
    } catch (failure) {
      error = '$failure';
    }
    if (!mounted || document != _document || page.origin != origin.origin) {
      return;
    }
    await _controller.runJavaScript(
      'window.__haneokaAppResolve($id, ${jsonEncode(error)}, ${jsonEncode(value)})',
    );
  }

  Future<Map<String, Object?>?> _boxAccount(String? server) async {
    final picked = (await chooseGameAccount(context, server: server))?.save;
    if (picked == null) return null;
    var save = picked;
    if (canRefreshFromGame(save)) {
      try {
        save = await refreshFromGame(save);
      } catch (_) {
        if (mounted) _say(_t['readFailed']);
      }
    }
    return {'text': exportTeamPackage(save)};
  }

  Future<Map<String, Object?>?> _songProgress(String? server) async {
    final save = (await chooseGameAccount(context, server: server))?.save;
    return save == null ? null : {'marks': songMarks(save)};
  }

  Future<Map<String, Object?>?> _gachaHistory(String? key) async {
    await AccountStore.instance.load();
    if (!mounted) return null;
    final save = key == null
        ? null
        : AccountStore.instance.saves
              .where((save) => historyKey(save) == key)
              .firstOrNull;
    final chosen = save ?? (await chooseGameAccount(context))?.save;
    if (chosen == null) return null;
    try {
      final file = await readHistory(chosen);
      return {
        'files': [
          {'name': file.name, 'text': file.text},
        ],
      };
    } on GameHistoryException catch (error) {
      if (mounted) {
        _say(
          error.code == 'history_missing_session'
              ? _t['noSession']
              : _t['readFailed'],
        );
      }
      return null;
    }
  }

  Future<Map<String, Object?>?> _signIn(String provider) async {
    final grant = await signInWithProvider(origin, provider);
    return grant == null
        ? null
        : {'code': grant.code, 'verifier': grant.verifier};
  }

  Future<void> _download(Map<String, Object?> args) async {
    try {
      final bytes = base64.decode('${args['data']}');
      final saved = await FilePicker.saveFile(
        fileName: '${args['name']}',
        bytes: bytes,
        mimeType: (args['type'] as String?)?.isNotEmpty == true
            ? args['type'] as String
            : 'application/octet-stream',
      );
      if (saved != null && mounted) _say(_t['saved']);
    } catch (_) {
      if (mounted) _say(_t['saveFailed']);
    }
  }

  Future<void> _setFullscreen(bool active) async {
    if (mounted) setState(() => _fullscreen = active);
    await SystemChrome.setEnabledSystemUIMode(
      active ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    if (!active) await SystemChrome.setPreferredOrientations(const []);
  }

  Future<void> _back() async {
    if (!_initialized) {
      await SystemNavigator.pop();
      return;
    }
    if (_fullscreen) {
      await _controller.runJavaScript('window.__haneokaAppExitFullscreen?.()');
      return;
    }
    if (await _controller.canGoBack()) {
      await _controller.goBack();
    } else {
      await SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = _theme;
    final padding = _fullscreen
        ? EdgeInsets.zero
        : MediaQuery.paddingOf(context);
    final barDark =
        ThemeData.estimateBrightnessForColor(EdgeRun.dominant(theme.bar)) ==
        Brightness.dark;
    final backgroundDark =
        ThemeData.estimateBrightnessForColor(EdgeRun.dominant(theme.bottom)) ==
        Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: barDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: barDark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: backgroundDark
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      ),
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_back());
        },
        child: Scaffold(
          backgroundColor: theme.background,
          body: Column(
            children: [
              _Edge(
                runs: theme.bar,
                height: padding.top,
                duration: theme.duration,
              ),
              Expanded(
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  removeBottom: true,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_web case final controller?)
                        Offstage(
                          offstage: _launchVisible && !_loaded,
                          child: WebViewWidget(
                            key: ValueKey(controller),
                            controller: controller,
                          ),
                        ),
                      if (_launchVisible)
                        IgnorePointer(
                          ignoring: _loaded,
                          child: AnimatedOpacity(
                            opacity: _loaded ? 0 : 1,
                            duration: const Duration(milliseconds: 250),
                            onEnd: () {
                              if (mounted && _loaded) {
                                setState(() => _launchVisible = false);
                              }
                            },
                            child: TickerMode(
                              enabled: !_loaded,
                              child: LaunchScreen(
                                t: _t,
                                progress: _progress,
                                slow: _slow,
                                error: _error,
                                errorTitle: _initialized
                                    ? _t.format('offline', {
                                        'host': origin.host,
                                      })
                                    : _t['startupFailed'],
                                onRetry: _retry,
                                onSaves: _openSaves,
                                siteHost: origin.host,
                                alternativeHost:
                                    SiteOrigin.instance.alternative?.host,
                                onSwitchSite: _switchSite,
                                onCopyDiagnostics: _copyDiagnostics,
                                onOpenBrowser: () => launchUrl(
                                  _requestedPage ?? _home,
                                  mode: LaunchMode.externalApplication,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              _Edge(
                runs: theme.bottom,
                height: padding.bottom,
                duration: theme.duration,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The page supplies the background drawn under a system bar.
class _Edge extends StatelessWidget {
  const _Edge({
    required this.runs,
    required this.height,
    required this.duration,
  });
  final List<EdgeRun> runs;
  final double height;
  final Duration duration;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Row(
      children: [
        for (final run in runs)
          Expanded(
            flex: (run.width * 10000).round().clamp(1, 10000),
            child: AnimatedContainer(duration: duration, color: run.color),
          ),
      ],
    ),
  );
}
