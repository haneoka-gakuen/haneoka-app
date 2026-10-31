import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../ui/player.dart';
import '../ui/theme.dart';

/// Lets a page open the shell's navigation on compact windows.
class ShellScope extends InheritedWidget {
  const ShellScope({
    super.key,
    required this.openNavigation,
    required this.compact,
    required this.navigate,
    required this.back,
    required this.canGoBack,
    this.navigationOpen = false,
    required super.child,
  });
  final VoidCallback openNavigation;
  final bool compact;

  /// Opens a website route in the shell (`/catalog/songs`, `/calendar`).
  final ValueChanged<String> navigate;
  final VoidCallback back;
  final bool canGoBack;
  final bool navigationOpen;
  static ShellScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellScope>();
  @override
  bool updateShouldNotify(ShellScope old) =>
      old.compact != compact ||
      old.canGoBack != canGoBack ||
      old.navigationOpen != navigationOpen;
}

/// One control in the title bar. It draws as an icon button while it fits and
/// as a menu entry behind ⋮ when it does not (`app-bar-overflow.ts`).
class BarAction {
  const BarAction({
    required this.icon,
    required this.label,
    this.onPressed,
    this.selected,
    this.badge = 0,
    this.tonal = false,
    this.overflowFirst = false,
    this.image,
    this.showLabel = false,
  }) : options = const [];

  /// A segmented choice (view switch): one checkable menu entry per option.
  const BarAction.choice({required this.label, required this.options})
    : icon = Symbols.tune_rounded,
      onPressed = null,
      selected = null,
      badge = 0,
      tonal = false,
      overflowFirst = false,
      image = null,
      showLabel = false;
  final bool showLabel;
  final Widget? image;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// A toggle's state; null for a plain action.
  final bool? selected;
  final int badge;
  final bool tonal;
  final List<BarChoice> options;

  /// Entity arrows: the first to move into the overflow menu.
  final bool overflowFirst;

  int get slots => options.isEmpty ? 1 : options.length;
}

class BarChoice {
  const BarChoice({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.image,
  });
  final IconData icon;

  /// Drawn instead of [icon]: a flag, a logo.
  final Widget? image;
  final String label;
  final bool selected;
  final VoidCallback onSelected;
}

/// Every page: the shell's title bar above the content pane, as on the
/// website. The bar carries Back or the navigation menu, the title, marks
/// after the title, the search and the page's actions; nothing else draws a
/// bar. On compact windows bar and page are one surface, and the bar takes
/// surface-container once the page scrolls under it.
class ShellPage extends StatefulWidget {
  const ShellPage({
    super.key,
    required this.title,
    required this.body,
    this.titleLanguage,
    this.marks,
    this.marksExtent = 0,
    this.status,
    this.actions = const [],
    this.search,
    this.showBack = false,
    this.onBack,
  });
  final String title;
  final Locale? titleLanguage;

  /// Identity after the title: rarity, band, applied-filter chips.
  final Widget? marks;

  /// A live count or state before the actions; never overflows.
  final Widget? status;

