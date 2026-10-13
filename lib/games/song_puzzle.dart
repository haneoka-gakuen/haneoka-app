import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/shapes.dart';
import '../ui/theme.dart';
import '../ui/tile.dart';
import 'puzzle_model.dart';

Future<SolveResult> _solveInBackground(
  int size,
  List<int> start,
  List<int> goal,
  int budget,
) => Isolate.run(() => solvePuzzle(size, start, goal, budget));

class _Song {
  const _Song(this.id, this.name, this.band, this.cover);
  final String id;
  final String name;
  final String band;
  final String cover;
}

class _Solution {
  _Solution(this.start, this.path, this.directions);
  final List<int> start;
  final List<int> path;
  final List<String> directions;
}

/// Slide a song's cover back together (`song-puzzle`): any size from 3×3
/// to 8×8, an optimal solver with hints and replay, and an edit mode to
/// set up a board.
class SongPuzzleScreen extends StatefulWidget {
  const SongPuzzleScreen({super.key});
  @override
  State<SongPuzzleScreen> createState() => _SongPuzzleScreenState();
}

class _SongPuzzleScreenState extends State<SongPuzzleScreen> {
  String _server = '';
  List<_Song> _songs = [];
  String _song = '';
  bool _loaded = false;
  String _message = '';
  int _size = 3;
  int _goalBlank = 8;
  late List<int> _tiles = goalBoard(3);
  String _mode = 'play';
  int _selected = -1;
  bool _numbers = true;
  bool _reference = true;
  double? _cellSize;
  int _scrambleSteps = 20;
  int _budgetSeconds = 15;
  int _moves = 0;
  final _history = <({List<int> tiles, int moves})>[];
  int _revision = 0;
  bool _busy = false;
  _Solution? _solution;
  int _replayIndex = 0;
  Timer? _replay;
  int _hint = -1;

  List<int> get _goal => goalBoard(_size, _goalBlank);

