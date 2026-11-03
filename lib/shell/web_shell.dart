import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_all_android/webview_all_android.dart';

import '../ui/game_account_sheet.dart';
import '../ui/import_screen.dart';
import '../account/haneoka_account.dart';
import '../core/app_state.dart';
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

/// The website, overridable for testing a local preview.
final origin = Uri.parse(
  const String.fromEnvironment(
    'HANEOKA_ORIGIN',
    defaultValue: 'https://haneoka.org',
  ),
);

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
  int _attempt = 0;
  int _document = 0;
  Uri? _requestedPage;
  Timer? _deadline;
  final _links = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;
  bool _loaded = false;
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
    _attempt++;
    _linkSubscription?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final attempt = ++_attempt;
    _initialized = false;
    _startLoading();
    try {
      await _configure(attempt).timeout(const Duration(seconds: 20));
    } catch (error, stack) {
      debugPrint('WebView startup: $error\n$stack');
      if (mounted && attempt == _attempt) {
        _attempt++;
        _fail(_t['webviewFailed']);
      }
    }
  }

  Future<void> _configure(int attempt) async {
    bool active() => mounted && attempt == _attempt;
    final controller = WebViewController();
    if (!active()) return;
    setState(() => _web = controller);
    final info = await PackageInfo.fromPlatform();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setBackgroundColor(_theme.background);
    final agent = await controller.getUserAgent();
    await controller.setUserAgent(
      '${agent ?? ''} HaneokaApp/${info.version}'.trim(),
    );
    await controller.addJavaScriptChannel(
      bridgeChannel,
      onMessageReceived: (message) {
        if (active()) unawaited(_message(message.message));
      },
    );
    final script = bridgeScript(
      version: info.version,
      platform: Platform.operatingSystem,
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
          _document++;
          _requestedPage = Uri.tryParse(url);
          if (!_loaded) _startLoading();
          if (!userScript) _inject(script);
        },
        onProgress: (progress) {
          if (!active() || _loaded || _error != null) return;
          setState(() => _progress = progress);
          if (progress == 100) unawaited(_checkLoaded());
        },
        onPageFinished: (url) {
          if (!active()) return;
          _readSession(url);
          final server = Uri.tryParse(url)?.pathSegments.firstOrNull;
          if (server == 'jp' || server == 'intl') {
            AppScope.of(context).setServer(server!);
          }
          if (!userScript) _inject(script);
          unawaited(_checkLoaded());
        },
        onWebResourceError: (error) {
          if (!active() || error.isForMainFrame == false) return;
          if (error.url?.isNotEmpty == true &&
              Uri.tryParse(error.url!) != _requestedPage) {
            return;
          }
          if (error.isForMainFrame == true) {
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
          _fail('HTTP ${error.response?.statusCode ?? ''}'.trim());
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
    await controller.loadRequest(_requestedPage!);
    if (!active()) return;
    if (initial?.scheme == 'haneoka' && initial?.host == 'saves') _openSaves();
    await _linkSubscription?.cancel();
    _linkSubscription = _links.uriLinkStream.listen((uri) {
      if (uri.scheme == 'haneoka' && uri.host == 'saves') {
        _openSaves();
      } else if (_page(uri) case final page?) {
        unawaited(_loadPage(page));
      }
    });
  }

  void _inject(String script) {
    unawaited(
      _controller.runJavaScript(script).catchError((Object error) {
        debugPrint('Page bridge: $error');
      }),
    );
  }

  Future<void> _checkLoaded() async {
    final attempt = _attempt, document = _document;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted ||
        _loaded ||
        _web == null ||
        attempt != _attempt ||
        document != _document) {
      return;
    }
    try {
      Object? answer = await _controller
          .runJavaScriptReturningResult(
            'JSON.stringify({locale:document.documentElement.dataset.locale || "",'
            'main:!!document.querySelector("main"),ready:document.readyState,'
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
      if (answer['locale'] != '' && answer['main'] == true) {
        _showPage();
      } else if ('${answer['error'] ?? ''}'.isNotEmpty) {
        _fail('${answer['error']}');
      }
    } catch (error) {
      debugPrint('Page readiness: $error');
    }
  }

  void _showPage() {
    if (_error != null || _loaded || !mounted) return;
    _slowTimer?.cancel();
    _deadline?.cancel();
    setState(() => _loaded = true);
  }

  void _fail(String error) {
    if (!mounted) return;
    _slowTimer?.cancel();
    _deadline?.cancel();
    setState(() {
      _error = error;
      _loaded = false;
      _launchVisible = true;
    });
  }

  void _startLoading() {
    _slowTimer?.cancel();
    _deadline?.cancel();
    _slow = false;
    _slowTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && !_loaded) setState(() => _slow = true);
    });
    final attempt = _attempt, document = _document;
    _deadline = Timer(const Duration(seconds: 30), () async {
      await _checkLoaded();
      if (mounted && !_loaded && attempt == _attempt && document == _document) {
        _fail(_t['loadTimeout']);
      }
    });
  }

  Future<void> _loadPage(Uri page) async {
    _requestedPage = page;
    if (!_initialized) {
      await _start();
      return;
    }
    final attempt = _attempt;
    setState(() {
      _error = null;
      _progress = 0;
    });
    _document++;
    _startLoading();
    try {
      await _controller.loadRequest(page).timeout(const Duration(seconds: 15));
    } catch (error) {
      debugPrint('Page navigation: $error');
      if (mounted && attempt == _attempt) _fail(_t['offline']);
    }
  }

  Future<void> _retry() async {
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
    if (link.host == origin.host) return link;
    if (link.scheme == 'haneoka' && link.host == 'gacha-history') {
      return _home.resolve('gacha-history/');
    }
    return null;
  }

  FutureOr<NavigationDecision> _navigate(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    if (uri == null || !request.isMainFrame) return NavigationDecision.navigate;
    if (uri.host == origin.host ||
        const {'about', 'blob', 'data', 'javascript'}.contains(uri.scheme)) {
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

  Future<void> _message(String text) async {
    final Map<String, Object?> message;
    try {
      message = (jsonDecode(text) as Map).cast<String, Object?>();
    } on FormatException {
      return;
    }
    final args = (message['args'] as Map?)?.cast<String, Object?>() ?? {};
    switch (message['method']) {
      case 'painted':
        return _showPage();
      case 'theme':
        if (_error != null) return;
        if (PageTheme.read(args, _theme) case final theme?) {
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
                        WebViewWidget(
                          key: ValueKey(controller),
                          controller: controller,
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
                                    ? _t['offline']
                                    : _t['startupFailed'],
                                onRetry: _retry,
                                onSaves: _openSaves,
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
