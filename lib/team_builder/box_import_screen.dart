/// The card data import dialog (`renderBoxImportDialog` in
/// `lit/shared/team-box-import.ts`, `ImportController` in
/// `lit/team-builder/importers.ts`): read saves on this device, files or
/// pasted text, then review each entry before anything is written.
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../l10n/app_localizations.dart';
import '../save/account_store.dart';
import '../save/game_save.dart';
import 'box_import.dart';
import 'controller.dart';
import 'screenshot_import_screen.dart';
import 'widgets.dart';

Future<List<BoxCandidate>> _parseFiles(List<Uint8List> data) =>
    Isolate.run(() => parseBoxFiles(data));
Future<List<BoxCandidate>> _parseText(String text) =>
    Isolate.run(() => parseBoxText(text));

Future<void> openBoxImport(
  BuildContext context,
  TeamBuilderController c, {
  required bool members,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _BoxImportScreen(c: c, members: members),
  ),
);

enum _Phase { select, parsing, choose, review }

class _BoxImportScreen extends StatefulWidget {
  const _BoxImportScreen({required this.c, required this.members});
  final TeamBuilderController c;
  final bool members;

  @override
  State<_BoxImportScreen> createState() => _BoxImportScreenState();
}

class _BoxImportScreenState extends State<_BoxImportScreen> {
  TeamBuilderController get c => widget.c;
  final _text = TextEditingController();
  var _phase = _Phase.select;
  List<BoxCandidate> _candidates = const [];
  String? _candidate;
  BoxPreview? _preview;
  BoxConfirmation? _confirmation;
  String? _error;
  int _generation = 0;
  List<GameSave> _saves = const [];
  bool _mapsOpen = false, _issuesOpen = false;

  String _t(String key, String fallback, [Map<String, Object?> v = const {}]) {
    final t = c.state.text;
    if (key.startsWith('existing')) {
      return t(
        'tools.teamBuilder.importExisting.${key.substring(8).toLowerCase()}',
        fallback,
        v,
      );
    }
    if (const {'close', 'cancel', 'clear'}.contains(key)) {
      return t(
        key == 'clear' ? 'common.actions.clear' : 'common.actions.$key',
        fallback,
        v,
      );
    }
    if (const {'members', 'snapshots', 'unknown'}.contains(key)) {
      return c.tb(key, fallback, v);
    }
    return t('tools.teamBuilder.boxImport.$key', fallback, v);
  }

  @override
  void initState() {
    super.initState();
    AccountStore.instance.load().then((_) {
      if (!mounted) return;
      setState(
        () => _saves = [
          for (final save in AccountStore.instance.saves)
            if (save.release?.server == c.state.server) save,
        ],
      );
    });
  }

  @override
  void dispose() {
    ++_generation;
    _text.dispose();
    super.dispose();
  }

  String _errorText(String code) {
    if (code == 'box_review_changed') {
      return _t(
        'changed',
        'Your account, data or inventory changed. Open the import again.',
      );
    }
    if (code == 'box_no_player') {
      return _t('empty', 'No supported card entries found.');
    }
    if (code == 'box_invalid_list') {
      return _t(
        'invalidList',
        'Choose one CSV or TSV file up to 1 MiB, or paste a card list with IDs, names and levels.',
      );
    }
    if (code.endsWith('_budget')) {
      return _t(
        'tooLarge',
        'This file exceeds the supported size or record limit.',
      );
    }
    if (const {
      'box_conflict_required',
      'box_unconfirmed_value',
      'box_unresolved_values',
      'box_invalid_confirmed_inventory',
    }.contains(code)) {
      return _t(
        'reviewValues',
        'Review the selected training values or exclude the affected entries.',
      );
    }
    if (code == 'box_worker_failed') {
      return _t(
        'failed',
        'Local parsing failed. Check the file and try again.',
      );
    }
    return _t(
      'invalidFormat',
      'This file is not a supported card-data format.',
    );
  }

  void _review(BoxPreview preview, {bool maps = true}) {
    _preview = preview;
    _confirmation = BoxConfirmation.all(preview, maps: maps);
    _phase = _Phase.review;
    _recheck();
  }

