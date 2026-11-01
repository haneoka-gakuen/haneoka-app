import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
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
  final _controller = WebViewController();
  final _links = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;
  bool _loaded = false;

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
    SiteLinks.load = _controller.loadRequest;
    AccountStore.instance.addListener(_accountsChanged);
    HaneokaAccount.siteCookies = _siteCookies;
    unawaited(_start());
  }

  @override
  void dispose() {
    SiteLinks.load = null;
    AccountStore.instance.removeListener(_accountsChanged);
    HaneokaAccount.siteCookies = null;
    _slowTimer?.cancel();
    _linkSubscription?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final info = await PackageInfo.fromPlatform();
    final controller = _controller;
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setBackgroundColor(_theme.background);
    final agent = await controller.getUserAgent();
    await controller.setUserAgent(
      '${agent ?? ''} HaneokaApp/${info.version}'.trim(),
    );
    await controller.addJavaScriptChannel(
      bridgeChannel,
      onMessageReceived: (message) => _message(message.message),
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
    // The Android plugin keeps only a weak reference to the delegate.
    await controller.setNavigationDelegate(
      _navigation = NavigationDelegate(
        onNavigationRequest: _navigate,
        onPageStarted: (_) {
          if (!userScript) unawaited(controller.runJavaScript(script));
        },
        onProgress: (progress) {
          if (!mounted || _loaded) return;
          setState(() => _progress = progress);
          if (progress == 100) _checkLoaded();
        },
        onPageFinished: (url) {
          _readSession(url);
          final server = Uri.tryParse(url)?.pathSegments.firstOrNull;
          if (mounted && (server == 'jp' || server == 'intl')) {
            AppScope.of(context).setServer(server!);
          }
          if (!userScript) unawaited(controller.runJavaScript(script));
          if (_error != null || _loaded || !mounted) return;
          _slowTimer?.cancel();
          setState(() => _loaded = true);
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame == false || !mounted) return;
          _slowTimer?.cancel();
          setState(() {
            _error = error.description.isEmpty
                ? 'error ${error.errorCode}'
                : error.description;
            _loaded = false;
          });
        },
      ),
    );
    final initial = await _links.getInitialLink();
    _startLoading();
    await controller.loadRequest(_page(initial) ?? _home);
    if (initial?.scheme == 'haneoka' && initial?.host == 'saves') _openSaves();
    _linkSubscription = _links.uriLinkStream.listen((uri) {
      if (uri.scheme == 'haneoka' && uri.host == 'saves') {
        _openSaves();
      } else if (_page(uri) case final page?) {
        controller.loadRequest(page);
      }
    });
  }

  /// A load that ends without the website: the platform does not always
  /// report it (Android skips the error callback when a proxy fails), so the
  /// page itself is asked. Only Haneoka's documents carry `data-locale`.
  Future<void> _checkLoaded() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted || _loaded || _error != null) return;
    final Object answer;
    try {
      answer = await _controller.runJavaScriptReturningResult(
        'JSON.stringify([document.documentElement.dataset.locale || "", '
        '(document.body?.innerText.match(/net::ERR_[A-Z_]+/) || [document.title || ""])[0]])',
      );
    } catch (_) {
      return;
    }
    final decoded = jsonDecode(
      answer is String && answer.startsWith('"')
          ? jsonDecode(answer) as String
          : '$answer',
    );
    if (!mounted || _loaded || _error != null || decoded is! List) return;
    if ('${decoded.first}'.isNotEmpty) {
      _slowTimer?.cancel();
      setState(() => _loaded = true);
    } else {
      _slowTimer?.cancel();
      setState(
        () => _error = '${decoded.last}'.trim().isEmpty
            ? _t['offline']
            : '${decoded.last}'.trim(),
      );
    }
  }

  /// A connection that takes long says so on the launch page; the load goes on.
  void _startLoading() {
    _slowTimer?.cancel();
    _slow = false;
    _slowTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && !_loaded) setState(() => _slow = true);
    });
  }

  Future<void> _retry() async {
    setState(() {
      _error = null;
      _progress = 0;
    });
    _startLoading();
    final current = Uri.tryParse(await _controller.currentUrl() ?? '');
    await _controller.loadRequest(
      current != null && current.host == origin.host ? current : _home,
    );
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
  void _accountsChanged() => unawaited(
    _controller.runJavaScript(
      'dispatchEvent(new Event("haneoka-app-accounts"))',
    ),
  );

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
      case 'theme':
        if (_error != null) return;
        if (PageTheme.read(args, _theme) case final theme?) {
          final state = AppScope.of(context);
          if (theme.locale case final locale?) {
            unawaited(state.setLocale(locale));
          }
          widget.theme.value = theme;
          unawaited(_controller.setBackgroundColor(theme.background));
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
                      WebViewWidget(controller: _controller),
                      IgnorePointer(
                        ignoring: _loaded,
                        child: AnimatedOpacity(
                          opacity: _loaded ? 0 : 1,
                          duration: const Duration(milliseconds: 250),
                          child: _Launch(
                            t: _t,
                            progress: _progress,
                            slow: _slow,
                            error: _error,
                            onRetry: _retry,
                            onSaves: _openSaves,
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

/// What the page shows along one edge, drawn under a system bar.
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

/// The launch page: the app's own screen until the website has drawn, with
/// the load's real progress, what is wrong when it cannot load, and save
/// reading, which needs neither the website nor a sign-in.
class _Launch extends StatelessWidget {
  const _Launch({
    required this.t,
    required this.progress,
    required this.slow,
    required this.error,
    required this.onRetry,
    required this.onSaves,
  });
  final Strings t;
  final int progress;
  final bool slow;
  final String? error;
  final VoidCallback onRetry;
  final VoidCallback onSaves;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = error != null;
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(flex: 3),
              Image.asset(
                'assets/brand/android-chrome-512x512.png',
                width: 96,
                height: 96,
              ),
              const SizedBox(height: 16),
              Text('haneoka', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 32),
              SizedBox(
                width: 240,
                height: 72,
                child: failed
                    ? Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Symbols.cloud_off_rounded,
                                size: 20,
                                color: scheme.error,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  t['offline'],
                                  style: theme.textTheme.titleSmall,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            error!,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      )
                    : Column(
                        children: [
                          LinearProgressIndicator(
                            value: progress > 0 ? progress / 100 : null,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            progress > 0
                                ? t.format('loading', {'percent': progress})
                                : t['connecting'],
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          if (slow)
                            Text(
                              t['slow'],
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
              ),
              const Spacer(flex: 2),
              if (failed) ...[
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Symbols.refresh_rounded),
                    label: Text(t['retry']),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: onSaves,
                  icon: const Icon(Symbols.sports_esports_rounded),
                  label: Text(t['readSave']),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