  String _text(String key, [Map<String, Object?> values = const {}]) =>
      AppScope.of(context).text('tools.songPuzzle.$key', key, values);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_server.isEmpty) {
      _server = AppScope.of(context).server;
      _loadSongs();
    }
  }

  @override
  void dispose() {
    _replay?.cancel();
    super.dispose();
  }

  Future<void> _loadSongs() async {
    final state = AppScope.of(context);
    setState(() {
      _loaded = false;
      _message = '';
      _songs = [];
    });
    try {
      final document = await state.apiFor(_server).catalog('songs');
      final rows = document is Map && document['items'] is Map
          ? document['items'] as Map
          : document as Map;
      final songs = [
        for (final MapEntry(:key, :value) in rows.entries)
          if (value is Map &&
              RegExp(r'^\d+$').hasMatch('$key') &&
              '${value['jacketUrl'] ?? value['jacketThumbUrl'] ?? ''}'
                  .startsWith('/assets/'))
            _Song(
              '$key',
              // `localizedText(song.title, locale)`, as the site names them.
              state.text.text(value['musicTitle']),
              state.text.text(value['bandName'] ?? value['artistName']),
              state
                  .apiFor(_server)
                  .asset('${value['jacketUrl'] ?? value['jacketThumbUrl']}')
                  .toString(),
            ),
      ];
      if (!mounted) return;
      if (songs.isEmpty) throw StateError('empty');
      setState(() {
        _songs = songs;
        _song = songs.first.id;
        _loaded = true;
        _resetBoard(true);
      });
    } catch (_) {
      if (mounted) setState(() => _message = 'loadError');
    }
  }

  void _invalidate() {
    _replay?.cancel();
    _replay = null;
    _revision++;
    _busy = false;
    _solution = null;
    _replayIndex = 0;
    _hint = -1;
    _selected = -1;
    _message = '';
  }

  void _resetBoard(bool scramble) {
    _invalidate();
    _tiles = _goal;
    if (scramble) _tiles = shuffleBoard(_size, _goal, _scrambleSteps);
    _moves = 0;
    _history.clear();
  }

  /// A change that would discard a board in progress asks first.
  Future<void> _change(VoidCallback action) async {
    if (!solved(_tiles, _goal) && _moves > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_text('resetConfirm')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(_text('keepBoard')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(_text('confirm')),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    setState(action);
  }

  void _activate(int index) {
    setState(() {
      if (_mode == 'edit') {
        if (_selected < 0) {
          _selected = index;
        } else if (_selected == index) {
          _selected = -1;
        } else {
          final next = [..._tiles];
          final t = next[index];
          next[index] = next[_selected];
          next[_selected] = t;
          _history.add((tiles: _tiles, moves: _moves));
          _invalidate();
          _tiles = next;
        }
        return;
      }
      final next = slide(_size, _tiles, _tiles[index]);
      if (next == null || !_loaded) return;
      _history.add((tiles: _tiles, moves: _moves));
      _invalidate();
      _tiles = next;
      _moves++;
    });
  }

  void _undo() => setState(() {
    if (_history.isEmpty) return;
    final previous = _history.removeLast();
    _invalidate();
    _tiles = previous.tiles;
    _moves = previous.moves;
  });

  Future<void> _solve() async {
    final start = [..._tiles];
    final goal = _goal;
    final size = _size;
    final budget = _budgetSeconds * 1000;
    setState(() {
      _invalidate();
      _busy = true;
    });
    final revision = _revision;
    final result = await _solveInBackground(size, start, goal, budget);
    if (!mounted || revision != _revision) return;
    setState(() {
      _busy = false;
      _message = result.status;
      if (result.status != 'optimal') return;
      var board = start;
      final directions = <String>[];
      for (final tile in result.path) {
        directions.add(tileDirection(board, tile, size));
        board = slide(size, board, tile)!;
      }
      _solution = _Solution(start, result.path, directions);
      _hint = result.path.isEmpty ? -1 : _tiles.indexOf(result.path.first);
    });
  }

  void _showHint() {
    final tile = _solution?.path.elementAtOrNull(_replayIndex);
    if (tile == null) {
      _solve();
      return;
    }
    setState(() => _hint = _tiles.indexOf(tile));
  }

  void _step({bool automated = false}) {
    final solution = _solution;
    final tile = solution?.path.elementAtOrNull(_replayIndex);
    if (solution == null || tile == null) {
      _replay?.cancel();
      _replay = null;
      return;
    }
    setState(() {
      final next = slide(_size, _tiles, tile);
      if (next == null) {
        _invalidate();
        _message = 'error';
        return;
      }
      _history.add((tiles: _tiles, moves: _moves));
      _tiles = next;
      if (!automated) _moves++;
      _replayIndex++;
      _hint = -1;
      if (_replayIndex >= solution.path.length) {
        _replay?.cancel();
        _replay = null;
      }
    });
  }

  void _toggleReplay() {
    if (_replay != null) {
      setState(() {
        _replay!.cancel();
        _replay = null;
      });
      return;
    }
    final solution = _solution;
    if (solution == null || solution.path.isEmpty) return;
    if (_replayIndex >= solution.path.length) _rewind();
    setState(() {
      _replay = Timer.periodic(
        const Duration(milliseconds: 550),
        (_) => _step(automated: true),
      );
    });
  }

  void _rewind() => setState(() {
    _replay?.cancel();
    _replay = null;
    final solution = _solution;
    if (solution == null) return;
    _revision++;
    _tiles = [...solution.start];
    _history.clear();
    _moves = 0;
    _replayIndex = 0;
    _hint = -1;
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final song = _songs.where((s) => s.id == _song).firstOrNull;
    final finished = solved(_tiles, _goal);
    final valid = solvable(_size, _tiles, _goal);
    final status = _busy
        ? _text('searching')
        : _message == 'optimal' && _solution != null
        ? _text('optimal', {'moves': _solution!.path.length})
        : _message.isNotEmpty
        ? _text(_message)
        : !valid
        ? _text('unsolvable')
        : finished
        ? _text('completed')
        : _text('ready');
    Widget heading(IconData icon, String label, [Widget? trailing]) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          ShapedIcon(
            shape: MaterialShapes.cookie9Sided,
            size: 40,
            child: Icon(icon, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: theme.textTheme.titleLarge)),
          ?trailing,
        ],
      ),
    );
    Widget surface(Widget child) => Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(Corner.extraLarge),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
    return ShellPage(
      title: _text('title'),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 840;
          final cell =
              _cellSize ??
              (constraints.maxWidth < 600
                  ? const [96.0, 64.0, 56.0, 48.0, 48.0, 48.0]
                  : const [128.0, 104.0, 88.0, 80.0, 72.0, 64.0])[_size - 3];
          final play = surface(
            Column(
              children: [
                if (!_loaded)
                  Padding(
                    padding: const EdgeInsets.all(48),
                    child: _message == 'loadError'
                        ? FilledButton.tonal(
                            onPressed: _loadSongs,
                            child: Text(_text('retry')),
                          )
                        : const CircularProgressIndicator(),
                  )
                else
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: _Board(
                      size: _size,
                      tiles: _tiles,
                      goal: _goal,
                      cover: song?.cover,
                      cell: cell,
                      numbers: _numbers,
                      selected: _selected,
                      hint: _hint,
                      blankLabel: _text('blank'),
                      onTap: _activate,
                    ),
                  ),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_text('moves'), style: theme.textTheme.bodyMedium),
                        const SizedBox(width: 8),
                        Text('$_moves', style: theme.textTheme.titleLarge),
                        if (_history.isNotEmpty)
                          IconButton(
                            tooltip: _text('undo'),
                            onPressed: _undo,
                            icon: const Icon(Symbols.undo_rounded),
                          ),
                      ],
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () => _change(() => _resetBoard(false)),
                      icon: const Icon(Symbols.restart_alt_rounded),
                      label: Text(_text('reset')),
                    ),
                    FilledButton.icon(
                      onPressed: () => _change(() => _resetBoard(true)),
                      icon: const Icon(Symbols.shuffle_rounded),
                      label: Text(_text('shuffle')),
                    ),
                  ],
                ),
              ],
            ),
          );
          final settings = [
            surface(
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  heading(Symbols.library_music_rounded, _text('song')),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    onTap: _songs.isEmpty ? null : _pickSong,
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(Corner.small),
                      child: SizedBox.square(
                        dimension: 56,
                        child: song == null
                            ? null
                            : AppImage(
                                candidates: [song.cover],
                                fit: BoxFit.cover,
                              ),
                      ),
                    ),
                    title: Text(song?.name ?? _text('song')),
                    subtitle: song == null ? null : Text(song.band),
                    trailing: const Icon(Symbols.chevron_right_rounded),
                  ),
                  const SizedBox(height: 8),
                  DropdownMenu<int>(
                    expandedInsets: EdgeInsets.zero,
                    label: Text(_text('size')),
                    initialSelection: _size,
                    onSelected: (value) {
                      if (value == null || value == _size) return;
                      _change(() {
                        _size = value;
                        _goalBlank = value * value - 1;
                        _cellSize = null;
                        _resetBoard(true);
                      });
                    },
                    dropdownMenuEntries: [
                      for (var s = 3; s <= 8; s++)
                        DropdownMenuEntry(value: s, label: '$s × $s'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: 'play',
                        icon: const Icon(Symbols.sports_esports_rounded),
                        label: Text(_text('play')),
                      ),
                      ButtonSegment(
                        value: 'edit',
                        icon: const Icon(Symbols.edit_rounded),
                        label: Text(_text('edit')),
                      ),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (v) => setState(() {
                      _mode = v.single;
                      _selected = -1;
                    }),
                  ),
                  if (_reference && song != null) ...[
                    const SizedBox(height: 16),
                    Center(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(Corner.large),
                        child: SizedBox.square(
                          dimension: 200,
                          child: AppImage(
                            candidates: [song.cover],
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            surface(
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  heading(
                    Symbols.lightbulb_rounded,
                    _text('solution'),
                    Chip(label: Text(status)),
                  ),
                  if (_busy) const LinearProgressIndicator(),
                  if (!_busy && (_solution?.path.isNotEmpty ?? false)) ...[
                    LinearProgressIndicator(
                      value: _replayIndex / _solution!.path.length,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$_replayIndex / ${_solution!.path.length}',
                      style: theme.textTheme.labelMedium,
                    ),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (_busy)
                        FilledButton.tonal(
                          onPressed: () => setState(() {
                            _invalidate();
                            _message = 'cancelled';
                          }),
                          child: Text(_text('cancel')),
                        )
                      else if (!finished && _solution == null) ...[
                        FilledButton(
                          onPressed: valid && _loaded ? _solve : null,
                          child: Text(_text('solve')),
                        ),
                        FilledButton.tonal(
                          onPressed: valid && _loaded ? _showHint : null,
                          child: Text(_text('hint')),
                        ),
                      ],
                      if (_solution != null) ...[
                        FilledButton.tonal(
                          onPressed: _replayIndex >= _solution!.path.length
                              ? null
                              : () => _step(),
                          child: Text(_text('step')),
                        ),
                        FilledButton.tonal(
                          onPressed: _solution!.path.isEmpty
                              ? null
                              : _toggleReplay,
                          child: Text(
                            _text(_replay != null ? 'pause' : 'replay'),
                          ),
                        ),
                        FilledButton.tonal(
                          onPressed: _solution!.path.isEmpty ? null : _rewind,
                          child: Text(_text('stopReplay')),
                        ),
                      ],
                    ],
                  ),
                  if (_solution != null && _solution!.path.isNotEmpty)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: Text(
                        '${_text('steps')} · ${_solution!.path.length}',
                      ),
                      children: [
                        for (final (index, tile) in _solution!.path.indexed)
                          ListTile(
                            dense: true,
                            selected: index == _replayIndex,
                            title: Text(
                              '${index + 1}. ${_text('tile', {'tile': tile})} ${_text(_solution!.directions[index])}',
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Material(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(Corner.extraLarge),
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                leading: const Icon(Symbols.tune_rounded),
                title: Text(_text('advanced')),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_text('numbers')),
                    value: _numbers,
                    onChanged: (v) => setState(() => _numbers = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_text('reference')),
                    value: _reference,
                    onChanged: (v) => setState(() => _reference = v),
                  ),
                  const SizedBox(height: 8),
                  DropdownMenu<String>(
                    expandedInsets: EdgeInsets.zero,
                    label: Text(_text('server')),
                    initialSelection: _server,
                    onSelected: (value) {
                      if (value == null || value == _server) return;
                      _change(() {
                        _server = value;
                        _loadSongs();
                      });
                    },
                    dropdownMenuEntries: [
                      DropdownMenuEntry(value: 'jp', label: _text('jp')),
                      DropdownMenuEntry(value: 'intl', label: _text('intl')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DropdownMenu<int>(
                    expandedInsets: EdgeInsets.zero,
                    label: Text(_text('goalBlank')),
                    initialSelection: _goalBlank,
                    onSelected: (value) {
                      if (value == null) return;
                      _change(() {
                        _goalBlank = value;
                        _resetBoard(false);
                      });
                    },
                    dropdownMenuEntries: [
                      for (var i = 0; i < _size * _size; i++)
                        DropdownMenuEntry(
                          value: i,
                          label: _text('position', {
                            'row': i ~/ _size + 1,
                            'column': i % _size + 1,
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _NumberField(
                    label: _text('shuffleSteps'),
                    value: _scrambleSteps,
                    min: 1,
                    max: 1000,
                    onChanged: (v) => _scrambleSteps = v,
                  ),
                  const SizedBox(height: 12),
                  _NumberField(
                    label: _text('searchBudget'),
                    value: _budgetSeconds,
                    min: 1,
                    max: 120,
                    onChanged: (v) => _budgetSeconds = v,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(_text('zoom')),
                      const Spacer(),
                      Text('${cell.round()} px'),
                    ],
                  ),
                  Slider(
                    min: 48,
                    max: 128,
                    divisions: 10,
                    value: cell.clamp(48, 128),
                    label: '${cell.round()} px',
                    onChanged: (v) => setState(() => _cellSize = v),
                  ),
                ],
              ),
            ),
          ];
          return ListView(
            padding: pagePadding(context),
            children: [
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: play),
                    const SizedBox(width: 24),
                    SizedBox(width: 380, child: Column(children: settings)),
                  ],
                )
              else ...[
                play,
                const SizedBox(height: 16),
                ...settings,
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _pickSong() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _SongPicker(
        songs: _songs,
        selected: _song,
        searchLabel: _text('search'),
        emptyLabel: _text('noResults'),
      ),
    );
    if (picked == null || picked == _song) return;
    await _change(() {
      _song = picked;
      _resetBoard(true);
    });
  }
}

class _NumberField extends StatefulWidget {
  const _NumberField({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });
  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final _controller = TextEditingController(text: '${widget.value}');
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    keyboardType: TextInputType.number,
    decoration: InputDecoration(
      labelText: widget.label,
      border: const OutlineInputBorder(),
    ),
    onSubmitted: (_) => _commit(),
    onTapOutside: (_) => _commit(),
  );

  void _commit() {
    final value = (int.tryParse(_controller.text) ?? widget.value).clamp(
      widget.min,
      widget.max,
    );
    _controller.text = '$value';
    widget.onChanged(value);
  }
}

/// The cover cut into tiles; the blank shows as a dashed cell.
class _Board extends StatelessWidget {
  const _Board({
    required this.size,
    required this.tiles,
    required this.goal,
    required this.cover,
    required this.cell,
    required this.numbers,
    required this.selected,
    required this.hint,
    required this.blankLabel,
    required this.onTap,
  });
  final int size;
  final List<int> tiles;
  final List<int> goal;
  final String? cover;
  final double cell;
  final bool numbers;
  final int selected;
  final int hint;
  final String blankLabel;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const gap = 2.0;
    final full = cell * size + gap * (size - 1);
    return SizedBox.square(
      dimension: full,
      child: Stack(
        children: [
          for (var index = 0; index < tiles.length; index++)
            AnimatedPositioned(
              key: ValueKey(tiles[index]),
              duration: Durations.short4,
              curve: Easing.standard,
              left: (index % size) * (cell + gap),
              top: (index ~/ size) * (cell + gap),
              width: cell,
              height: cell,
              child: GestureDetector(
                onTap: () => onTap(index),
                child: tiles[index] == 0
                    ? Container(
                        decoration: BoxDecoration(
                          color: Colors.black,
                          border: Border.all(
                            color: selected == index
                                ? scheme.primary
                                : scheme.outline,
                            width: selected == index ? 3 : 2,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          blankLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      )
                    : _Piece(
                        tile: tiles[index],
                        home: goal.indexOf(tiles[index]),
                        size: size,
                        cell: cell,
                        gap: gap,
                        cover: cover,
                        number: numbers,
                        outline: selected == index
                            ? scheme.primary
                            : hint == index
                            ? scheme.tertiary
                            : null,
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Piece extends StatelessWidget {
  const _Piece({
    required this.tile,
    required this.home,
    required this.size,
    required this.cell,
    required this.gap,
    required this.cover,
    required this.number,
    this.outline,
  });
  final int tile;
  final int home;
  final int size;
  final double cell;
  final double gap;
  final String? cover;
  final bool number;
  final Color? outline;

  @override
  Widget build(BuildContext context) {
    final full = cell * size;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRect(
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: full,
              maxWidth: full,
              minHeight: full,
              maxHeight: full,
              child: Transform.translate(
                offset: Offset(-(home % size) * cell, -(home ~/ size) * cell),
                child: SizedBox.square(
                  dimension: full,
                  child: cover == null
                      ? null
                      : AppImage(candidates: [cover!], fit: BoxFit.cover),
                ),
              ),
            ),
          ),
          if (number)
            Positioned(
              left: 4,
              top: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '$tile',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          if (outline != null)
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: outline!, width: 3),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
        ],
      ),
    );
  }
}

class _SongPicker extends StatefulWidget {
  const _SongPicker({
    required this.songs,
    required this.selected,
    required this.searchLabel,
    required this.emptyLabel,
  });
  final List<_Song> songs;
  final String selected;
  final String searchLabel;
  final String emptyLabel;
  @override
  State<_SongPicker> createState() => _SongPickerState();
}

class _SongPickerState extends State<_SongPicker> {
  String _query = '';
  String _band = '';
  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    final query = _query.trim().toLowerCase();
    final bands = {
      for (final s in widget.songs)
        if (s.band.isNotEmpty) s.band,
    }.toList();
    final songs = widget.songs
        .where(
          (s) =>
              (_band.isEmpty || s.band == _band) &&
              (query.isEmpty ||
                  '${s.id} ${s.name} ${s.band}'.toLowerCase().contains(query)),
        )
        .toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.85,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Symbols.search_rounded),
                hintText: widget.searchLabel,
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          SizedBox(
            height: 56,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(t('common.states.all', 'All')),
                    selected: _band.isEmpty,
                    onSelected: (_) => setState(() => _band = ''),
                  ),
                ),
                for (final band in bands)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(band),
                      selected: _band == band,
                      onSelected: (_) =>
                          setState(() => _band = _band == band ? '' : band),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: songs.isEmpty
                ? Center(child: Text(widget.emptyLabel))
                : GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 180,
                          childAspectRatio: 0.72,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                        ),
                    itemCount: songs.length,
                    itemBuilder: (context, index) {
                      final song = songs[index];
                      return Tile(
                        title: song.name,
                        subtitle: song.band,
                        images: [song.cover],
                        aspectRatio: 1,
                        selected: song.id == widget.selected,
                        onTap: () => Navigator.pop(context, song.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
