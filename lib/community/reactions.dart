import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../account/account_widgets.dart';
import '../account/haneoka_account.dart';
import 'community_widgets.dart';

/// Signs in first when needed; true when the reader is signed in.
Future<bool> requireSession(BuildContext context) async {
  if (HaneokaAccount.instance.signedIn) return true;
  await signInToHaneoka(context);
  return HaneokaAccount.instance.signedIn;
}

/// Like or unlike a post or comment (`PUT …/reaction`), shown at once and
/// settled by the server's count.
class LikeButton extends StatefulWidget {
  const LikeButton({
    super.key,
    required this.kind,
    required this.record,
    required this.onChanged,
    this.compact = false,
    this.showLabel = false,
  });

  /// `post` or `comment`.
  final String kind;
  final Json record;
  final ValueChanged<Json> onChanged;
  final bool compact;
  final bool showLabel;

  @override
  State<LikeButton> createState() => _LikeButtonState();
}

class _LikeButtonState extends State<LikeButton> {
  bool _busy = false;

  Future<void> _toggle() async {
    if (_busy || !await requireSession(context)) return;
    if (!mounted) return;
    final owner = HaneokaAccount.instance.user?['id'];
    final record = widget.record;
    final viewer = jsonMap(record['viewer']);
    final liked = viewer['liked'] == true;
    final count = (record['likeCount'] as num?)?.toInt() ?? 0;
    Json apply(bool active, int likes) => {
      ...record,
      'likeCount': likes,
      'viewer': {...viewer, 'liked': active},
    };
    widget.onChanged(
      apply(!liked, (count + (liked ? -1 : 1)).clamp(0, 1 << 31)),
    );
    setState(() => _busy = true);
    try {
      final result = await communityRequest(
        'PUT',
        '/api/v1/community/${widget.kind == 'post' ? 'posts' : 'comments'}/${Uri.encodeComponent('${record['id']}')}/reaction',
        body: {'active': !liked},
      );
      if (!mounted || HaneokaAccount.instance.user?['id'] != owner) return;
      widget.onChanged(
        apply(
          result['active'] == true,
          (result['likeCount'] as num?)?.toInt() ?? count,
        ),
      );
    } catch (_) {
      if (mounted && HaneokaAccount.instance.user?['id'] == owner) {
        widget.onChanged(apply(liked, count));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final viewer = jsonMap(widget.record['viewer']);
    final liked = viewer['liked'] == true;
    final count = (widget.record['likeCount'] as num?)?.toInt() ?? 0;
    final color = liked
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    final label = count > 0 || !widget.showLabel
        ? '$count'
        : communityLabel(context, 'like', 'Like');
    return TextButton.icon(
      onPressed: viewer['canLike'] == false ? null : _toggle,
      style: TextButton.styleFrom(
        foregroundColor: color,
        minimumSize: const Size(40, 40),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        textStyle: widget.compact ? theme.textTheme.bodySmall : null,
      ),
      icon: Icon(
        Symbols.favorite_rounded,
        fill: liked ? 1 : 0,
        size: widget.compact ? 18 : 20,
      ),
      label: Text(label),
    );
  }
}
