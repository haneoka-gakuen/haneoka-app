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
import 'shell/web_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final locale = Strings.tag(WidgetsBinding.instance.platformDispatcher.locale);
  final state = AppState(
    locale == 'ja' ? 'jp' : 'intl',
    await SiteText.load(locale),
  );
  HaneokaAccount.instance.load();
  runApp(AppScope(state: state, child: const HaneokaApp()));
}

class HaneokaApp extends StatefulWidget {
  const HaneokaApp({super.key});
  @override
  State<HaneokaApp> createState() => _HaneokaAppState();
}

class _HaneokaAppState extends State<HaneokaApp> {
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
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: _theme,
    builder: (context, theme, _) => MaterialApp(
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
      home: WebShell(theme: _theme),
    ),
  );
}
