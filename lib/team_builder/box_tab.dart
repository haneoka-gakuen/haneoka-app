/// My cards: ownership, participation and growth, with filters, bulk
/// edits, the growth editor and import from a read save
/// (`lit/team-builder/box-tab.ts`).
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../ui/tile.dart';
import '../ui/card_artwork.dart';
import 'box.dart';
import 'catalog.dart';
import 'controller.dart';
import 'engine/box.dart';
import 'engine/num.dart';
import 'pickers.dart';
import 'box_import_screen.dart';
import 'screenshot_import_screen.dart';
import 'widgets.dart';

enum _Show { owned, all, unowned }

class BoxTab extends StatefulWidget {
  const BoxTab({super.key, required this.controller, required this.query});
  final TeamBuilderController controller;

  /// The app-bar search.
  final String query;

  @override
  State<BoxTab> createState() => _BoxTabState();
}

class _BoxTabState extends State<BoxTab> {
  bool _members = true;
  _Show _show = _Show.owned;
  CardFilters _filters = const CardFilters();
  bool _filtersOpen = false;

  /// Quick add: tapping a card marks it owned (or drops it) instead of
  /// opening the growth editor (`box-tab.ts` Quick add).
  bool _quickAdd = false;

  TeamBuilderController get c => widget.controller;

  String _prefix(bool members) => members ? 'm' : 's';

