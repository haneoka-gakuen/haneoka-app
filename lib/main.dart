import 'core/analytics.dart';
import 'core/site_date.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';

import 'core/app_state.dart';
import 'core/app_media_lifetime.dart';
import 'core/music_background.dart';
import 'core/playback_focus.dart';
import 'l10n/app_localizations.dart';
import 'shell/shell.dart';
import 'gacha_history/history_page.dart';
import 'ui/save_screen.dart';
import 'ui/fonts.dart';
import 'ui/season_layer.dart';
import 'ui/theme.dart';
import 'team_builder/engine_client.dart'
    show runTeamEngineHost, runTeamEngineProcess;

Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty &&
      arguments.first.startsWith('--haneoka-team-engine-process=')) {
    await runTeamEngineProcess(
      arguments.first.substring('--haneoka-team-engine-process='.length),
    );
    return;
  }
  if (arguments.isNotEmpty &&
      arguments.first.startsWith('--haneoka-team-engine=')) {
    await runTeamEngineHost(
      arguments.first.substring('--haneoka-team-engine='.length),
    );
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  registerAppFontLicenses();
  MediaKit.ensureInitialized();
  await SiteDatePreferences.load();
  final state = await AppState.load(
    WidgetsBinding.instance.platformDispatcher.locale,
  );
  AppAnalytics.startLater(enabled: state.analytics);
  PlaybackFocus.prepare = MusicBackground.prepareSession;
  Uri? initialAddress;
  for (final argument in arguments) {
    if (argument.startsWith('-')) continue;
    final uri = Uri.tryParse(argument);
    if (uri != null &&
        const {'https', 'http', 'file', 'haneoka'}.contains(uri.scheme)) {
      initialAddress = uri;
      break;
    }
    if (FileSystemEntity.typeSync(argument) != FileSystemEntityType.notFound) {
      initialAddress = Uri.file(argument, windows: Platform.isWindows);
      break;
    }
  }
  runApp(
    AppMediaLifetime(
      child: AppScope(
        state: state,
        child: HaneokaApp(initialAddress: initialAddress),
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(
      MusicBackground.initialize(state.audio).catchError((
        Object error,
        StackTrace stack,
      ) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            context: ErrorDescription('initializing background audio controls'),
          ),
        );
      }),
    );
  });
}

class HaneokaApp extends StatelessWidget {
  const HaneokaApp({super.key, this.initialAddress});
  final Uri? initialAddress;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return MaterialApp(
      title: 'Haneoka',
      builder: (context, child) => SaveHistoryActionScope(
        onReadHistory: openGameHistory,
        child: SeasonLayer(
          motif: state.seasonEffects ? state.shownDecoration?.$1 : null,
          child: child!,
        ),
      ),
      locale: state.locale,
      theme: haneokaTheme(
        Brightness.light,
        seed: state.shownSeed,
        schemes: state.schemesFor(state.shownSeed),
        compact: state.compact,
        locale: state.locale,
      ),
      darkTheme: haneokaTheme(
        Brightness.dark,
        seed: state.shownSeed,
        schemes: state.schemesFor(state.shownSeed),
        compact: state.compact,
        locale: state.locale,
      ),
      themeMode: state.themeMode,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppShell(initialAddress: initialAddress),
    );
  }
}
