import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../ui/account_dialog.dart';
import '../account/haneoka_account.dart';
import 'community_widgets.dart';
import 'editor.dart';
import 'reactions.dart';

void communityMessage(BuildContext context, String key) => ScaffoldMessenger.of(
  context,
).showSnackBar(SnackBar(content: Text(communityLabel(context, key, key))));

Future<bool> confirmCommunity(
  BuildContext context,
  String title,
  String body,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AccountDialog(
        child: AlertDialog(
          title: Text(communityLabel(context, title, title)),
          content: Text(communityLabel(context, body, body)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(AppScope.of(context).text('common.actions.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(communityLabel(context, title, title)),
            ),
          ],
        ),
      ),
    ) ??
    false;

Future<bool> communityStatement(
  BuildContext context, {
  required bool appeal,
  required String kind,
  required String id,
  Object? revision,
}) async {
  if (!await requireSession(context) || !context.mounted) return false;
  final controller = TextEditingController();
  var reason = 'other', busy = false, attempted = false;
  try {
    return await showDialog<bool>(
          context: context,
          builder: (dialog) => StatefulBuilder(
            builder: (context, refresh) => AccountDialog(
              child: AlertDialog(
                title: Text(
                  communityLabel(
                    context,
                    appeal ? 'appeal' : 'report',
                    appeal ? 'Appeal' : 'Report',
                  ),
                ),
                content: SizedBox(
                  width: 420,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!appeal)
                        DropdownButtonFormField<String>(
                          initialValue: reason,
                          decoration: InputDecoration(
                            labelText: communityLabel(
                              context,
                              'reportDialog.reason',
                              'Reason',
                            ),
                          ),
                          items: [
                            for (final key in [
                              'spam',
                              'harassment',
                              'hate',
                              'sexual',
                              'violence',
                              'privacy',
                              'misinformation',
                              'copyright',
                              'other',
                            ])
                              DropdownMenuItem(
                                value: key,
                                child: Text(
                                  communityLabel(
                                    context,
                                    'reportDialog.reasons.$key',
                                    key,
                                  ),
                                ),
                              ),
                          ],
                          onChanged: busy ? null : (value) => reason = value!,
                        ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: controller,
                        minLines: 3,
                        maxLines: 6,
                        maxLength: 2000,
                        decoration: InputDecoration(
                          labelText: communityLabel(
                            context,
                            appeal ? 'appealStatement' : 'reportDialog.details',
                            'Details',
                          ),
                          errorText:
                              attempted &&
                                  (appeal || reason == 'other') &&
                                  controller.text.trim().isEmpty
                              ? AppScope.of(context)
                                    .text('common.fields.required')
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: Text(
                      AppScope.of(context).text('common.actions.cancel'),
                    ),
                  ),
                  FilledButton(
                    onPressed: busy
                        ? null
                        : () async {
                            refresh(() => attempted = true);
                            if ((appeal || reason == 'other') &&
                                controller.text.trim().isEmpty) {
                              return;
                            }
                            refresh(() => busy = true);
                            try {
                              await communityRequest(
                                'POST',
                                appeal
                                    ? '/api/v1/community/appeals'
                                    : '/api/v1/community/reports',
                                body: appeal
                                    ? {
                                        'entityKind': kind,
                                        'entityId': id,
                                        'statement': controller.text.trim(),
                                        'entityRevision': ?revision,
                                      }
                                    : {
                                        'targetKind': kind,
                                        'targetId': id,
                                        'reasonCode': reason,
                                        if (controller.text.trim().isNotEmpty)
                                          'details': controller.text.trim(),
                                      },
                              );
                              if (context.mounted) {
                                Navigator.of(context).pop(true);
                              }
                            } catch (_) {
                              if (context.mounted) {
                                communityMessage(
                                  context,
                                  appeal
                                      ? 'appealFailed'
                                      : 'reportDialog.failed',
                                );
                                refresh(() => busy = false);
                              }
                            }
                          },
                    child: Text(
                      communityLabel(
                        context,
                        appeal ? 'submitAppeal' : 'reportDialog.submit',
                        'Submit',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ) ??
        false;
  } finally {
    controller.dispose();
  }
}

class CommunityRecordMenu extends StatefulWidget {
  const CommunityRecordMenu({
    super.key,
    required this.kind,
    required this.record,
    required this.onChanged,
    this.viewer,
    this.onRemoved,
    this.onFeedback,
    this.detail = false,
  });
  final String kind;
  final Json record;
  final Json? viewer;
  final ValueChanged<Json> onChanged;
  final VoidCallback? onRemoved, onFeedback;
  final bool detail;
  @override
  State<CommunityRecordMenu> createState() => _CommunityRecordMenuState();
}

class _CommunityRecordMenuState extends State<CommunityRecordMenu> {
  bool _busy = false;
  Json get viewer => widget.viewer ?? jsonMap(widget.record['viewer']);
  String get path =>
      '/api/v1/community/${widget.kind == 'post' ? 'posts' : 'comments'}/${Uri.encodeComponent('${widget.record['id']}')}';
  Future<void> _editComment() async {
    final text = TextEditingController(text: '${widget.record['body'] ?? ''}');
    var attempted = false, busy = false;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialog) => StatefulBuilder(
          builder: (context, refresh) => AccountDialog(
            child: AlertDialog(
              title: Text(communityLabel(context, 'edit', 'Edit comment')),
              content: SizedBox(
                width: 560,
                child: TextField(
                  controller: text,
                  minLines: 4,
                  maxLines: 12,
                  maxLength: 5000,
                  decoration: InputDecoration(
                    errorText: attempted && text.text.trim().isEmpty
                        ? AppScope.of(context).text('common.fields.required')
                        : null,
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: busy ? null : () => Navigator.of(context).pop(),
                  child: Text(
                    AppScope.of(context).text('common.actions.cancel'),
                  ),
                ),
                FilledButton(
                  onPressed: busy
                      ? null
                      : () async {
                          refresh(() => attempted = true);
                          if (text.text.trim().isEmpty) return;
                          refresh(() => busy = true);
                          try {
                            final result = await communityRequest(
                              'PATCH',
                              path,
                              body: {
                                'version': widget.record['version'],
                                'body': text.text.trim(),
                              },
                            );
                            if (context.mounted) {
                              invalidateCommunityData();
                              widget.onChanged({
                                ...widget.record,
                                '_refreshThread': true,
                                ...jsonMap(result['comment']),
                              });
                              Navigator.of(context).pop();
                            }
                          } catch (_) {
                            if (context.mounted) {
                              communityMessage(context, 'unavailable');
                              refresh(() => busy = false);
                            }
                          }
                        },
                  child: Text(communityLabel(context, 'save', 'Save')),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      text.dispose();
    }
  }

  Future<void> _move() async {
    final owner = HaneokaAccount.instance.user?['id'];
    final directory = await communityRequest('GET', '/api/v1/community/forums');
    final forums = jsonList(directory['forums'])
        .where((f) => jsonMap(f['capabilities'])['canManage'] == true)
        .toList();
    if (!mounted || HaneokaAccount.instance.user?['id'] != owner) return;
    String? target;
    final reason = TextEditingController();
    var attempted = false, busy = false;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialog) => StatefulBuilder(
          builder: (context, refresh) => AccountDialog(
            child: AlertDialog(
              title: Text(communityLabel(context, 'movePost', 'Move post')),
              content: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: target,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: communityLabel(context, 'forum', 'Forum'),
                        errorText: attempted && target == null
                            ? AppScope.of(context)
                                  .text('common.fields.required')
                            : null,
                      ),
                      items: [
                        for (final forum in forums)
                          DropdownMenuItem(
                            value: '${forum['id']}',
                            child: Text('${forum['name'] ?? forum['title']}'),
                          ),
                      ],
                      onChanged: busy ? null : (v) => target = v,
                    ),
                    TextField(
                      controller: reason,
                      decoration: InputDecoration(
                        labelText: communityLabel(
                          context,
                          'moveReason',
                          'Reason',
                        ),
                        errorText: attempted && reason.text.trim().isEmpty
                            ? AppScope.of(context)
                                  .text('common.fields.required')
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: busy ? null : () => Navigator.of(context).pop(),
                  child: Text(
                    AppScope.of(context).text('common.actions.cancel'),
                  ),
                ),
                FilledButton(
                  onPressed: busy
                      ? null
                      : () async {
                          refresh(() => attempted = true);
                          if (target == null || reason.text.trim().isEmpty) {
                            return;
                          }
                          refresh(() => busy = true);
                          try {
                            await communityRequest(
                              'POST',
                              '/api/v1/admin/forums/move-post',
                              body: {
                                'postId': widget.record['id'],
                                'expectedVersion': widget.record['version'],
                                'forumId': target,
                                'reasonCode': reason.text.trim(),
                              },
                            );
                            final result = await communityRequest('GET', path);
                            if (context.mounted) {
                              invalidateCommunityData();
                              widget.onChanged({
                                ...jsonMap(result['post']),
                                'viewer': result['viewer'],
                              });
                              Navigator.of(context).pop();
                            }
                          } catch (_) {
                            if (context.mounted) {
                              communityMessage(context, 'unavailable');
                              refresh(() => busy = false);
                            }
                          }
                        },
                  child: Text(communityLabel(context, 'movePost', 'Move post')),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      reason.dispose();
    }
  }

  Future<void> _action(String action) async {
    if (!await requireSession(context) || !mounted) return;
    final record = widget.record;
    final owner = HaneokaAccount.instance.user?['id'];
    final originalPath = path;
    if (action == 'report' || action == 'appeal') {
      await communityStatement(
        context,
        appeal: action == 'appeal',
        kind: widget.kind,
        id: '${record['id']}',
      );
      return;
    }
    if (action == 'edit') {
      setState(() => _busy = true);
      try {
        if (widget.kind == 'post') {
          final loaded = await communityRequest('GET', path);
          if (!mounted || HaneokaAccount.instance.user?['id'] != owner) return;
          if (jsonMap(loaded['viewer'])['canEdit'] != true) {
            communityMessage(context, 'editForbidden');
            return;
          }
          final value = await Navigator.of(context).push<Json>(
            MaterialPageRoute(
              builder: (_) => PostEditorScreen(post: jsonMap(loaded['post'])),
            ),
          );
          if (value != null &&
              mounted &&
              HaneokaAccount.instance.user?['id'] == owner) {
            widget.onChanged({...record, ...value, 'viewer': viewer});
          }
        } else {
          await _editComment();
        }
      } catch (_) {
        if (mounted) communityMessage(context, 'editLoadFailed');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    if (action == 'delete' &&
        !await confirmCommunity(
          context,
          widget.kind == 'post' ? 'deletePost' : 'delete',
          widget.kind == 'post' ? 'deletePostConfirm' : 'deleteCommentConfirm',
        )) {
      return;
    }
    if (!mounted || HaneokaAccount.instance.user?['id'] != owner) return;
    setState(() => _busy = true);
    try {
      if (action == 'move') {
        await _move();
        return;
      }
      final result = await communityRequest(
        action == 'delete'
            ? 'DELETE'
            : action == 'archive'
            ? 'POST'
            : 'PUT',
        action == 'delete'
            ? path
            : '$path/${action == 'archive' ? (record['state'] == 'archived' ? 'restore' : 'archive') : action}',
        body: action == 'feedback'
            ? {'feedback': 'not_interested'}
            : {
                'version': record['version'],
                if (action == 'pin') 'active': record['pinnedAt'] == null,
                if (action == 'lock')
                  'active': record['commentsLockedAt'] == null,
              },
      );
      if (!mounted || HaneokaAccount.instance.user?['id'] != owner) return;
      invalidateCommunityData();
      if (action == 'feedback') {
        widget.onFeedback?.call();
        final messenger = ScaffoldMessenger.of(context);
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              communityLabel(
                context,
                'notInterestedDone',
                'Hidden from your recommendations',
              ),
            ),
            action: SnackBarAction(
              label: communityLabel(context, 'undo', 'Undo'),
              onPressed: () async {
                if (HaneokaAccount.instance.user?['id'] != owner) return;
                try {
                  await communityRequest(
                    'PUT',
                    '$originalPath/feedback',
                    body: {'feedback': null},
                  );
                  if (HaneokaAccount.instance.user?['id'] == owner) {
                    invalidateCommunityData();
                  }
                } catch (_) {
                  if (mounted) communityMessage(context, 'unavailable');
                }
              },
            ),
          ),
        );
      } else if (action == 'delete' && widget.kind == 'post') {
        widget.onRemoved?.call();
      } else {
        final next = jsonMap(result[widget.kind]);
        widget.onChanged({
          ...record,
          ...next,
          if (widget.kind == 'comment' &&
              (action == 'delete' || result['visibilityChanged'] == true))
            '_refreshThread': true,
          'viewer': result['viewer'] ?? widget.viewer ?? record['viewer'],
        });
      }
    } catch (_) {
      if (mounted) communityMessage(context, 'unavailable');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final own = viewer['canEdit'] == true;
    final uid = HaneokaAccount.instance.user?['uid'];
    final author =
        uid != null &&
        widget.record['authorUid'] != null &&
        '$uid' == '${widget.record['authorUid']}';
    final actions = <String, String>{
      if (own) 'edit': widget.kind == 'post' ? 'editPost' : 'edit',
      if (!own) 'report': 'report',
      if (widget.kind == 'post' && widget.detail) ...{
        if (viewer['canLock'] == true)
          'lock': widget.record['commentsLockedAt'] == null
              ? 'lockTopic'
              : 'unlockTopic',
        if (viewer['canMove'] == true) 'move': 'movePost',
        if (viewer['canPin'] == true)
          'pin': widget.record['pinnedAt'] == null ? 'pinPost' : 'unpinPost',
        if (own)
          'archive': widget.record['state'] == 'archived'
              ? 'restorePost'
              : 'archivePost',
      },
      if (widget.onFeedback != null &&
          !own &&
          viewer['canGiveFeedback'] == true)
        'feedback': 'notInterested',
      if (viewer['canAppeal'] == true ||
          author && widget.record['moderationStatus'] == 'block')
        'appeal': 'appeal',
      if (viewer['canDelete'] == true || widget.kind == 'post' && own)
        'delete': widget.kind == 'post' ? 'deletePost' : 'delete',
    };
    return PopupMenuButton<String>(
      enabled: !_busy,
      tooltip: AppScope.of(context).text('common.actions.moreActions'),
      icon: const Icon(Symbols.more_horiz_rounded),
      onSelected: _action,
      itemBuilder: (_) => [
        for (final entry in actions.entries)
          PopupMenuItem(
            value: entry.key,
            child: Text(communityLabel(context, entry.value, entry.value)),
          ),
      ],
    );
  }
}
