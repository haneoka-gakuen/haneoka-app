import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../community/community_time.dart';
import '../core/app_state.dart';
import '../shell/links.dart';
import '../chart_editor/project.dart';
import 'controller.dart';

/// Comment moderation (`admin-comments`): filters, search, bulk decisions and
/// a per-comment history link.
class AdminCommentsPanel extends StatefulWidget {
  const AdminCommentsPanel({
    super.key,
    required this.controller,
    required this.query,
  });
  final AdminController controller;
  final String query;
  @override
  State<AdminCommentsPanel> createState() => _AdminCommentsPanelState();
}

class _AdminCommentsPanelState extends State<AdminCommentsPanel> {
  String _filter = 'attention', _target = 'all';
  List<Map<String, Object?>> _comments = const [];
  String? _cursor;
  bool _loading = true, _failed = false, _working = false;
  final _selected = <String>{};

  String _t(
    String key,
    String fallback, [
    Map<String, Object?> values = const {},
  ]) => AppScope.of(context).text('admin.comments.$key', fallback, values);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(AdminCommentsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) _load();
  }

  String _endpoint(String? cursor) => Uri(
    path: '/api/v1/admin/comments',
    queryParameters: {
      'limit': '50',
      if (_filter == 'attention' || _filter == 'block')
        'moderationStatus': _filter,
      if (_filter == 'reported' || _filter == 'hidden') 'state': _filter,
      if (_target != 'all') 'target': _target,
      if (widget.query.isNotEmpty) 'q': widget.query,
      'cursor': ?cursor,
    },
  ).toString();

  Future<void> _load({bool append = false}) async {
    if (append && _cursor == null) return;
    if (!append) {
      setState(() {
        _loading = true;
        _failed = false;
      });
    }
    try {
      final data = await widget.controller.request(
        _endpoint(append ? _cursor : null),
      );
      if (!mounted) return;
      final rows = chartRows(data['comments'] ?? const []);
      setState(() {
        _comments = append ? [..._comments, ...rows] : rows;
        _cursor = data['nextCursor'] as String?;
        _loading = false;
      });
    } catch (_) {
      if (mounted && !append) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  Future<void> _decide(List<String> ids, String action) async {
    if (_working || ids.isEmpty) return;
    setState(() => _working = true);
    var failed = 0;
    for (final id in ids) {
      final index = _comments.indexWhere((row) => '${row['id']}' == id);
      if (index < 0) continue;
      final comment = _comments[index];
      try {
        final moderation = action == 'allow' || action == 'block';
        await widget.controller.request(
          '/api/v1/admin/comments/$id/${moderation ? 'moderation' : 'state'}',
          method: 'PUT',
          headers: {
            'Idempotency-Key':
                'admin-$id-$action-${DateTime.now().microsecondsSinceEpoch}',
          },
          body: moderation
              ? {'verdict': action, 'reasonCode': 'staff.comment.$action'}
              : {
                  'action': action,
                  'expectedVersion': comment['version'],
                  'reasonCode': 'staff.comment.$action',
                },
        );
        _comments = [
          for (final row in _comments)
            if ('${row['id']}' != id)
              row
            else if (moderation)
              {...row, 'moderationStatus': action}
            else
              {
                ...row,
                'hidden': action == 'hide',
                'version': (row['version'] as num? ?? 0) + 1,
              },
        ];
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    final done = ids.length - failed;
    setState(() {
      _working = false;
      _selected.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failed > 0
              ? _t('partial', '{done} updated · {failed} failed', {
                  'done': done,
                  'failed': failed,
                })
              : _t('updated', '{count} updated', {'count': done}),
        ),
      ),
    );
  }

  Widget _row(Map<String, Object?> comment) {
    final theme = Theme.of(context);
    final id = '${comment['id']}';
    final status = '${comment['moderationStatus'] ?? ''}';
    final hidden = comment['hidden'] == true;
    final author = (comment['author'] as Map?) ?? const {};
    final target = (comment['target'] as Map?) ?? const {};
    final reports = (comment['reports'] as num?)?.toInt() ?? 0;
    final locale = AppScope.of(context).text.locale;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            Row(
              children: [
                Checkbox(
                  value: _selected.contains(id),
                  onChanged: (value) => setState(
                    () => value == true
                        ? _selected.add(id)
                        : _selected.remove(id),
                  ),
                ),
                Expanded(
                  child: Text(
                    '${author['name'] ?? author['handle'] ?? author['uid'] ?? ''}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text(
                  formatCommunityTime(comment['createdAt'], locale)?.text ?? '',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            Text('${comment['body'] ?? ''}'),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (status == 'review' || status == 'attention')
                  Chip(label: Text(_t('statusReview', 'Needs review'))),
                if (status == 'pending')
                  Chip(label: Text(_t('statusPending', 'Pending'))),
                if (status == 'block')
                  Chip(label: Text(_t('statusBlocked', 'Blocked'))),
                if (hidden) Chip(label: Text(_t('statusHidden', 'Hidden'))),
                if (reports > 0)
                  Chip(
                    label: Text(
                      _t('reports', '{count} reports', {'count': reports}),
                    ),
                  ),
              ],
            ),
            Row(
              children: [
                if (status != 'allow')
                  IconButton(
                    tooltip: _t('approve', 'Approve'),
                    onPressed: () => _decide([id], 'allow'),
                    icon: const Icon(Symbols.check_circle_rounded),
                  ),
                if (status != 'block')
                  IconButton(
                    tooltip: _t('block', 'Block'),
                    onPressed: () => _decide([id], 'block'),
                    icon: const Icon(Symbols.block_rounded),
                  ),
                IconButton(
                  tooltip: hidden ? _t('unhide', 'Show') : _t('hide', 'Hide'),
                  onPressed: () => _decide([id], hidden ? 'unhide' : 'hide'),
                  icon: Icon(
                    hidden
                        ? Symbols.visibility_rounded
                        : Symbols.visibility_off_rounded,
                  ),
                ),
                if (target['postId'] != null)
                  IconButton(
                    tooltip: _t('history', 'History'),
                    onPressed: () => openLink(
                      context,
                      '/$locale/community/posts/${target['postId']}/',
                    ),
                    icon: const Icon(Symbols.open_in_new_rounded),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filters = [
      ('attention', _t('filterAttention', 'To review')),
      ('reported', _t('filterReported', 'Reported')),
      ('block', _t('filterBlocked', 'Blocked')),
      ('hidden', _t('filterHidden', 'Hidden')),
      ('all', _t('filterAll', 'All')),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final (key, label) in filters)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(label),
                    selected: _filter == key,
                    onSelected: (_) {
                      _filter = key;
                      _selected.clear();
                      _load();
                    },
                  ),
                ),
            ],
          ),
        ),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: 'all', label: Text(_t('targetAll', 'All'))),
            ButtonSegment(
              value: 'forum',
              label: Text(_t('targetForum', 'Forums')),
            ),
            ButtonSegment(
              value: 'entity',
              label: Text(_t('targetEntity', 'Entity pages')),
            ),
          ],
          selected: {_target},
          onSelectionChanged: (value) {
            _target = value.first;
            _selected.clear();
            _load();
          },
        ),
        if (_selected.isNotEmpty)
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                _t('selected', '{count} selected', {'count': _selected.length}),
              ),
              for (final (action, label) in [
                ('allow', _t('approve', 'Approve')),
                ('block', _t('block', 'Block')),
                ('hide', _t('hide', 'Hide')),
              ])
                FilledButton.tonal(
                  onPressed: _working
                      ? null
                      : () => _decide(_selected.toList(), action),
                  child: Text(label),
                ),
            ],
          ),
        if (_comments.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(
                () => _selected.addAll(_comments.map((row) => '${row['id']}')),
              ),
              child: Text(
                _t('selectAll', 'Select all {count}', {
                  'count': _comments.length,
                }),
              ),
            ),
          ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_failed)
          Center(
            child: TextButton(
              onPressed: _load,
              child: Text(
                AppScope.of(context).text('common.actions.retry', 'Retry'),
              ),
            ),
          )
        else if (_comments.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(child: Text(_t('empty', 'Nothing here'))),
          )
        else ...[
          for (final comment in _comments) _row(comment),
          if (_cursor != null)
            TextButton(
              onPressed: () => _load(append: true),
              child: Text(
                AppScope.of(context)
                    .text('common.actions.loadMore', 'Load more'),
              ),
            ),
        ],
      ],
    );
  }
}
