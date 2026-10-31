/// The paged leaderboard the Arena and event pages share
/// (`src/lit/arena-ranking.ts`): rank jumps, ID search and windows of 100.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../team_builder/engine/num.dart';
import 'records.dart';

const rankingWindow = 100;

/// Jump, search and paging controls above a window of ranks.
class RankingBoardControls extends StatelessWidget {
  const RankingBoardControls({
    super.key,
    required this.rankField,
    required this.playerField,
    required this.start,
    required this.maximum,
    required this.onJump,
    required this.onFind,
    required this.onPage,
  });
  final TextEditingController rankField, playerField;
  final int start;
  final int? maximum;
  final void Function(int rank) onJump;
  final VoidCallback onFind;

  /// Moves one window forward (1) or back (-1).
  final void Function(int direction) onPage;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    String text(String key, [Map<String, Object?> values = const {}]) =>
        state.text('catalog.arena.ranking.$key', key, values);
    String number(num value) =>
        NumberFormat.decimalPattern(state.text.locale).format(value);
    void jump() {
      final rank = int.tryParse(rankField.text);
      if (rank != null && rank > 0) onJump(rank);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Row(
          spacing: 8,
          children: [
            Expanded(
              child: TextField(
                controller: rankField,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: text('jump')),
                onSubmitted: (_) => jump(),
              ),
            ),
            FilledButton.tonal(onPressed: jump, child: Text(text('go'))),
          ],
        ),
        Row(
          spacing: 8,
          children: [
            Expanded(
              child: TextField(
                controller: playerField,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: text('playerId')),
                onSubmitted: (_) => onFind(),
              ),
            ),
            FilledButton.tonal(onPressed: onFind, child: Text(text('find'))),
          ],
        ),
        Row(
          children: [
            IconButton(
              tooltip: text('previous'),
              onPressed: start > 1 ? () => onPage(-1) : null,
              icon: const Icon(Symbols.chevron_left_rounded),
            ),
            Expanded(
              child: Text(
                text('window', {
                  'start': number(start),
                  'end': number(start + rankingWindow - 1),
                  'total': maximum == null ? '—' : number(maximum!),
                }),
                textAlign: TextAlign.center,
              ),
            ),
            IconButton(
              tooltip: text('next'),
              onPressed: maximum == null || start + rankingWindow <= maximum!
                  ? () => onPage(1)
                  : null,
              icon: const Icon(Symbols.chevron_right_rounded),
            ),
          ],
        ),
      ],
    );
  }
}

/// An event's point ranking.
class EventPointBoard extends StatefulWidget {
  const EventPointBoard({
    super.key,
    required this.region,
    required this.eventId,
    this.onPlayer,
  });
  final String region;
  final Object? eventId;
  final void Function(String profileId)? onPlayer;

  @override
  State<EventPointBoard> createState() => EventPointBoardState();
}

class EventPointBoardState extends State<EventPointBoard> {
  final _list = GlobalKey<RankingListState>();
  final _rankField = TextEditingController();
  final _playerField = TextEditingController();
  int _start = 1;
  int? _target, _maximum;

  String get _board =>
      '/api/v1/game/records/${widget.region}/events/${widget.eventId}/points';

  void refresh() => _list.currentState?.refresh();

  @override
  void dispose() {
    _rankField.dispose();
    _playerField.dispose();
    super.dispose();
  }

  void _jump(int rank) {
    final target = rank.clamp(1, _maximum ?? rank);
    setState(() {
      _target = target;
      _start = ((target - 1) ~/ rankingWindow) * rankingWindow + 1;
    });
  }

  Future<void> _find() async {
    final id = _playerField.text.trim();
    if (!RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(id)) return;
    final messenger = ScaffoldMessenger.of(context);
    final state = AppScope.of(context);
    try {
      final result = objectRow(
        await state.apiFor(state.server).live('$_board/search?profileId=$id'),
      );
      if (!mounted) return;
      if (result['row'] is Map) {
        _jump(intOf(objectRow(result['row'])['rank']));
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              state.text('catalog.arena.ranking.notFound', 'notFound', {
                'count': NumberFormat.decimalPattern(state.text.locale)
                    .format(intOf(result['searchedTo'])),
              }),
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(state.text('common.states.unavailable'))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 12,
    children: [
      RankingBoardControls(
        rankField: _rankField,
        playerField: _playerField,
        start: _start,
        maximum: _maximum,
        onJump: _jump,
        onFind: _find,
        onPage: (direction) => setState(() {
          _start += direction * rankingWindow;
          _target = null;
        }),
      ),
      RankingList(
        key: _list,
        endpoint: '$_board/ranking?start=$_start',
        region: widget.region,
        points: true,
        limit: rankingWindow,
        highlightRank: _target,
        onData: (ranking, _) {
          final maximum = (ranking['maxRank'] as num?)?.toInt();
          if (maximum == _maximum) return;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _maximum = maximum);
          });
        },
        onPlayer: widget.onPlayer,
      ),
    ],
  );
}