  /// `reconfirm`: the merge is the final check of every choice.
  void _recheck() {
    final preview = _preview, confirmation = _confirmation;
    if (preview == null || confirmation == null) return;
    _error = null;
    if (confirmation.cards.values.any((r) => r.include) ||
        confirmation.maps.values.any((r) => r.include)) {
      try {
        if (!canConfirmReview(preview, confirmation)) {
          throw const BoxImportError('box_unresolved_values');
        }
        applyBoxImport(c.view!, preview, confirmation, c.catalog!.master);
      } on BoxImportError catch (error) {
        _error = error.code;
      }
    }
  }

  void _select(String id) {
    final candidate = _candidates.where((r) => r.id == id).firstOrNull;
    if (candidate == null) return;
    setState(() {
      try {
        _candidate = id;
        _review(
          previewBoxImport(
            candidate,
            c.view!,
            c.catalog!.master,
            c.catalog!.data,
            c.state.server,
          ),
        );
      } on BoxImportError catch (error) {
        _phase = _Phase.choose;
        _error = error.code;
      }
    });
  }

  Future<void> _parse(Future<List<BoxCandidate>> Function() read) async {
    final generation = ++_generation;
    setState(() {
      _phase = _Phase.parsing;
      _error = null;
      _preview = null;
    });
    try {
      final candidates = await read();
      if (generation != _generation || !mounted) return;
      setState(() {
        _candidates = candidates;
        _phase = _Phase.choose;
      });
      if (candidates.length == 1) _select(candidates.single.id);
    } on BoxImportError catch (error) {
      if (generation != _generation || !mounted) return;
      setState(() {
        _phase = _Phase.select;
        _error = error.code;
      });
    } catch (_) {
      if (generation != _generation || !mounted) return;
      setState(() {
        _phase = _Phase.select;
        _error = 'box_worker_failed';
      });
    }
  }

  void _list(String text) {
    setState(() {
      try {
        _review(
          previewInventoryList(
            text,
            c.view!,
            c.catalog!.master,
            c.catalog!.data,
            c.state.server,
            widget.members,
          ),
          maps: false,
        );
      } on BoxImportError catch (error) {
        _phase = _Phase.select;
        _error = error.code;
      }
    });
  }

  void _readSave(GameSave save) {
    final player = save.player;
    _parse(() async {
      final candidate = projectBox({'_player': player}, 'encrypted-player');
      if (candidate == null) throw const BoxImportError('box_no_player');
      return [candidate];
    });
  }

