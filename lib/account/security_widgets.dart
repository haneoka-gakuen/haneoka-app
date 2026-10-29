import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../ui/app_image.dart';
import '../ui/detail.dart';
import 'haneoka_account.dart';

class AccountAvatar extends StatefulWidget {
  const AccountAvatar({super.key});
  @override
  State<AccountAvatar> createState() => _AccountAvatarState();
}

class _AccountAvatarState extends State<AccountAvatar> {
  Object? _owner = HaneokaAccount.instance.user?['id'];
  Uint8List? _bytes;
  String? _name;
  String? _type;
  bool _busy = false;
  String label(String key, String fallback) =>
      AppScope.of(context).text('account.page.$key', fallback);
  void say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  Future<void> pick() async {
    final result = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'webp'],
    );
    if (!mounted || result == null) return;
    final file = result;
    final length = await file.length();
    if (!mounted) return;
    if (length == null || length == 0 || length > 2 * 1024 * 1024) {
      say(label('avatarTooLarge', 'The avatar must be 2 MB or smaller.'));
      return;
    }
    final type = switch (file.extension?.toLowerCase()) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      _ => null,
    };
    if (type == null) {
      say(label('avatarUnsupported', 'Choose a JPEG, PNG, or WebP image.'));
      return;
    }
    try {
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      if (bytes.isEmpty || bytes.length > 2 * 1024 * 1024) {
        say(label('avatarTooLarge', 'The avatar must be 2 MB or smaller.'));
        return;
      }
      setState(() {
        _bytes = bytes;
        _name = file.name;
        _type = type;
      });
    } catch (_) {
      if (mounted) {
        say(label('avatarUploadFailed', 'The avatar could not be uploaded.'));
      }
    }
  }

  Future<void> submit({bool remove = false}) async {
    setState(() => _busy = true);
    try {
      await HaneokaAccount.instance.request(
        remove ? 'DELETE' : 'PUT',
        '/api/v1/account/avatar',
        bytes: remove ? null : _bytes,
        headers: remove
            ? const {}
            : {
                'content-type': _type!,
                'x-file-name': Uri.encodeComponent(_name!),
              },
      );
      await HaneokaAccount.instance.refresh();
      if (mounted) {
        setState(() {
          _bytes = null;
          _name = _type = null;
        });
        say(
          label(
            remove ? 'avatarDeleted' : 'avatarPending',
            remove ? 'Avatar deleted.' : 'Your avatar is being reviewed.',
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        say(
          label(
            remove ? 'avatarDeleteFailed' : 'avatarUploadFailed',
            'The avatar could not be updated.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: HaneokaAccount.instance,
    builder: (context, _) {
      final owner = HaneokaAccount.instance.user?['id'];
      if (owner != _owner) {
        _owner = owner;
        _bytes = null;
        _name = _type = null;
      }
      final profile = HaneokaAccount.instance.profile ?? const {};
      final url = profile['avatarUrl'];
      final review = profile['avatarReview'] as Map?;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label('avatar', 'Avatar'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ClipOval(
                child: SizedBox.square(
                  dimension: 72,
                  child: _bytes != null
                      ? Image.memory(_bytes!, fit: BoxFit.cover)
                      : url is String && url.isNotEmpty
                      ? AppImage(
                          candidates: [
                            AppScope.of(context).api.asset(url).toString(),
                          ],
                        )
                      : const ColoredBox(
                          color: Colors.transparent,
                          child: Icon(Symbols.person_rounded, size: 40),
                        ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : pick,
                icon: const Icon(Symbols.photo_library_rounded),
                label: Text(label('chooseAvatar', 'Choose avatar')),
              ),
              if (_bytes != null) ...[
                FilledButton(
                  onPressed: _busy ? null : submit,
                  child: Text(label('uploadAvatar', 'Upload')),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _bytes = null;
                          _name = _type = null;
                        }),
                  child: Text(
                    AppScope.of(context)
                        .text('common.actions.cancel', 'Cancel'),
                  ),
                ),
              ],
              if (url != null || review != null)
                TextButton(
                  onPressed: _busy ? null : () => submit(remove: true),
                  child: Text(label('deleteAvatar', 'Delete avatar')),
                ),
            ],
          ),
          if (review != null && review['status'] != 'ready')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                label(
                  review['moderationStatus'] == 'block'
                      ? 'avatarBlocked'
                      : 'avatarPending',
                  'Your avatar is being reviewed.',
                ),
              ),
            ),
        ],
      );
    },
  );
}

class AccountSecurity extends StatefulWidget {
  const AccountSecurity({super.key});
  @override
  State<AccountSecurity> createState() => _AccountSecurityState();
}