  /// Bulk edits keep the previous values for one undo.
  void _bulk(String label, List<(String, Object?)> changes) {
    final store = c.store;
    if (changes.isEmpty || store == null) return;
    final owner = store.owner;
    final previous = [for (final (key, _) in changes) (key, store.value(key))];
    if (!c.write(changes)) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(label),
          action: SnackBarAction(
            label: c.tb('undo', 'Undo'),
            onPressed: () {
              if (c.store == store && store.owner == owner) c.write(previous);
            },
          ),
        ),
      );
  }

  Future<void> _clearOwnership() async {
    final store = c.store;
    if (store == null) return;
    final owner = store.owner;
    final changes = [
      for (final entry in store.entries.entries)
        if (RegExp(r'^[ms]\.[1-9]\d*\.own$').hasMatch(entry.key) &&
            entry.value.v == true)
          (entry.key, false),
    ];
    if (changes.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          c.tb('clearOwnership', 'Mark all members and snapshots not owned'),
        ),
        content: Text(
          c.tb(
            'clearOwnershipScope',
            '{count} owned cards. Training values, account bonuses, teams and preferences stay saved.',
            {'count': changes.length},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(c.state.text('common.actions.cancel', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(c.tb('clearOwnershipConfirm', 'Mark all not owned')),
          ),
        ],
      ),
    );
    if (!mounted ||
        confirmed != true ||
        c.store != store ||
        store.owner != owner) {
      return;
    }
    _bulk(
      c.tb(
        'clearedOwnership',
        'Marked {count} members and snapshots not owned',
        {'count': changes.length},
      ),
      changes,
    );
  }

  List<(String, Object?)> _maxChanges(bool members, int id) {
    final catalog = c.catalog!;
    final p = _prefix(members);
    if (members) {
      final limits = catalog.memberLimits(id, null);
      if (limits == null) return const [];
      return [
        ('$p.$id.own', true),
        ('$p.$id.lvl', limits.level),
        ('$p.$id.awk', limits.awake),
        ('$p.$id.rnk', limits.rank),
        ('$p.$id.sk', limits.liveSkillLevel),
        ('$p.$id.gsk', limits.gekisoSkillLevel),
      ];
    }
    final limits = catalog.snapLimits(id, null);
    if (limits == null) return const [];
    return [
      ('$p.$id.own', true),
      ('$p.$id.lvl', limits.level),
      ('$p.$id.rnk', limits.rank),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final catalog = c.catalog!;
    final view = c.view!;
    final theme = Theme.of(context);
    final filters = _filters.copyWith(query: widget.query);
    final owned = _members ? view.members : view.snaps;
    final ids =
        [
          for (final key in (objectRow(
            catalog.data[_members ? 'members' : 'snapshots'],
          )).keys)
            if (int.tryParse(key) case final id?)
              if ((_show == _Show.all ||
                      (_show == _Show.owned) == owned.containsKey(id)) &&
                  filters.matches(catalog, _members, id))
                id,
        ]..sort((a, b) {
          final rarity =
              catalog.rarity(_members, b) - catalog.rarity(_members, a);
          return rarity != 0 ? rarity : b - a;
        });
    final ownedShown = [
      for (final id in ids)
        if (owned.containsKey(id)) id,
    ];
    final used = owned.values
        .where(
          (row) => switch (row) {
            OwnedMember(:final use) => use,
            OwnedSnap(:final use) => use,
            _ => false,
          },
        )
        .length;
    final p = _prefix(_members);
    // On a phone the bulk actions stay on one line that scrolls sideways.
    Widget bulkRow(List<Widget> children) =>
        MediaQuery.sizeOf(context).width <= 760
        ? SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: children),
          )
        : Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: children,
          );
    final toolbar = ToolSection(
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: true,
                  icon: const Icon(Symbols.person_rounded),
                  label: Text(
                    '${c.tb('members', 'Members')} ${view.members.length}',
                  ),
                ),
                ButtonSegment(
                  value: false,
                  icon: const Icon(Symbols.photo_rounded),
                  label: Text(
                    '${c.tb('snapshots', 'Snaps')} ${view.snaps.length}',
                  ),
                ),
              ],
              selected: {_members},
              onSelectionChanged: (value) =>
                  setState(() => _members = value.single),
            ),
            SegmentedButton<_Show>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: _Show.owned,
                  label: Text(c.tb('showOwned', 'Owned')),
                ),
                ButtonSegment(
                  value: _Show.all,
                  label: Text(c.tb('showAll', 'All')),
                ),
                ButtonSegment(
                  value: _Show.unowned,
                  label: Text(c.tb('showUnowned', 'Not owned')),
                ),
              ],
              selected: {_show},
              onSelectionChanged: (value) =>
                  setState(() => _show = value.single),
            ),
            IconButton(
              tooltip: c.tb('filters', 'Filters'),
              isSelected: _filtersOpen,
              onPressed: () => setState(() => _filtersOpen = !_filtersOpen),
              icon: Badge(
                isLabelVisible: _filters.active > 0,
                label: Text('${_filters.active}'),
                child: const Icon(Symbols.filter_list_rounded),
              ),
            ),
            IconButton.filledTonal(
              tooltip: _quickAdd
                  ? c.tb('quickAddDone', 'Finish quick add')
                  : c.tb('quickAdd', 'Quick add'),
              isSelected: _quickAdd,
              onPressed: () => setState(() => _quickAdd = !_quickAdd),
              icon: Icon(
                _quickAdd
                    ? Symbols.check_circle_rounded
                    : Symbols.add_circle_outline_rounded,
              ),
            ),
            if (_quickAdd)
              Chip(
                avatar: const Icon(Symbols.touch_app_rounded, size: 18),
                label: Text(c.tb('quickAddHint', 'Tap to add or remove')),
              ),
          ],
        ),
        if (_filtersOpen)
          CardFilterPanel(
            catalog: catalog,
            filters: _filters,
            onChanged: (value) => setState(() => _filters = value),
          ),
        const Divider(height: 1),
        bulkRow([
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              c.tb(
                'boxSummary',
                '{owned} owned · {used} in search · {shown} shown',
                {'owned': owned.length, 'used': used, 'shown': ids.length},
              ),
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: ids.isEmpty
                ? null
                : () => _bulk(
                    c.tb('bulkOwned', 'Marked {count} cards as owned', {
                      'count': ids.length,
                    }),
                    [
                      for (final id in ids) ...[
                        ('$p.$id.own', true),
                        if (!owned.containsKey(id)) ('$p.$id.use', true),
                      ],
                    ],
                  ),
            icon: const Icon(Symbols.library_add_check_rounded),
            label: Text(c.tb('bulkOwn', 'Own all shown')),
          ),
          TextButton.icon(
            onPressed: ownedShown.isEmpty
                ? null
                : () => _bulk(
                    c.tb('bulkUsedDone', '{count} cards take part', {
                      'count': ownedShown.length,
                    }),
                    [for (final id in ownedShown) ('$p.$id.use', true)],
                  ),
            icon: const Icon(Symbols.check_box_rounded),
            label: Text(c.tb('bulkUse', 'Use all')),
          ),
          TextButton.icon(
            onPressed: ownedShown.isEmpty
                ? null
                : () => _bulk(
                    c.tb('bulkUnusedDone', '{count} cards left out', {
                      'count': ownedShown.length,
                    }),
                    [for (final id in ownedShown) ('$p.$id.use', false)],
                  ),
            icon: const Icon(Symbols.check_box_outline_blank_rounded),
            label: Text(c.tb('bulkUnuse', 'Use none')),
          ),
          TextButton.icon(
            onPressed: ownedShown.isEmpty
                ? null
                : () => _bulk(
                    c.tb('bulkMaxDone', 'Set {count} cards to full growth', {
                      'count': ownedShown.length,
                    }),
                    [for (final id in ownedShown) ..._maxChanges(_members, id)],
                  ),
            icon: const Icon(Symbols.upgrade_rounded),
            label: Text(c.tb('bulkMax', 'Full growth')),
          ),
          TextButton(
            onPressed: c.view!.members.isEmpty && c.view!.snaps.isEmpty
                ? null
                : _clearOwnership,
            child: Text(
              c.tb(
                'clearOwnership',
                'Mark all members and snapshots not owned',
              ),
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: () => openBoxImport(context, c, members: _members),
            icon: const Icon(Symbols.upload_file_rounded),
            label: Text(c.tb('importBox', 'Import')),
          ),
          FilledButton.tonalIcon(
            onPressed: () => openScreenshotImport(context, c),
            icon: const Icon(Symbols.photo_camera_rounded),
            label: Text(c.tb('importScreens', 'Screenshots')),
          ),
          TextButton.icon(
            onPressed: () => exportBox(c),
            icon: const Icon(Symbols.download_rounded),
            label: Text(c.state.text('common.actions.export', 'Export')),
          ),
        ]),
      ],
    );
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          sliver: SliverToBoxAdapter(child: toolbar),
        ),
        if (ids.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                children: [
                  Text(
                    _show == _Show.owned && owned.isEmpty
                        ? c.tb('emptyBox', 'No cards yet')
                        : c.tb('noMatches', 'No cards match'),
                    style: theme.textTheme.titleMedium,
                  ),
                  if (_show == _Show.owned && owned.isEmpty) ...[
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton(
                          onPressed: () => setState(() => _show = _Show.all),
                          child: Text(c.tb('showAll', 'All')),
                        ),
                        FilledButton.tonal(
                          onPressed: () =>
                              openBoxImport(context, c, members: _members),
                          child: Text(c.tb('importBox', 'Import')),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) => SliverGrid(
                gridDelegate: collectionGrid(
                  context,
                  constraints.crossAxisExtent,
                  minWidth: _members ? 136 : 220,
                  aspectRatio: _members ? 3 / 4 : 16 / 9,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) =>
                      _card(context, catalog, ids[index], owned[ids[index]]),
                  childCount: ids.length,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _card(
    BuildContext context,
    TeamCatalog catalog,
    int id,
    Object? owned,
  ) {
    final using = switch (owned) {
      OwnedMember(:final use) => use,
      OwnedSnap(:final use) => use,
      _ => false,
    };
    final locked = switch (owned) {
      OwnedMember(:final lock) => lock,
      OwnedSnap(:final lock) => lock,
      _ => false,
    };
    final policy = c.settings.unknownPolicy == 'min'
        ? UnknownPolicy.min
        : UnknownPolicy.max;
    final growth = catalog.ownedGrowth(_members, owned, policy);
    final p = _prefix(_members);
    final label = owned == null
        ? c.tb('markOwned', 'Mark as owned')
        : c.tb('useInSearch', 'Use in team search');
    final tile = Tile(
      title: catalog.cardName(_members, id),
      subtitle: catalog.cardSubtitle(_members, id),
      adornments: [
        for (final character in catalog.characterIds(_members, id))
          catalog.characterFace(character),
      ],
      images: [catalog.cardImage(_members, id)],
      media: CardArtwork(
        kind: _members ? GameCardKind.member : GameCardKind.support,
        image: catalog.cardImage(_members, id),
        attribute: catalog.attributeIcon(catalog.attribute(_members, id)),
        attributeLabel: catalog.attributeName(catalog.attribute(_members, id)),
        rarity: catalog.rarityIcon(catalog.rarity(_members, id)),
        growth: growth,
      ),
      fit: BoxFit.cover,
      aspectRatio: _members ? 3 / 4 : 16 / 9,
      serverMark: catalog.mark(_members ? 'members' : 'snapshots', id),
      marks: [
        if (owned == null)
          TileMark.text(MarkAt.bottomStart, c.tb('notOwned', 'Not owned')),
      ],
      onTap: () {
        if (!_quickAdd) {
          showCardEditor(context, c, members: _members, id: id);
          return;
        }
        final name = catalog.cardName(_members, id);
        _bulk(
          owned == null
              ? c.tb('quickAddOwned', 'Quick added {name}', {'name': name})
              : c.tb('quickAddDropped', 'Quick dropped {name}', {'name': name}),
          owned == null
              ? [('$p.$id.own', true), ('$p.$id.use', true)]
              : [('$p.$id.own', false)],
        );
      },
      action: Material(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
        shape: const CircleBorder(),
        child: Checkbox(
          semanticLabel: label,
          value: using,
          onChanged: (_) => c.write(
            owned == null
                ? [('$p.$id.own', true), ('$p.$id.use', true)]
                : [('$p.$id.use', !using)],
          ),
        ),
      ),
    );
    return Opacity(
      opacity: owned == null ? 0.6 : 1,
      child: locked
          ? Stack(
              children: [
                tile,
                const Positioned(
                  top: 8,
                  left: 8,
                  child: Icon(Symbols.push_pin_rounded, size: 18, fill: 1),
                ),
              ],
            )
          : tile,
    );
  }
}

/// Growth editor; every change is saved at once.
Future<void> showCardEditor(
  BuildContext context,
  TeamBuilderController c, {
  required bool members,
  required int id,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) =>
        _CardEditor(controller: c, members: members, id: id),
  ),
);

class _CardEditor extends StatelessWidget {
  const _CardEditor({
    required this.controller,
    required this.members,
    required this.id,
  });
  final TeamBuilderController controller;
  final bool members;
  final int id;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final catalog = c.catalog!;
    final view = c.view!;
    final theme = Theme.of(context);
    final p = members ? 'm' : 's';
    final Object? owned = members ? view.members[id] : view.snaps[id];
    void write(String field, Object? value) {
      final changes = <(String, Object?)>[('$p.$id.$field', value)];
      // Lowering training or limit break lowers the cap; a higher level cannot exist.
      final capField = members ? 'awk' : 'rnk';
      final level = switch (owned) {
        OwnedMember(:final level) => level,
        OwnedSnap(:final level) => level,
        _ => null,
      };
      if (field == capField && value is int && level != null) {
        final cap =
            (members
                    ? catalog.memberLimits(id, value)
                    : catalog.snapLimits(id, value))
                ?.levelCap;
        if (cap != null && level > cap) changes.add(('$p.$id.lvl', cap));
      }
      c.write([
        if (owned == null) ...[('$p.$id.own', true), ('$p.$id.use', true)],
        ...changes,
      ]);
    }

    Widget steps(String label, String field, int? value, int max) => ToolField(
      label: label,
      child: Segmented<int>(
        value: value ?? -1,
        grow: false,
        options: [for (var i = 1; i <= max; i++) Choice(i, '$i')],
        onSelected: (next) => write(field, next),
      ),
    );
    Widget level(int? value, int cap) => ToolField(
      label: c.tb('level', 'Level'),
      value: '${value == null ? '—' : value.clamp(1, cap)} / $cap',
      child: _CardLevel(
        key: ValueKey('$p.$id.lvl'),
        label: c.tb('level', 'Level'),
        value: value,
        cap: cap,
        maxLabel: c.tb('maxLevel', 'Max level'),
        onChanged: (next) => write('lvl', next),
      ),
    );
    final fields = <Widget>[];
    if (owned is OwnedMember || (members && owned == null)) {
      final row = owned as OwnedMember?;
      final limits = catalog.memberLimits(id, row?.awake);
      if (limits != null) {
        fields.addAll([
          steps(c.tb('training', 'Training'), 'awk', row?.awake, limits.awake),
          level(row?.level, limits.levelCap),
          steps(c.tb('awakening', 'Awakening'), 'rnk', row?.rank, limits.rank),
          steps(
            c.tb('liveSkill', 'Live skill'),
            'sk',
            row?.skill,
            limits.liveSkillLevel,
          ),
          if ((catalog.master.members[id]?.gekisoSkillId ?? 0) != 0)
            steps(
              c.tb('gekisoSkill', 'Gekiso skill'),
              'gsk',
              row?.gekisoSkill,
              limits.gekisoSkillLevel,
            ),
        ]);
      }
    } else {
      final row = owned as OwnedSnap?;
      final limits = catalog.snapLimits(id, row?.rank);
      if (limits != null) {
        fields.addAll([
          steps(
            c.tb('limitBreak', 'Limit break'),
            'rnk',
            row?.rank,
            limits.rank,
          ),
          level(row?.level, limits.levelCap),
        ]);
      }
    }
    final use = switch (owned) {
      OwnedMember(:final use) => use,
      OwnedSnap(:final use) => use,
      _ => false,
    };
    final lock = switch (owned) {
      OwnedMember(:final lock) => lock,
      OwnedSnap(:final lock) => lock,
      _ => false,
    };
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: members ? 72 : 128,
                  child: CardArt(catalog: catalog, members: members, id: id),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        catalog.cardName(members, id),
                        style: theme.textTheme.titleLarge,
                      ),
                      Text(
                        catalog.cardSubtitle(members, id),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (owned == null) ...[
                        const SizedBox(height: 8),
                        Chip(
                          label: Text(
                            c.tb(
                              'notOwnedYet',
                              'Not owned yet: any change adds it',
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            for (final field in fields) ...[field, const SizedBox(height: 12)],
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: use,
              onChanged: (value) => write('use', value == true),
              title: Text(c.tb('useInSearch', 'Use in team search')),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: lock,
              onChanged: (value) => write('lock', value == true),
              title: Text(c.tb('required', 'Always include')),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () {
                    final limits = members
                        ? catalog.memberLimits(id, null)
                        : catalog.snapLimits(id, null);
                    if (limits == null) return;
                    c.write([
                      if (owned == null) ...[
                        ('$p.$id.own', true),
                        ('$p.$id.use', true),
                      ],
                      ('$p.$id.lvl', limits.level),
                      ('$p.$id.rnk', limits.rank),
                      if (members) ...[
                        ('$p.$id.awk', limits.awake),
                        ('$p.$id.sk', limits.liveSkillLevel),
                        ('$p.$id.gsk', limits.gekisoSkillLevel),
                      ],
                    ]);
                  },
                  icon: const Icon(Symbols.upgrade_rounded),
                  label: Text(c.tb('fullGrowth', 'Full growth')),
                ),
                if (owned != null)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    onPressed: () {
                      c.write([('$p.$id.own', false), ('$p.$id.lock', false)]);
                      Navigator.of(context).pop();
                    },
                    icon: const Icon(Symbols.remove_circle_rounded),
                    label: Text(c.tb('removeOwned', 'Not owned')),
                  ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(c.tb('done', 'Done')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CardLevel extends StatefulWidget {
  const _CardLevel({
    super.key,
    required this.label,
    required this.value,
    required this.cap,
    required this.maxLabel,
    required this.onChanged,
  });
  final String label, maxLabel;
  final int? value;
  final int cap;
  final ValueChanged<int?> onChanged;

  @override
  State<_CardLevel> createState() => _CardLevelState();
}

class _CardLevelState extends State<_CardLevel> {
  late final _text = TextEditingController(text: _valueText);
  final _focus = FocusNode();

  String get _valueText =>
      widget.value == null ? '' : '${widget.value!.clamp(1, widget.cap)}';

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  void _focusChanged() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    if (_text.text.isEmpty) {
      if (widget.value != null) widget.onChanged(null);
      return;
    }
    final parsed = int.tryParse(_text.text);
    if (parsed == null) {
      _text.text = _valueText;
      return;
    }
    _choose(parsed.clamp(1, widget.cap));
  }

  void _choose(int value) {
    if (_text.text != '$value') _text.text = '$value';
    if (value != widget.value) widget.onChanged(value);
  }

  @override
  void didUpdateWidget(_CardLevel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus && _text.text != _valueText) {
      _text.text = _valueText;
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 72,
        child: Semantics(
          label: widget.label,
          child: TextField(
            controller: _text,
            focusNode: _focus,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              hintText: '—',
              border: const OutlineInputBorder(),
            ),
            onChanged: (text) {
              final value = int.tryParse(text);
              if (text.isEmpty) {
                widget.onChanged(null);
              } else if (value != null && value >= 1 && value <= widget.cap) {
                widget.onChanged(value);
              }
            },
            onSubmitted: (_) => _commit(),
            onTapOutside: (_) => _focus.unfocus(),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Semantics(
          label: widget.label,
          child: Slider(
            min: 1,
            max: widget.cap.toDouble(),
            divisions: widget.cap > 1 ? widget.cap - 1 : null,
            value: (widget.value ?? widget.cap).clamp(1, widget.cap).toDouble(),
            label: '${widget.value ?? widget.cap}',
            onChanged: widget.cap > 1 ? (v) => _choose(v.round()) : null,
            onChangeEnd: widget.cap > 1 ? (v) => _choose(v.round()) : null,
          ),
        ),
      ),
      IconButton(
        tooltip: widget.maxLabel,
        onPressed: widget.value == widget.cap
            ? null
            : () => _choose(widget.cap),
        icon: const Icon(Symbols.vertical_align_top_rounded),
      ),
    ],
  );
}

/// Saves the box as the website's inventory document
/// (`haneoka-team-inventory-v2`), which its import reads back.
Future<void> exportBox(TeamBuilderController c) async {
  final view = c.view, catalog = c.catalog;
  if (view == null || catalog == null) return;
  final identity = objectRow(catalog.data['identity']);
  final document = {
    'schema': 'haneoka-team-inventory-v2',
    'server': identity['server'],
    'releaseId': identity['releaseId'],
    'members': [
      for (final row in view.members.values)
        if (catalog.has(true, row.cardId))
          {
            'instanceId': 'm${row.cardId}',
            'cardId': row.cardId,
            'level': row.level,
            'training': row.awake,
            'awakening': row.rank,
            'liveSkillLevel': row.skill,
            'gekisoSkillLevel': row.gekisoSkill,
            'locked': row.lock,
            'excluded': !row.use,
          },
    ],
    'snapshots': [
      for (final row in view.snaps.values)
        if (catalog.has(false, row.cardId))
          {
            'instanceId': 's${row.cardId}',
            'cardId': row.cardId,
            'level': row.level,
            'awakening': row.rank,
            'locked': row.lock,
            'excluded': !row.use,
          },
    ],
    'bandItems': view.player.bandItems,
    'characterRanks': view.player.characterRanks,
    'bandRanks': view.bandRanks,
    'playerModifiers': {
      'characterTotalRank': view.player.characterTotalRank,
      'vipRank': view.player.vipRank,
      'musicMemoryPoints': view.player.musicMemory,
      'characterMemoryPoints': view.player.characterMemory,
    },
  };
  final bytes = Uint8List.fromList(
    utf8.encode(const JsonEncoder.withIndent('  ').convert(document)),
  );
  await FilePicker.saveFile(
    fileName: 'haneoka-team-box-${identity['server']}.json',
    bytes: bytes,
    type: FileType.custom,
    allowedExtensions: const ['json'],
  );
}