  Future<void> _files() async {
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty || !mounted) return;
    final files = picked;
    if (files.any((f) => isInventoryListFile(f.name))) {
      if (files.length != 1) {
        setState(() => _error = 'box_invalid_list');
        return;
      }
      final file = files.single;
      final bytes = await file.readAsBytes();
      if (bytes.length > 1024 * 1024) {
        setState(() => _error = 'box_invalid_list');
        return;
      }
      String text;
      try {
        text = utf8.decode(bytes);
      } on FormatException {
        setState(() => _error = 'box_invalid_list');
        return;
      }
      _list(text);
      return;
    }
    final data = <Uint8List>[
      for (final file in files) await file.readAsBytes(),
    ];
    await _parse(() => _parseFiles(data));
  }

  void _pasted() {
    final text = _text.text;
    if (text.trim().isEmpty) return;
    if (isInventoryListText(text)) {
      _list(text);
    } else {
      _parse(() => _parseText(text));
    }
  }

  void _confirm() {
    final preview = _preview, confirmation = _confirmation;
    if (preview == null || confirmation == null) return;
    try {
      final view = c.view;
      if (view == null) throw const BoxImportError('box_review_changed');
      final changes = [
        for (final change in applyBoxImport(
          view,
          preview,
          confirmation,
          c.catalog!.master,
        ))
          if (c.store!.value(change.$1) != change.$2) change,
      ];
      c.write(changes);
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            c.tb('imported', 'Imported {count} changes', {
              'count': changes.length,
            }),
          ),
        ),
      );
    } on BoxImportError catch (error) {
      setState(() => _error = error.code);
    }
  }

  String _fieldName(String field) => c.tb(switch (field) {
    'liveSkillLevel' => 'liveSkill',
    'gekisoSkillLevel' => 'gekisoSkill',
    _ => field,
  }, field);

  String _mapName(bool characters, int id) {
    final catalog = c.catalog!;
    final name = characters
        ? catalog.characterName(id)
        : catalog.text(
            (catalog.data['bandItems'] as Map?)?['$id'] is Map
                ? ((catalog.data['bandItems'] as Map)['$id'] as Map)['name']
                : null,
          );
    return name.isEmpty ? c.tb('unknown', 'Unknown or not entered') : name;
  }

  String _sourceLabel(ValueSource source) => switch (source) {
    ValueSource.box => _t('boxValue', 'Imported value'),
    ValueSource.saved => _t('keep', 'Keep saved value'),
    ValueSource.conflict => _t('chooseValue', 'Choose a value'),
    ValueSource.unknown => _t('unknown', 'Unknown'),
  };

  Widget _fieldControl(BoxCardProposal card, ReviewField row) {
    final confirmation = _confirmation!;
    final selected = confirmation.card(card.key).fields[row.field];
    final caption =
        '${_sourceLabel(row.defaultSource)}${row.defaultValue == null ? '' : ': ${row.defaultValue}'}';
    if (row.values.isEmpty) {
      return Text(
        '${_fieldName(row.field)} · ${_sourceLabel(row.source)}${row.value == null ? '' : ': ${row.value}'}',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    final keepLabel =
        '${_t('keep', 'Keep saved value')}: ${card.existing(row.field) ?? _t('unknown', 'Unknown')}';
    final current = switch (selected) {
      KeepChoice() => 'keep',
      ValueChoice(:final value) => '$value',
      null => 'auto',
    };
    return DropdownMenu<String>(
      key: ValueKey('${card.key}.${row.field}.$current'),
      label: Text(_fieldName(row.field)),
      initialSelection: current,
      width: 220,
      errorText: row.requiresChoice ? '' : null,
      onSelected: (value) => setState(() {
        final fields = confirmation.card(card.key).fields;
        switch (value) {
          case 'auto' || null:
            fields.remove(row.field);
          case 'keep':
            fields[row.field] = const KeepChoice();
          default:
            fields[row.field] = ValueChoice(int.parse(value));
        }
        _recheck();
      }),
      dropdownMenuEntries: [
        DropdownMenuEntry(value: 'auto', label: caption),
        if (card.owned != null)
          DropdownMenuEntry(value: 'keep', label: keepLabel),
        for (final value in row.values)
          DropdownMenuEntry(value: '$value', label: '$value'),
      ],
    );
  }

  Widget _cardRow(BoxCardProposal card) {
    final theme = Theme.of(context);
    final catalog = c.catalog!;
    final preview = _preview!, confirmation = _confirmation!;
    final choice = confirmation.card(card.key);
    final blocked = preview.blocked(card);
    final rows = reviewCard(card, choice, confirmation.policy);
    final known = catalog.has(card.members, card.cardId);
    void toggle(bool include) => setState(() {
      choice.include = include;
      _recheck();
    });
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: card.members ? 72 : 112,
              child: InkWell(
                onTap: blocked && !choice.include
                    ? null
                    : () => toggle(!choice.include),
                borderRadius: BorderRadius.circular(8),
                child: known
                    ? CardArt(
                        catalog: catalog,
                        members: card.members,
                        id: card.cardId,
                      )
                    : const SizedBox.shrink(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (known)
                    Text(
                      catalog.cardName(card.members, card.cardId),
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    value: choice.include,
                    onChanged: blocked && !choice.include
                        ? null
                        : (value) => toggle(value ?? false),
                    title: Text(_t('include', 'Include')),
                  ),
                  if (blocked)
                    Text(
                      _t('review', 'Needs review'),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final row in rows) _fieldControl(card, row),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mapRow(BoxMapProposal map) {
    final theme = Theme.of(context);
    final preview = _preview!, confirmation = _confirmation!;
    final choice = confirmation.map(map.key);
    final blocked = preview.mapBlocked(map);
    final review = reviewMap(map, choice, confirmation.policy);
    final current = switch (choice.value) {
      KeepChoice() => 'keep',
      ValueChoice(:final value) => '$value',
      null => 'auto',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 240,
            child: CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              value: choice.include,
              onChanged: blocked && !choice.include
                  ? null
                  : (value) => setState(() {
                      choice.include = value ?? false;
                      _recheck();
                    }),
              title: Text(_mapName(map.characters, map.id)),
            ),
          ),
          Text(
            '${_t('saved', 'Saved')}: ${map.existing ?? _t('unknown', 'Unknown')}',
            style: theme.textTheme.bodySmall,
          ),
          DropdownMenu<String>(
            key: ValueKey('${map.key}.$current'),
            label: Text(_t('boxValue', 'Imported value')),
            width: 200,
            initialSelection: current,
            errorText: review.requiresChoice && choice.include ? '' : null,
            onSelected: (value) => setState(() {
              choice.value = switch (value) {
                'auto' || null => null,
                'keep' => const KeepChoice(),
                _ => ValueChoice(int.parse(value)),
              };
              _recheck();
            }),
            dropdownMenuEntries: [
              DropdownMenuEntry(
                value: 'auto',
                label: review.defaultValue == null
                    ? map.exists &&
                              confirmation.policy != ExistingPolicy.overwrite
                          ? _t('unknown', 'Unknown')
                          : _t('chooseValue', 'Choose a value')
                    : '${review.defaultValue}',
              ),
              if (map.exists)
                DropdownMenuEntry(
                  value: 'keep',
                  label:
                      '${_t('keep', 'Keep saved value')}: ${map.existing ?? _t('unknown', 'Unknown')}',
                ),
              for (final value in map.values)
                DropdownMenuEntry(value: '$value', label: '$value'),
            ],
          ),
        ],
      ),
    );
  }

  String _issueText(BoxIssue issue) {
    final subject = switch (issue.kind) {
      'input' =>
        issue.field == 'row'
            ? _t('listRow', 'Row {row}', {'row': issue.id})
            : _t('review', 'Needs review'),
      'members' || 'snapshots' => () {
        final members = issue.kind == 'members';
        final name = c.catalog!.has(members, issue.id)
            ? c.catalog!.cardName(members, issue.id)
            : '';
        return name.isNotEmpty
            ? name
            : '${_t(issue.kind, issue.kind)} #${issue.id}';
      }(),
      'bandItems' ||
      'characterRanks' => _mapName(issue.kind == 'characterRanks', issue.id),
      _ => _t('review', 'Needs review'),
    };
    final detail = issue.field == 'row'
        ? _t(
            'listRowCheck',
            'Check the card ID, name, type and training values in this row.',
          )
        : '${_fieldName(issue.field)} · ${_t('review', 'Needs review')}';
    return '$subject · $detail';
  }

  Widget _selectBody(ThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      OutlinedButton.icon(
        onPressed: () {
          final navigator = Navigator.of(context);
          navigator.pop();
          openScreenshotImport(navigator.context, c);
        },
        icon: const Icon(Symbols.photo_camera_rounded),
        label: Text(_t('screenshots', 'Screenshots')),
      ),
      const SizedBox(height: 8),
      for (final save in _saves) ...[
        OutlinedButton.icon(
          onPressed: () => _readSave(save),
          icon: const Icon(Symbols.sports_esports_rounded),
          label: Text('${save.name ?? save.profileId} · ${save.profileId}'),
        ),
        const SizedBox(height: 8),
      ],
      if (_saves.isEmpty) ...[
        Text(
          AppLocalizations.of(context).teamBuilderNoSave,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
      ],
      OutlinedButton.icon(
        onPressed: _files,
        icon: const Icon(Symbols.upload_file_rounded),
        label: Text(_t('chooseFiles', 'Choose files')),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _text,
        minLines: 4,
        maxLines: 8,
        decoration: InputDecoration(
          labelText: _t('paste', 'Paste a card list or Box text'),
          alignLabelWithHint: true,
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: AlignmentDirectional.centerEnd,
        child: OutlinedButton(
          onPressed: _pasted,
          child: Text(_t('parse', 'Read data')),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = _preview, confirmation = _confirmation;
    final canConfirm =
        preview != null &&
        confirmation != null &&
        _error == null &&
        canConfirmReview(preview, confirmation);
    final slivers = <Widget>[
      if (_error != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              _errorText(_error!),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        ),
      if (_phase == _Phase.select)
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(child: _selectBody(theme)),
        ),
      if (_phase == _Phase.parsing)
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Text(_t('parsing', 'Reading data locally')),
              ],
            ),
          ),
        ),
      if ((_phase == _Phase.choose || _phase == _Phase.review) &&
          _candidates.length > 1)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          sliver: SliverToBoxAdapter(
            child: DropdownMenu<String>(
              expandedInsets: EdgeInsets.zero,
              label: Text(_t('candidate', 'Choose Box data')),
              initialSelection: _candidate,
              onSelected: (id) {
                if (id != null) _select(id);
              },
              dropdownMenuEntries: [
                for (final (index, candidate) in _candidates.indexed)
                  DropdownMenuEntry(
                    value: candidate.id,
                    label: _t(
                      'candidateCounts',
                      'Data {index}: {members} members, {snapshots} snapshots, {characters} characters, {items} items',
                      {
                        'index': index + 1,
                        'members': candidate.members.length,
                        'snapshots': candidate.snaps.length,
                        'characters': candidate.characters.length,
                        'items': candidate.bandItems.length,
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      if (_phase == _Phase.review &&
          preview != null &&
          confirmation != null) ...[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _t('existingPolicy', 'Existing cards'),
                  style: theme.textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                Segmented<ExistingPolicy>(
                  grow: false,
                  value: confirmation.policy,
                  options: [
                    Choice(
                      ExistingPolicy.keep,
                      _t('existingKeep', 'Keep all existing values'),
                    ),
                    Choice(
                      ExistingPolicy.updates,
                      _t('existingUpdates', 'Only increases'),
                    ),
                    Choice(
                      ExistingPolicy.overwrite,
                      _t('existingOverwrite', 'Overwrite all existing values'),
                    ),
                  ],
                  onSelected: (value) => setState(() {
                    confirmation.setPolicy(preview, value);
                    _recheck();
                  }),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => setState(() {
                        confirmation.selectAvailable(preview, true);
                        _recheck();
                      }),
                      child: Text(
                        _t('selectAvailable', 'Select available entries'),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        confirmation.selectAvailable(preview, false);
                        _recheck();
                      }),
                      child: Text(_t('clear', 'Clear selection')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          sliver: SliverList.separated(
            itemCount: preview.cards.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) => _cardRow(preview.cards[index]),
          ),
        ),
        if (preview.maps.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            sliver: SliverToBoxAdapter(
              child: ExpansionTile(
                initiallyExpanded: _mapsOpen,
                onExpansionChanged: (value) => _mapsOpen = value,
                tilePadding: EdgeInsets.zero,
                title: Text(_t('maps', 'Character and item levels')),
                children: [for (final map in preview.maps) _mapRow(map)],
              ),
            ),
          ),
        if (preview.issues.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            sliver: SliverToBoxAdapter(
              child: ExpansionTile(
                initiallyExpanded: _issuesOpen,
                onExpansionChanged: (value) => _issuesOpen = value,
                tilePadding: EdgeInsets.zero,
                title: Text(_t('issues', 'Entries needing review')),
                trailing: Badge(label: Text('${preview.issues.length}')),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final issue in preview.issues)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(_issueText(issue)),
                    ),
                ],
              ),
            ),
          ),
      ],
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(_t('title', 'Import card data'))),
      body: CustomScrollView(slivers: slivers),
      bottomNavigationBar: _phase == _Phase.parsing || _phase == _Phase.review
          ? Material(
              color: theme.colorScheme.surfaceContainer,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    heightFactor: 1,
                    child: _phase == _Phase.parsing
                        ? OutlinedButton(
                            onPressed: () => setState(() {
                              ++_generation;
                              _phase = _Phase.select;
                            }),
                            child: Text(_t('cancel', 'Cancel')),
                          )
                        : FilledButton(
                            onPressed: canConfirm ? _confirm : null,
                            child: Text(_t('confirm', 'Confirm import')),
                          ),
                  ),
                ),
              ),
            )
          : null,
    );
  }
}
