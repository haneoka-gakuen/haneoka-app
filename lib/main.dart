import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'account/haneoka_account.dart';
import 'core/app_state.dart';
import 'core/i18n.dart';
import 'l10n/app_localizations.dart';
import 'shell/history_action.dart';
import 'shell/page_theme.dart';
import 'ui/save_screen.dart';
import 'shell/strings.dart';
import 'shell/launch.dart';
import 'shell/web_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const HaneokaApp());
  unawaited(
    HaneokaAccount.instance.load().catchError((Object error) {
      debugPrint('Account startup: $error');
    }),
  );
}

class HaneokaApp extends StatefulWidget {
  const HaneokaApp({super.key});
  @override
  State<HaneokaApp> createState() => _HaneokaAppState();
}

class _HaneokaAppState extends State<HaneokaApp> {
  late Future<AppState> _state = _load();

  Future<AppState> _load() async {
    final locale = Strings.tag(
      WidgetsBinding.instance.platformDispatcher.locale,
    );
    final text = await SiteText.load(locale)
        .timeout(const Duration(seconds: 10));
    return AppState(locale == 'ja' ? 'jp' : 'intl', text);
  }

  late final _theme = ValueNotifier(
    PageTheme.fallback(
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
    ),
  );

  @override
  void dispose() {
    _theme.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AppState>(
    future: _state,
    builder: (context, snapshot) => ValueListenableBuilder(
      valueListenable: _theme,
      builder: (context, theme, _) {
        final strings = Strings.of(
          WidgetsBinding.instance.platformDispatcher.locale,
        );
        final app = MaterialApp(
          title: 'Haneoka',
          debugShowCheckedModeBanner: false,
          theme: theme.data,
          locale: switch (theme.locale) {
            'zh-CN' => const Locale.fromSubtags(
              languageCode: 'zh',
              scriptCode: 'Hans',
            ),
            'zh-TW' => const Locale.fromSubtags(
              languageCode: 'zh',
              scriptCode: 'Hant',
            ),
            final tag? => Locale(tag.split('-').first),
            null => null,
          },
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => SaveHistoryActionScope(
            onReadHistory: (context, save) => readHistoryToSite(context, save),
            child: child!,
          ),
          home: snapshot.hasData
              ? WebShell(theme: _theme)
              : Scaffold(
                  body: LaunchScreen(
                    t: strings,
                    progress: 0,
                    slow: false,
                    error: snapshot.hasError ? strings['startupFailed'] : null,
                    errorTitle: strings['startupFailed'],
                    onRetry: () => setState(() => _state = _load()),
                  ),
                ),
        );
        if (snapshot.data case final state?) {
          return AppScope(state: state, child: app);
        }
        return app;
      },
    ),
  );
}