class _AccountSecurityState extends State<AccountSecurity> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  late Future<List<Map>> _providers = _loadProviders();
  Future<List<Map>> _loadProviders() async =>
      (await HaneokaAccount.instance.request('GET', '/api/auth/list-accounts')
                  as List? ??
              const [])
          .whereType<Map>()
          .toList();
  String label(String key, String fallback) =>
      AppScope.of(context).text('account.page.$key', fallback);
  @override
  void dispose() {
    _email.dispose();
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action, String success) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(success)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(label('authFailed', 'Authentication failed.')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> password() async {
    if (!_form.currentState!.validate()) return;
    await run(() async {
      await HaneokaAccount.instance.changePassword(_current.text, _new.text);
      _current.clear();
      _new.clear();
      _confirm.clear();
    }, label('passwordChanged', 'Password changed.'));
  }

  @override
  Widget build(BuildContext context) => DetailFold(
    title: label('security', 'Sign-in & security'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${label('currentEmail', 'Current email address')}: ${HaneokaAccount.instance.user?['email'] ?? ''}',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          maxLength: 254,
          decoration: InputDecoration(
            labelText: label('newEmail', 'New email address'),
            border: const OutlineInputBorder(),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _busy
                ? null
                : () {
                    final email = _email.text.trim();
                    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                        .hasMatch(email)) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            label(
                              'invalidEmail',
                              'Enter a valid email address.',
                            ),
                          ),
                        ),
                      );
                      return;
                    }
                    run(() async {
                      await HaneokaAccount.instance.request(
                        'POST',
                        '/api/auth/change-email',
                        body: {
                          'newEmail': email,
                          'callbackURL': '/account?verified=1',
                        },
                      );
                      _email.clear();
                    }, label('emailChangeSent', 'Check your new inbox.'));
                  },
            child: Text(label('changeEmail', 'Change email')),
          ),
        ),
        const SizedBox(height: 16),
        FutureBuilder(
          future: _providers,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return TextButton(
                onPressed: () => setState(() => _providers = _loadProviders()),
                child: Text(
                  AppScope.of(context).text('common.actions.retry', 'Retry'),
                ),
              );
            }
            final providers = snapshot.data;
            if (providers == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (providers.any((p) => p['providerId'] == 'credential'))
                  Form(
                    key: _form,
                    child: Column(
                      children: [
                        for (final (controller, key, fallback) in [
                          (_current, 'currentPassword', 'Current password'),
                          (_new, 'newPassword', 'New password'),
                          (_confirm, 'confirmPassword', 'Confirm new password'),
                        ])
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: TextFormField(
                              controller: controller,
                              obscureText: true,
                              maxLength: 128,
                              autofillHints: [
                                controller == _current
                                    ? AutofillHints.password
                                    : AutofillHints.newPassword,
                              ],
                              decoration: InputDecoration(
                                labelText: label(key, fallback),
                                border: const OutlineInputBorder(),
                              ),
                              validator: (value) {
                                if (value == null || value.isEmpty) {
                                  return label(key, fallback);
                                }
                                if (controller != _current &&
                                    value.length < 12) {
                                  return label(
                                    'passwordHint',
                                    'Use at least 12 characters.',
                                  );
                                }
                                if (controller == _confirm &&
                                    value != _new.text) {
                                  return label(
                                    'passwordMismatch',
                                    'The passwords do not match.',
                                  );
                                }
                                return null;
                              },
                            ),
                          ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton(
                            onPressed: _busy ? null : password,
                            child: Text(
                              label('changePassword', 'Change password'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                for (final provider in providers)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${provider['providerId']}'),
                    subtitle: Text(label('linked', 'Linked')),
                    trailing:
                        providers.length < 2 ||
                            provider['providerId'] == 'credential'
                        ? null
                        : TextButton(
                            onPressed: _busy
                                ? null
                                : () => run(
                                    () async {
                                      await HaneokaAccount.instance.request(
                                        'POST',
                                        '/api/auth/unlink-account',
                                        body: {
                                          'providerId': provider['providerId'],
                                          'accountId': provider['accountId'],
                                        },
                                      );
                                      setState(
                                        () => _providers = _loadProviders(),
                                      );
                                    },
                                    label(
                                      'accountUnlinked',
                                      'Account unlinked.',
                                    ),
                                  ),
                            child: Text(label('unlink', 'Unlink')),
                          ),
                  ),
              ],
            );
          },
        ),
      ],
    ),
  );
}

class DeleteAccount extends StatefulWidget {
  const DeleteAccount({super.key});
  @override
  State<DeleteAccount> createState() => _DeleteAccountState();
}

class _DeleteAccountState extends State<DeleteAccount> {
  final _confirmation = TextEditingController();
  bool _busy = false;
  String label(String key, String fallback) =>
      AppScope.of(context).text('account.page.$key', fallback);
  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DetailFold(
    title: label('deleteAccount', 'Delete account'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label(
            'deleteAccountDescription',
            'Disable sign-in and hide your community content.',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _confirmation,
          keyboardType: TextInputType.emailAddress,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: label('currentEmail', 'Current email address'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed:
                _busy ||
                    _confirmation.text != HaneokaAccount.instance.user?['email']
                ? null
                : () async {
                    setState(() => _busy = true);
                    try {
                      await HaneokaAccount.instance.deleteAccount(
                        _confirmation.text,
                      );
                      if (context.mounted) Navigator.of(context).pop();
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              label(
                                'deleteFailed',
                                'The account could not be deleted.',
                              ),
                            ),
                          ),
                        );
                      }
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
            child: Text(label('deleteAccount', 'Delete account')),
          ),
        ),
      ],
    ),
  );
}
