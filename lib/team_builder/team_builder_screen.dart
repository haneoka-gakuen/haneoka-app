/// The team builder: Build, My cards, Account bonuses and Teams, over the
/// box synced with the website (`lit/team-builder.ts`).
library;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../account/account_widgets.dart';
import '../account/haneoka_account.dart';
import '../core/app_state.dart';
import '../save/game_save.dart';
import '../shell/links.dart';
import '../shell/page.dart';
import 'account_tab.dart';
import 'arena.dart';
import 'box.dart';
import 'box_import_screen.dart';
import 'box_tab.dart';
import 'build_tab.dart';
import 'controller.dart';
import 'engine/num.dart';
import 'pt_tab.dart';
import 'teams_tab.dart';
import 'song_comparison_view.dart';
import 'results_view.dart' show showResultComparison;
import 'widgets.dart';

enum _Tab { build, pt, comparison, arena, box, account, teams }

class TeamBuilderScreen extends StatefulWidget {
  const TeamBuilderScreen({
    super.key,
    this.importSave,
    this.initialTab,
    this.returnTab,
    this.initialLeague,
    this.server,
  });
  final String? initialTab, returnTab, server;
  final int? initialLeague;
  final GameSave? importSave;

  @override
  State<TeamBuilderScreen> createState() => _TeamBuilderScreenState();
}

class _TeamBuilderScreenState extends State<TeamBuilderScreen> {
  TeamBuilderController? _controller;
  _Tab _tab = _Tab.build;
  _Tab _returnTab = _Tab.build;
  bool _manualBuild = false;
  bool _quickAdd = false;
  bool _arenaApplied = false;
  void _selectTab(_Tab tab) {
    if (const [_Tab.box, _Tab.account, _Tab.teams].contains(tab) &&
        const [
          _Tab.build,
          _Tab.pt,
          _Tab.comparison,
          _Tab.arena,
        ].contains(_tab)) {
      _returnTab = _tab;
    }
    setState(() {
      _tab = tab;
      _controller?.activate(
        tab == _Tab.pt
            ? 'pt'
            : tab == _Tab.arena
            ? 'arena'
            : const [_Tab.box, _Tab.account, _Tab.teams].contains(tab)
            ? (_returnTab == _Tab.arena
                  ? 'arena'
                  : _returnTab == _Tab.pt
                  ? 'pt'
                  : 'build')
            : 'build',
      );
    });
  }

  String _query = '';
  String? _errorShown;
  bool _importOpened = false;

  @override
  void initState() {
    super.initState();
    _tab =
        _Tab.values
            .where(
              (tab) =>
                  (tab == _Tab.comparison ? 'song-comparison' : tab.name) ==
                      widget.initialTab ||
                  tab.name == widget.initialTab,
            )
            .firstOrNull ??
        _Tab.build;
    _returnTab =
        _Tab.values.where((tab) => tab.name == widget.returnTab).firstOrNull ??
        _Tab.build;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    final controller = _controller ??= TeamBuilderController(
      state,
      serverOverride: widget.server ?? widget.importSave?.server,
    )..addListener(_changed);
    controller.activate(
      _tab == _Tab.arena
          ? 'arena'
          : _tab == _Tab.pt
          ? 'pt'
          : 'build',
    );
    controller.load();
  }

