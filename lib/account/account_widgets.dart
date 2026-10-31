import '../core/site_date.dart';
import 'package:flutter/material.dart';

import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../l10n/app_localizations.dart';
import '../save/game_save.dart';
import '../shell/links.dart';
import '../ui/app_image.dart';
import '../ui/shapes.dart';
import '../ui/theme.dart';
import 'haneoka_account.dart';
import 'profile_screen.dart';
import 'sign_in_screen.dart';

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// Opens the native sign-in screen.
Future<void> signInToHaneoka(BuildContext context) => openSignIn(context);

class _Avatar extends StatelessWidget {
  const _Avatar({required this.image});
  final String? image;
  static const double size = 56;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = switch (image) {
      final String value when value.startsWith('/') =>
        'https://haneoka.org$value',
      final String value when value.startsWith('https://') => value,
      _ => null,
    };
    return ClipOval(
      child: Container(
        width: size,
        height: size,
        color: scheme.secondaryContainer,
        child: url == null
            ? Icon(
                Symbols.person_rounded,
                size: size / 2,
                color: scheme.onSecondaryContainer,
              )
            : AppImage(candidates: [url], fit: BoxFit.cover, localized: false),
      ),
    );
  }
}

/// The Haneoka account at the top of Account: who is signed in, or why
/// signing in is worth it.
class HaneokaAccountCard extends StatefulWidget {
  const HaneokaAccountCard({super.key});
  @override
  State<HaneokaAccountCard> createState() => _HaneokaAccountCardState();
}

class _HaneokaAccountCardState extends State<HaneokaAccountCard> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    HaneokaAccount.instance.load();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final site = AppScope.of(context).text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: HaneokaAccount.instance,
      builder: (context, _) {
        final account = HaneokaAccount.instance;
        final user = account.user;
        final Widget body;
        if (account.signedIn && user != null) {
          final name = '${user['name'] ?? ''}'.trim();
          final email = '${user['email'] ?? ''}';
          final uid = user['uid'];
          body = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _Avatar(image: user['image'] as String?),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name.isEmpty ? email : name,
                          style: theme.textTheme.titleLarge,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (name.isNotEmpty && email.isNotEmpty)
                          Text(
                            email,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (uid != null)
                    FilledButton.tonalIcon(
                      onPressed: () => openLink(
                        context,
                        '/${site.locale}/community/users/$uid/',
                      ),
                      icon: const Icon(Symbols.account_circle_rounded),
                      label: Text(t.openProfile),
                    ),
                  FilledButton.tonalIcon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AccountProfileScreen(),
                      ),
                    ),
                    icon: const Icon(Symbols.manage_accounts_rounded),
                    label: Text(site('account.page.profile', 'Profile')),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _run(account.signOut),
                    icon: const Icon(Symbols.logout_rounded),
                    label: Text(t.signOut),
                  ),
                ],
              ),
            ],
          );
        } else {
          body = Row(
            children: [
              ShapedIcon(
                shape: MaterialShapes.cookie9Sided,
                size: 56,
                child: const Icon(Symbols.cloud_sync_rounded, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.haneokaAccount, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      t.haneokaAccountSummary,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _run(() => signInToHaneoka(context)),
                      icon: const Icon(Symbols.login_rounded),
                      label: Text(t.signIn),
                    ),
                  ],
                ),
              ),
            ],
          );
        }
        return Material(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Corner.extraLarge),
          child: Padding(padding: const EdgeInsets.all(20), child: body),
        );
      },
    );
  }
}

/// A player's link to the Haneoka account, on the player's page.
class PlayerLink extends StatefulWidget {
  const PlayerLink({super.key, required this.save});
  final GameSave save;
  @override
  State<PlayerLink> createState() => _PlayerLinkState();
}

class _PlayerLinkState extends State<PlayerLink> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    HaneokaAccount.instance.load();
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await action();
      if (mounted && done != null) _say(context, done);
    } on AccountError catch (error) {
      if (mounted) {
        _say(
          context,
          error.code == 'player_linked' ? t.linkedElsewhere : t.linkFailed,
        );
      }
    } catch (_) {
      if (mounted) _say(context, t.linkFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlink() async {
    final t = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Symbols.link_off_rounded),
        content: Text(t.unlinkConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.unlink),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _run(() => HaneokaAccount.instance.unlink(widget.save));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    return ListenableBuilder(
      listenable: HaneokaAccount.instance,
      builder: (context, _) {
        final account = HaneokaAccount.instance;
        final link = account.linkOf(widget.save);
        final note = Text(
          t.linkExplain,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        );
        final List<Widget> children;
        if (!account.signedIn) {
          children = [
            Text(t.linkSignInFirst, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(() => signInToHaneoka(context)),
                icon: const Icon(Symbols.login_rounded),
                label: Text(t.signIn),
              ),
            ),
            const SizedBox(height: 12),
            note,
          ];
        } else if (link == null) {
          children = [
            note,
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => account.link(widget.save, public: true),
                        done: t.linkUpdated,
                      ),
                icon: const Icon(Symbols.link_rounded),
                label: Text(t.linkToProfile),
              ),
            ),
          ];
        } else {
          children = [
            Row(
              children: [
                Icon(Symbols.link_rounded, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  t.linked,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: scheme.primary,
                  ),
                ),
                if (link.syncedAt case final synced?) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      t.syncedOn(
                        SiteDate.day(locale).withTime().format(synced),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.showOnProfile),
              value: link.public,
              onChanged: _busy
                  ? null
                  : (value) =>
                        _run(() => account.link(widget.save, public: value)),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => account.link(widget.save),
                          done: t.linkUpdated,
                        ),
                  icon: const Icon(Symbols.sync_rounded),
                  label: Text(t.syncNow),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : _unlink,
                  icon: const Icon(Symbols.link_off_rounded),
                  label: Text(t.unlink),
                ),
              ],
            ),
            const SizedBox(height: 8),
            note,
          ];
        }
        return Material(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(Corner.large),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        );
      },
    );
  }
}
