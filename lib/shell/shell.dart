import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../core/app_updates.dart';
import '../core/voice.dart';
import '../core/storage.dart';
import '../ui/app_updates.dart';
import '../ui/player.dart';
import '../ui/player_orientation.dart';
import '../ui/theme.dart';
import '../ui/import_screen.dart';
import 'links.dart';
import 'navigation.dart';
import 'page.dart';
import 'routes.dart';

/// The website's shell: an expanded drawer on wide windows, a rail on medium
/// ones, a modal drawer on phones; the page's bar and pane beside it.
class AppShell extends StatefulWidget {
  const AppShell({super.key, this.initialAddress});
  final Uri? initialAddress;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _PageNavigationObserver extends NavigatorObserver {
  _PageNavigationObserver(this.onChange);
  final ValueChanged<String> onChange;
  final _routes = <Route<dynamic>>[];
  Route<dynamic>? _visibleRoute;
  Route<dynamic>? get current => _routes.lastOrNull;
  List<PageRoute<dynamic>> get pages =>
      _routes.whereType<PageRoute<dynamic>>().toList();

  void _changed() {
    playerOrientation.setActiveRoute(
      _routes.whereType<PageRoute<dynamic>>().lastOrNull,
    );
    if (_visibleRoute != current) {
      _visibleRoute = current;
      VoicePlayback.stopAll();
    }
    final route = _routes.reversed
        .map((route) => route.settings.name)
        .whereType<String>()
        .firstOrNull;
    if (route != null) onChange(route);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        _routes.removeAt(index);
      } else {
        _routes[index] = newRoute;
      }
    }
    _changed();
  }
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  final _scaffold = GlobalKey<ScaffoldState>();
  var _pages = GlobalKey<NavigatorState>();
  String _route = const String.fromEnvironment(
    'HANEOKA_ROUTE',
    defaultValue: '/',
  );
  late var _observer = _PageNavigationObserver(_routeChanged);
  bool _nestedCanPop = false;
  bool _drawerCollapsed = false;
  bool _navigationOpen = false;
  bool _handlingBack = false;
  (String, String)? _dataKey;
  void _routeChanged(String value) {
    if (mounted && _route != value) setState(() => _route = value);
  }

  StreamSubscription<Uri>? _links;
  String? _notifiedRelease;

  Future<void> _checkUpdates() async {
    final updates = AppUpdates.instance;
    await updates.check();
    final notify = await updates.shouldNotify();
    if (!mounted ||
        !notify ||
        _notifiedRelease == updates.available?.identity) {
      return;
    }
    _notifiedRelease = updates.available!.identity;
    await showAppUpdate(context, updates.available!);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CacheStorage.instance.scheduleTrim();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkUpdates());
    if (widget.initialAddress case final address?) _openAddress(address);
    // haneoka.org addresses opened from other apps (Android App Links).
    if (Platform.isAndroid || Platform.isIOS) {
      _links = AppLinks().uriLinkStream.listen(_openAddress);
    }
  }

  @override
  void dispose() {
    _links?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_checkUpdates());
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      AppScope.of(context).audio.saveSnapshot();
    }
  }

  void _openAddress(Uri uri) {
    if (uri.scheme == 'haneoka' && uri.host == 'auth') return;
    if (uri.scheme == 'haneoka') {
      uri = Uri(
        scheme: 'https',
        host: 'haneoka.org',
        path: '/${uri.host}${uri.path}',
        query: uri.hasQuery ? uri.query : null,
        fragment: uri.hasFragment ? uri.fragment : null,
      );
    }
    if (uri.scheme == 'file') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _pages.currentState?.push(
          MaterialPageRoute<void>(
            builder: (_) => ImportScreen(initialPath: uri.toFilePath()),
          ),
        );
      });
      WidgetsBinding.instance.scheduleFrame();
      return;
    }
    if (uri.host != 'haneoka.org') return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _pages.currentContext;
      if (context != null && context.mounted) {
        openLink(context, uri.toString(), navigate: _navigate);
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  bool _isPlayerRoute(Route<dynamic> route) {
    final uri = Uri.tryParse(route.settings.name ?? '');
    return uri != null &&
        (uri.path == '/chart-simulator' ||
            uri.path == '/catalog/live2d' ||
            uri.path == '/catalog/spine' ||
            uri.path.startsWith('/catalog/live2d/') ||
            uri.path.startsWith('/catalog/spine/') ||
            uri.queryParameters['view'] == 'play');
  }

  void _navigate(String route) {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _navigate(route);
      });
      return;
    }
    _scaffold.currentState?.closeDrawer();
    if (route == _route) return;
    final navigator = _pages.currentState;
    if (navigator == null) return;
    final destination = route;
    final page = MaterialPageRoute<void>(
      settings: RouteSettings(name: destination),
      builder: (_) =>
          screenFor(destination, navigate: _navigate) ??
          PendingScreen(label: destination),
    );
    // Keep ordinary pages alive for Back. Leaving a player releases its GPU
    // session and audio instead of retaining them behind the next page.
    unawaited(
      navigator.pushAndRemoveUntil(
        page,
        (previous) => previous is PageRoute && !_isPlayerRoute(previous),
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final retained = _observer.pages;
      for (final previous in retained.take(
        (retained.length - 16).clamp(0, retained.length),
      )) {
        if (!previous.isCurrent) navigator.removeRoute(previous);
      }
    });
  }

  Future<void> _back() async {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_back());
      });
      return;
    }
    if (_handlingBack) return;
    _handlingBack = true;
    try {
      if (_scaffold.currentState?.isDrawerOpen ?? false) {
        _scaffold.currentState?.closeDrawer();
        return;
      }
      final popped = await _pages.currentState?.maybePop() ?? false;
      if (!popped && mounted && _route != '/') _navigate('/');
    } finally {
      _handlingBack = false;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    final key = (state.server, state.text.locale);
    if (_dataKey != null && _dataKey != key) {
      _pages = GlobalKey<NavigatorState>();
      _observer = _PageNavigationObserver(_routeChanged);
      _nestedCanPop = false;
    }
    _dataKey = key;
  }

  NavDestination? get _destination {
    NavDestination? best;
    var score = -1;
    void matchItems(List<NavItem> items, NavDestination destination) {
      for (final item in items) {
        final match = routeMatch(_route, item.route);
        if (match > score) {
          best = destination;
          score = match;
        }
        matchItems(item.children, destination);
      }
    }

    for (final destination in navDestinations) {
      final match = routeMatch(_route, destination.route);
      if (match > score) {
        best = destination;
        score = match;
      }
      for (final section in destination.sections) {
        matchItems(section.items, destination);
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    final destinationRoute = _route;
    final page = NotificationListener<NavigationNotification>(
      onNotification: (notification) {
        if (_nestedCanPop != notification.canHandlePop) {
          setState(() => _nestedCanPop = notification.canHandlePop);
        }
        return false;
      },
      child: Navigator(
        key: _pages,
        observers: [_observer],
        onGenerateRoute: (_) {
          final route = MaterialPageRoute<void>(
            settings: RouteSettings(name: destinationRoute),
            builder: (_) =>
                screenFor(destinationRoute, navigate: _navigate) ??
                PendingScreen(label: destinationRoute),
          );
          return route;
        },
      ),
    );
    return PopScope<void>(
      canPop: !_nestedCanPop && _route == '/',
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_back());
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final compact =
              width < ShellMetrics.compact ||
              ((Platform.isAndroid || Platform.isIOS) &&
                  constraints.maxHeight < ShellMetrics.compact);
          AppScope.of(context).audio.compact = compact;
          final destination = _destination;
          Widget drawer(bool modal) => _Drawer(
            route: _route,
            current: destination,
            modal: modal,
            onNavigate: _navigate,
            onClose: modal
                ? () => _scaffold.currentState?.closeDrawer()
                : () => setState(() => _drawerCollapsed = true),
          );
          final body = ShellScope(
            back: () => unawaited(_back()),
            canGoBack: _nestedCanPop || _route != '/',
            compact: compact,
            navigationOpen: _navigationOpen,
            openNavigation: () => _scaffold.currentState?.openDrawer(),
            navigate: _navigate,
            child: compact
                ? page
                : Column(
                    children: [
                      Expanded(child: page),
                      const DockedPlayer(),
                    ],
                  ),
          );
          if (compact) {
            return Scaffold(
              key: _scaffold,
              onDrawerChanged: (open) => setState(() => _navigationOpen = open),
              drawer: Drawer(
                width: ShellMetrics.drawer + 40,
                child: drawer(true),
              ),
              body: SafeArea(child: body),
            );
          }
          if (width < ShellMetrics.expanded || _drawerCollapsed) {
            return Scaffold(
              key: _scaffold,
              onDrawerChanged: (open) => setState(() => _navigationOpen = open),
              drawer: Drawer(
                width: ShellMetrics.drawer + 40,
                child: drawer(true),
              ),
              body: SafeArea(
                child: Row(
                  children: [
                    NavigationRail(
                      scrollable: true,
                      selectedIndex: destination == null
                          ? null
                          : navDestinations.indexOf(destination),
                      labelType: NavigationRailLabelType.all,
                      leading: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: IconButton(
                          tooltip: MaterialLocalizations.of(context)
                              .openAppDrawerTooltip,
                          onPressed: () {
                            if (width >= ShellMetrics.expanded &&
                                _drawerCollapsed) {
                              setState(() => _drawerCollapsed = false);
                            } else {
                              _scaffold.currentState?.openDrawer();
                            }
                          },
                          icon: const Icon(Symbols.menu_rounded),
                        ),
                      ),
                      trailing: Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const NowPlaying(),
                              for (final item in utilityItems)
                                IconButton(
                                  tooltip: t(item.label),
                                  isSelected: _route == item.route,
                                  onPressed: () => _navigate(item.route),
                                  icon: Icon(item.icon),
                                  selectedIcon: Icon(item.icon, fill: 1),
                                ),
                            ],
                          ),
                        ),
                      ),
                      onDestinationSelected: (index) =>
                          _navigate(navDestinations[index].route),
                      destinations: [
                        for (final d in navDestinations)
                          NavigationRailDestination(
                            icon: Icon(d.icon),
                            selectedIcon: Icon(d.icon, fill: 1),
                            label: Text(t(d.label)),
                          ),
                      ],
                    ),
                    Expanded(child: body),
                  ],
                ),
              ),
            );
          }
          return Scaffold(
            key: _scaffold,
            body: SafeArea(
              child: Row(
                children: [
                  SizedBox(width: ShellMetrics.drawer, child: drawer(false)),
                  Expanded(child: body),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The website's drawer (`.nav`): brand, then each destination as a header
/// that opens its page and its tree, the current one open; Account,
/// Settings and About at the foot.
class _Drawer extends StatefulWidget {
  const _Drawer({
    required this.route,
    required this.current,
    required this.modal,
    required this.onNavigate,
    required this.onClose,
  });
  final String route;
  final NavDestination? current;
  final bool modal;
  final ValueChanged<String> onNavigate;
  final VoidCallback onClose;

  @override
  State<_Drawer> createState() => _DrawerState();
}

class _DrawerState extends State<_Drawer> {
  late final Set<String> _open = {?widget.current?.id};

  /// Collapsible sections (the archive mirrors) the reader opened.
  final Set<String> _expanded = {};
  final _selected = GlobalKey();

  void _revealCurrent() {
    bool contains(List<NavItem> items) => items.any(
      (item) =>
          item.route == activeNavigationItem(widget.route)?.route ||
          contains(item.children),
    );
    for (final section in widget.current?.sections ?? const <NavSection>[]) {
      if (section.collapsible && contains(section.items)) {
        _expanded.add(section.id);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _selected.currentContext;
      if (mounted && context != null) {
        Scrollable.ensureVisible(
          context,
          alignment: widget.current?.id == 'stories' ? 0.12 : 0.35,
        );
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _revealCurrent();
  }

  @override
  void didUpdateWidget(_Drawer old) {
    super.didUpdateWidget(old);
    if (widget.current != null) _open.add(widget.current!.id);
    if (old.route != widget.route) _revealCurrent();
  }

  void _toggle(Set<String> set, String id) =>
      setState(() => set.contains(id) ? set.remove(id) : set.add(id));

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final activeRoute = activeNavigationItem(widget.route)?.route;

    Widget row({
      required String label,
      IconData? icon,
      required bool active,
      required VoidCallback onTap,
      double indent = 0,
      double height = 56,
      Widget? trailing,
      TextStyle? style,
      Key? key,
    }) => Padding(
      key: key,
      padding: EdgeInsets.fromLTRB(16 + indent, 0, 12, 0),
      child: Material(
        color: active ? scheme.secondaryContainer : Colors.transparent,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: SizedBox(
            height: height,
            child: Row(
              children: [
                const SizedBox(width: 16),
                if (icon != null) ...[
                  Icon(
                    icon,
                    fill: active ? 1 : 0,
                    color: active
                        ? scheme.onSecondaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: (style ?? theme.textTheme.labelLarge)?.copyWith(
                      color: active
                          ? scheme.onSecondaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                ?trailing,
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
    );

    List<Widget> items(List<NavItem> list, double indent) => [
      for (final item in list) ...[
        row(
          key: item.route == activeRoute ? _selected : null,
          label: t(item.label),
          icon: item.icon,
          active: item.route == activeRoute,
          onTap: () => widget.onNavigate(item.route),
          indent: indent,
          height: 48,
        ),
        ...items(item.children, indent + 16),
      ],
    ];

    Icon chevron(bool open) => Icon(
      open
          ? Symbols.keyboard_arrow_up_rounded
          : Symbols.keyboard_arrow_down_rounded,
      color: scheme.onSurfaceVariant,
    );

    return ColoredBox(
      color: scheme.surfaceContainer,
      child: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: ShellMetrics.topBar,
              child: Row(
                children: [
                  SizedBox(width: widget.modal ? 16 : 28),
                  if (widget.modal)
                    IconButton(
                      tooltip: MaterialLocalizations.of(context)
                          .closeButtonTooltip,
                      onPressed: widget.onClose,
                      icon: const Icon(Symbols.menu_open_rounded),
                    )
                  else
                    IconButton(
                      tooltip: MaterialLocalizations.of(context)
                          .openAppDrawerTooltip,
                      onPressed: widget.onClose,
                      icon: const Icon(Symbols.menu_open_rounded),
                    ),
                  SizedBox(width: widget.modal ? 4 : 12),
                  Image.asset(
                    'assets/brand/android-chrome-512x512.png',
                    width: 32,
                    height: 32,
                  ),
                  const SizedBox(width: 12),
                  Text('haneoka', style: theme.textTheme.titleLarge),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  for (final destination in navDestinations) ...[
                    row(
                      label: t(destination.label),
                      icon: destination.icon,
                      active: widget.current?.id == destination.id,
                      onTap: () {
                        setState(() => _open.add(destination.id));
                        widget.onNavigate(destination.route);
                      },
                      trailing: destination.sections.isEmpty
                          ? null
                          : InkResponse(
                              onTap: () => _toggle(_open, destination.id),
                              child: chevron(_open.contains(destination.id)),
                            ),
                    ),
                    if (_open.contains(destination.id))
                      for (final section in destination.sections) ...[
                        if (section.collapsible)
                          row(
                            label: t(section.label),
                            active: false,
                            onTap: () => _toggle(_expanded, section.id),
                            indent: 16,
                            height: 48,
                            style: theme.textTheme.titleSmall,
                            trailing: chevron(_expanded.contains(section.id)),
                          )
                        else if (destination.sections.length > 1)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(48, 12, 12, 8),
                            child: Text(
                              t(section.label),
                              style: theme.textTheme.titleSmall,
                            ),
                          ),
                        if (!section.collapsible ||
                            _expanded.contains(section.id))
                          ...items(section.items, 16),
                      ],
                  ],
                ],
              ),
            ),
            const NowPlaying(expanded: true),
            for (final item in utilityItems)
              row(
                label: t(item.label),
                icon: item.icon,
                active: widget.route == item.route,
                onTap: () => widget.onNavigate(item.route),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