  void _changed() {
    final c = _controller;
    if (!_importOpened &&
        widget.importSave != null &&
        c?.catalog != null &&
        c?.view != null) {
      _importOpened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          openBoxImport(
            context,
            c!,
            members: true,
            initialSave: widget.importSave,
          );
        }
      });
    }
    if (!_arenaApplied &&
        c?.catalog != null &&
        c?.view != null &&
        widget.initialLeague != null) {
      _arenaApplied = true;
      c!.updateArena({
        'leagueId': widget.initialLeague,
        'build': {...objectRow(c.arenaDraft['build']), 'songs': []},
      });
    }
    final error = _controller?.error;
    if (error != null && error != _errorShown) {
      _errorShown = error;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(error), duration: const Duration(seconds: 8)),
      );
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_changed);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller!;
    final t = c.state.text;
    final ready = c.catalog != null && c.view != null;
    final store = c.store;
    final sync = switch (store?.status) {
      BoxSyncStatus.syncing => (
        Symbols.sync_rounded,
        c.tb('syncing', 'Syncing…'),
      ),
      BoxSyncStatus.pending => (
        Symbols.schedule_rounded,
        c.tb('syncPending', 'Saving…'),
      ),
      BoxSyncStatus.synced => (
        Symbols.cloud_done_rounded,
        c.tb('synced', 'Synced'),
      ),
      BoxSyncStatus.offline => (
        Symbols.cloud_off_rounded,
        c.tb('syncOffline', 'Offline · changes are kept and sent later'),
      ),
      BoxSyncStatus.signedOut => (
        Symbols.no_accounts_rounded,
        c.tb('syncSignedOut', 'Sign in again to sync'),
      ),
      BoxSyncStatus.error => (
        Symbols.error_rounded,
        c.tb('syncError', 'Sync paused'),
      ),
      _ => (
        Symbols.save_rounded,
        c.tb('syncLocal', 'Saved on this device · sign in to sync'),
      ),
    };
    final tabs = [
      (_Tab.build, Symbols.groups_rounded, c.tb('tabBuild', 'Build'), null),
      (
        _Tab.pt,
        Symbols.emoji_events_rounded,
        c.tb('pt.tab', 'Event rewards'),
        null,
      ),
      (
        _Tab.comparison,
        Symbols.monitoring_rounded,
        c.tb('sc.tab', 'Gekiso songs'),
        null,
      ),
      (
        _Tab.arena,
        Symbols.military_tech_rounded,
        c.tb('arena.tab', 'Arena'),
        null,
      ),
    ];
    final Widget body;
    if (!ready) {
      body = Center(
        child: c.loadError != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(c.tb('loadFailed', 'Card data could not be loaded.')),
                  const SizedBox(height: 12),
                  FilledButton.tonal(
                    onPressed: c.load,
                    child: Text(t('common.actions.retry', 'Retry')),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(c.tb('loadingData', 'Loading card data')),
                ],
              ),
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (const [
            _Tab.build,
            _Tab.pt,
            _Tab.comparison,
            _Tab.arena,
          ].contains(_tab))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: PillTabs<_Tab>(
                value: _tab,
                tabs: tabs,
                onSelected: _selectTab,
              ),
            ),
          Expanded(
            child: switch (_tab) {
              _Tab.build => Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Segmented<bool>(
                      value: _manualBuild,
                      options: [
                        Choice(false, c.tb('automaticTeam', 'Find a team')),
                        Choice(
                          true,
                          c.tb('manualTeam', 'Build a team by hand'),
                        ),
                      ],
                      onSelected: (value) =>
                          setState(() => _manualBuild = value),
                    ),
                  ),
                  Expanded(
                    child: _manualBuild
                        ? TeamsTab(
                            controller: c,
                            showSaved: false,
                            onCompare: () => _selectTab(_Tab.comparison),
                          )
                        : BuildTab(controller: c),
                  ),
                ],
              ),
              _Tab.comparison => SongComparisonTab(controller: c),
              _Tab.arena => ArenaTab(controller: c),
              _Tab.pt => PtTab(
                controller: c,
                openTab: (name) =>
                    _selectTab(name == 'account' ? _Tab.account : _Tab.box),
              ),
              _Tab.box => BoxTab(
                controller: c,
                query: _query,
                quickAdd: _quickAdd,
              ),
              _Tab.account => AccountTab(controller: c),
              _Tab.teams => TeamsTab(
                controller: c,
                showEditor: false,
                onEdit: () {
                  _manualBuild = true;
                  _selectTab(_Tab.build);
                },
                onCompare: () => setState(() {
                  _tab = _Tab.comparison;
                  c.activity = false;
                }),
              ),
            },
          ),
          _Credit(controller: c),
        ],
      );
    }
    return ShellPage(
      showBack: widget.importSave != null,
      onBack: const [_Tab.box, _Tab.account, _Tab.teams].contains(_tab)
          ? () => _selectTab(_returnTab)
          : null,
      key: ValueKey(_tab == _Tab.box),
      title: const [_Tab.box, _Tab.account, _Tab.teams].contains(_tab)
          ? c.tb(
              _tab == _Tab.box
                  ? 'tabBox'
                  : _tab == _Tab.account
                  ? 'tabAccount'
                  : 'tabTeams',
              '',
            )
          : widget.importSave?.regionName == null
          ? c.tb('title', 'Team builder')
          : '${c.tb('title', 'Team builder')} · ${widget.importSave!.regionName}',
      search: ready && _tab == _Tab.box
          ? ShellSearch(
              label: t('common.actions.search', 'Search'),
              initial: _query,
              onChanged: (value) => setState(() => _query = value),
            )
          : null,
      actions: [
        if (ready) ...[
          if (_tab == _Tab.box)
            BarAction(
              icon: _quickAdd
                  ? Symbols.check_rounded
                  : Symbols.add_circle_rounded,
              label: _quickAdd
                  ? c.tb('finishQuickEntry', 'Finish adding')
                  : c.tb('quickEntry', 'Quick add'),
              selected: _quickAdd,
              showLabel: true,
              onPressed: () => setState(() => _quickAdd = !_quickAdd),
            ),
          if (_tab == _Tab.build || _tab == _Tab.pt || _tab == _Tab.arena)
            BarAction(
              icon: Symbols.compare_arrows_rounded,
              label: c.tb('compareTeams', 'Compare teams'),
              badge: c.usesPtResults ? c.ptCompared.length : c.compared.length,
              onPressed: () =>
                  showResultComparison(context, c, rewards: c.usesPtResults),
            ),
          for (final (tab, icon, key) in const [
            (_Tab.box, Symbols.style_rounded, 'tabBox'),
            (_Tab.account, Symbols.trending_up_rounded, 'tabAccount'),
            (_Tab.teams, Symbols.bookmark_rounded, 'tabTeams'),
          ])
            BarAction(
              icon: icon,
              label: c.tb(key, ''),
              selected: _tab == tab,
              onPressed: () => _selectTab(tab),
            ),
          if (_tab == _Tab.box && widget.importSave == null)
            BarAction.choice(
              label: t('common.fields.server', 'Server'),
              options: [
                for (final server in const ['jp', 'intl'])
                  BarChoice(
                    icon: Symbols.public_rounded,
                    label: c.tb('boxImport.servers.$server', server),
                    selected: c.server == server,
                    onSelected: () async {
                      ShellScope.of(context)?.navigate(
                        Uri(
                          path: '/team-builder',
                          queryParameters: {
                            'tab': 'box',
                            'return': _returnTab.name,
                          },
                        ).toString(),
                      );
                      await c.state.setServer(server);
                    },
                  ),
              ],
            ),
        ],
        if (store != null)
          HaneokaAccount.instance.signedIn &&
                  store.status != BoxSyncStatus.signedOut
              ? BarAction(
                  icon: sync.$1,
                  label: sync.$2,
                  onPressed: store.refresh,
                )
              : BarAction(
                  icon: Symbols.cloud_sync_rounded,
                  label: c.tb('syncSignIn', 'Sign in to sync'),
                  showLabel: true,
                  onPressed: () async {
                    await signInToHaneoka(context);
                    if (mounted) await store.refresh();
                  },
                ),
      ],
      body: body,
    );
  }
}

/// The engine's licence asks every interface showing its results to credit
/// the algorithm and link to haneoka.org; its source is linked as well.
class _Credit extends StatelessWidget {
  const _Credit({required this.controller});
  final TeamBuilderController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    Widget link(String label, String href) => InkWell(
      onTap: () => openLink(context, href),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          label,
          style: style?.copyWith(decoration: TextDecoration.underline),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '${controller.tb('credit', 'Team-building algorithm from Haneoka')} — ',
            style: style,
          ),
          link('haneoka.org', 'https://haneoka.org'),
          Text(' · ', style: style),
          link(
            controller.tb('creditSource', 'Source code'),
            'https://github.com/haneoka-gakuen/ournotes-team-builder',
          ),
        ],
      ),
    );
  }
}