  /// The marks' width, kept beside the title before actions overflow.
  final double marksExtent;
  final List<BarAction> actions;
  final ShellSearch? search;
  final bool showBack;
  final VoidCallback? onBack;
  final Widget body;

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  bool _scrolled = false;
  bool _nextScrolled = false, _scrollScheduled = false;
  bool _searching = false;
  late final _searchController = TextEditingController(
    text: widget.search?.initial,
  );

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth == 0 && notification.metrics.axis == Axis.vertical) {
      _nextScrolled = notification.metrics.pixels > 2;
      if (_nextScrolled != _scrolled && !_scrollScheduled) {
        _scrollScheduled = true;
        final binding = WidgetsBinding.instance;
        binding.addPostFrameCallback((_) {
          _scrollScheduled = false;
          if (mounted && _scrolled != _nextScrolled) {
            setState(() => _scrolled = _nextScrolled);
          }
        });
        binding.ensureVisualUpdate();
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final shell = ShellScope.of(context);
    final compact = shell?.compact ?? false;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Over the seasonal background the frame is clear and the pane translucent.
    final backdrop = AppScope.maybeOf(context)?.seasonBackdrop ?? false;
    final surface = backdrop
        ? scheme.surface.withValues(alpha: 0.55)
        : scheme.surface;
    final frame = backdrop ? Colors.transparent : scheme.surfaceContainer;
    final barColor = compact ? (_scrolled ? frame : surface) : frame;
    final pane = NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: Material(color: surface, child: widget.body),
    );
    return Material(
      color: compact ? surface : frame,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            color: barColor,
            height: ShellMetrics.topBar,
            padding: EdgeInsets.only(
              left: 4,
              right: compact ? 4 : ShellMetrics.paneGap,
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ListenableBuilder(
                  listenable:
                      AppScope.maybeOf(context)?.audio ?? const _Silent(),
                  builder: (context, _) => _bar(context, compact),
                ),
                if (_searching && widget.search != null)
                  Positioned.fill(child: _compactSearch(context)),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: compact
                ? pane
                : Padding(
                    padding: const EdgeInsets.fromLTRB(
                      0,
                      0,
                      ShellMetrics.paneGap,
                      ShellMetrics.paneGap,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(Corner.extraLarge),
                      child: pane,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  bool _detail(BuildContext context) {
    final route = ModalRoute.of(context);
    if (!(route?.canPop ?? false)) return false;
    if (widget.showBack) return true;
    final name = route?.settings.name;
    if (name == null) return true;
    final parts = Uri.parse(name).pathSegments;
    if (parts.length > 2 && parts.first == 'account') return true;
    if (parts.length > 1 && parts.first == 'stories') return true;
    if (parts.length > 2 &&
        parts.first == 'community' &&
        const {
          'posts',
          'users',
          'playlists',
          'songs-bestdori',
          'gbp',
          'sekai',
        }.contains(parts[1])) {
      return true;
    }
    if (parts.length > 2 && parts.first == 'catalog') {
      return parts[1] != 'stories' ||
          !const {
            'event',
            'band',
            'link',
            'birthday',
            'home',
            'afterlive',
            'tutorial',
          }.contains(parts[2]);
    }
    return false;
  }

  double _buttonExtent(BuildContext context) => 48;

  Widget _bar(BuildContext context, bool compact) {
    final shell = ShellScope.of(context);
    final theme = Theme.of(context);
    final detail = _detail(context);
    final canPop = detail || widget.onBack != null || shell?.canGoBack == true;
    final leading = canPop
        ? BackButton(onPressed: widget.onBack ?? shell?.back)
        : compact && shell != null
        ? IconButton(
            tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
            onPressed: shell.openNavigation,
            icon: const Icon(Symbols.menu_rounded),
          )
        : null;
    // The title keeps up to 160 dp before actions start to overflow
    // (`TITLE_MAX_RESERVED`); everything else belongs to the actions.
    return IconButtonTheme(
      data: IconButtonThemeData(
        style: ButtonStyle(
          fixedSize: WidgetStatePropertyAll(
            Size.square(_buttonExtent(context)),
          ),
          minimumSize: WidgetStatePropertyAll(
            Size.square(_buttonExtent(context)),
          ),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final lead = leading == null ? 12.0 : _buttonExtent(context) + 12;
          final title = (TextPainter(
            text: TextSpan(
              text: widget.title,
              style: theme.textTheme.titleLarge,
            ),
            textDirection: Directionality.of(context),
            maxLines: 1,
          )..layout()).width;
          final budget =
              (constraints.maxWidth -
                      lead -
                      title.clamp(
                        0,
                        widget.actions.any((a) => a.showLabel) ? 80 : 160,
                      ) -
                      (widget.marks == null ? 0 : widget.marksExtent + 8))
                  .clamp(48.0, constraints.maxWidth);
          return Row(
            children: [
              ?leading,
              SizedBox(width: leading == null ? 12 : 4),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        widget.title,
                        locale: widget.titleLanguage,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    if (widget.marks != null)
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: widget.marks!,
                        ),
                      ),
                  ],
                ),
              ),
              _trailing(context, compact, budget),
            ],
          );
        },
      ),
    );
  }

  /// Search, status, then as many actions as fit; the rest behind ⋮.
  Widget _trailing(BuildContext context, bool compact, double width) {
    final search = widget.search;
    final children = <Widget>[];
    var room = width;
    final slot = _buttonExtent(context) + 2;
    if (compact && AppScope.maybeOf(context)?.audio.current != null) {
      children.add(const NowPlaying());
      room -= slot;
    }
    if (search != null) {
      if (compact || room < 260) {
        children.add(
          IconButton(
            tooltip: search.label,
            onPressed: () => setState(() => _searching = true),
            icon: const Icon(Symbols.search_rounded),
          ),
        );
        room -= slot;
      } else {
        final pill = (room * 0.5).clamp(160.0, 360.0);
        children.add(
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SizedBox(width: pill, child: _searchBar(search, false)),
          ),
        );
        room -= pill + 8;
      }
    }
    if (widget.status != null) {
      children.add(widget.status!);
      room -= 44;
    }
    // As `fitAppBarActions`: 40 dp buttons 2 dp apart; entity arrows leave
    // first, then page actions from the end; on compact windows a page with
    // Back keeps the navigation menu in the overflow.
    final actions = widget.actions;
    final shell = ShellScope.of(context);
    final canPop = _detail(context) || widget.onBack != null;
    final menu = compact && canPop && shell != null
        ? BarAction(
            icon: Symbols.menu_rounded,
            label:
                AppScope.maybeOf(context)?.text('navigation.menu', 'Menu') ??
                'Menu',
            onPressed: shell.openNavigation,
          )
        : null;
    final hidden = <BarAction>{};
    double extent(BarAction action) {
      if (!action.showLabel) return action.slots * slot;
      final painter = TextPainter(
        text: TextSpan(
          text: action.label,
          style: Theme.of(context).textTheme.labelLarge,
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final width = painter.width + 62;
      painter.dispose();
      return width;
    }

    double used() =>
        actions
            .where((a) => !hidden.contains(a))
            .fold<double>(0, (sum, a) => sum + extent(a)) +
        (hidden.isNotEmpty || menu != null ? slot : 0);
    final order = [
      ...actions.where((a) => a.overflowFirst),
      ...actions.reversed.where((a) => !a.overflowFirst),
    ];
    for (final action in order) {
      if (used() <= room) break;
      hidden.add(action);
    }
    for (final action in actions) {
      if (!hidden.contains(action)) {
        children.addAll(
          _buttons(action).map(
            (button) =>
                Padding(padding: const EdgeInsets.only(left: 2), child: button),
          ),
        );
      }
    }
    final overflowed = [
      for (final action in actions)
        if (hidden.contains(action)) action,
      ?menu,
    ];
    if (overflowed.isNotEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(left: 2),
          child: _overflow(context, overflowed),
        ),
      );
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  List<Widget> _buttons(BarAction action) {
    if (action.options.isNotEmpty) {
      return [
        for (final option in action.options)
          option.selected
              ? IconButton.filledTonal(
                  tooltip: option.label,
                  onPressed: option.onSelected,
                  icon: option.image ?? Icon(option.icon, fill: 1),
                )
              : IconButton(
                  tooltip: option.label,
                  onPressed: option.onSelected,
                  icon: option.image ?? Icon(option.icon),
                ),
      ];
    }
    Widget icon = action.image ?? Icon(action.icon);
    if (action.badge > 0) {
      icon = Badge.count(count: action.badge, child: icon);
    }
    return [
      if (action.showLabel)
        FilledButton.tonalIcon(
          onPressed: action.onPressed,
          icon: icon,
          label: Text(action.label),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
        )
      else if (action.tonal)
        IconButton.filledTonal(
          tooltip: action.label,
          onPressed: action.onPressed,
          icon: icon,
        )
      else
        IconButton(
          tooltip: action.label,
          isSelected: action.selected,
          onPressed: action.onPressed,
          icon: icon,
        ),
    ];
  }

  Widget _overflow(BuildContext context, List<BarAction> hidden) {
    return MenuAnchor(
      menuChildren: [
        for (final action in hidden)
          if (action.options.isEmpty)
            MenuItemButton(
              leadingIcon: action.image ?? Icon(action.icon),
              trailingIcon: action.selected == true
                  ? const Icon(Symbols.check_rounded, size: 20)
                  : null,
              onPressed: action.onPressed,
              child: Text(action.label),
            )
          else
            for (final option in action.options)
              MenuItemButton(
                leadingIcon: option.image ?? Icon(option.icon),
                trailingIcon: option.selected
                    ? const Icon(Symbols.check_rounded, size: 20)
                    : null,
                onPressed: option.onSelected,
                child: Text(option.label),
              ),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: MaterialLocalizations.of(context).showMenuTooltip,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Symbols.more_vert_rounded),
      ),
    );
  }

  Widget _searchBar(ShellSearch search, bool compact) => SearchBar(
    controller: _searchController,
    autoFocus: compact,
    hintText: search.label,
    leading: const Icon(Symbols.search_rounded),
    trailing: [
      if (compact || _searchController.text.isNotEmpty)
        IconButton(
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: () => setState(() {
            _searchController.clear();
            search.onChanged('');
            _searching = false;
          }),
          icon: const Icon(Symbols.close_rounded),
        ),
    ],
    keyboardType: search.keyboardType,
    onSubmitted: search.onSubmitted,
    onChanged: (value) {
      setState(() {});
      search.onChanged(value);
    },
  );

  /// On compact windows the field grows out of the search icon it replaces.
  Widget _compactSearch(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: const Duration(milliseconds: 300),
    curve: Curves.easeOutCubic,
    builder: (context, t, child) =>
        ClipPath(clipper: _RevealFromEnd(t), child: child),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: _searchBar(widget.search!, true),
    ),
  );
}

class _RevealFromEnd extends CustomClipper<Path> {
  _RevealFromEnd(this.t);
  final double t;
  @override
  Path getClip(Size size) {
    final left = (size.width - 48) * (1 - t);
    return Path()..addRRect(
      RRect.fromLTRBR(
        left,
        0,
        size.width,
        size.height,
        const Radius.circular(28),
      ),
    );
  }

  @override
  bool shouldReclip(_RevealFromEnd old) => old.t != t;
}

class ShellSearch {
  const ShellSearch({
    required this.label,
    required this.onChanged,
    this.onSubmitted,
    this.initial,
    this.keyboardType,
  });
  final String label;
  final ValueChanged<String> onChanged;

  /// For a lookup rather than a filter (a player ID).
  final ValueChanged<String>? onSubmitted;
  final String? initial;
  final TextInputType? keyboardType;
}

/// A listenable that never changes, for pages shown without the app's state.
class _Silent implements Listenable {
  const _Silent();
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}
