/// Usage analytics through Firebase on Android and iOS; the reader can turn
/// it off in Settings.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

abstract final class AppAnalytics {
  static const _android = FirebaseOptions(
    apiKey: 'AIzaSyDG9rijPFVhIpcH2ZWBV9f0LtslF7stx6g',
    appId: '1:271263066270:android:27c11248838b71dc35f38f',
    messagingSenderId: '271263066270',
    projectId: 'haneoka',
    storageBucket: 'haneoka.firebasestorage.app',
  );
  static const _ios = FirebaseOptions(
    apiKey: 'AIzaSyBn47tVcJIxn-xPP7qqVuDZyeFbSbFjnrk',
    appId: '1:271263066270:ios:8ef17c70b269c76435f38f',
    messagingSenderId: '271263066270',
    projectId: 'haneoka',
    storageBucket: 'haneoka.firebasestorage.app',
    iosBundleId: 'org.haneoka.haneoka',
  );
  static FirebaseAnalytics? _analytics;
  static String? _lastScreen, _pending;

  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Starts once the first screen is up and the app has been idle a moment, so
  /// nothing the reader waits for shares the network or startup with it. The
  /// SDK then batches events and uploads them in the background.
  static void startLater({required bool enabled}) {
    if (!supported) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      Timer(const Duration(seconds: 5), () {
        SchedulerBinding.instance.scheduleTask(
          () => _start(enabled: enabled),
          Priority.idle,
        );
      });
    });
  }

  static Future<void> _start({required bool enabled}) async {
    try {
      await Firebase.initializeApp(options: Platform.isIOS ? _ios : _android);
      final analytics = FirebaseAnalytics.instance;
      await analytics.setAnalyticsCollectionEnabled(enabled);
      _analytics = analytics;
      if (_pending case final name?) {
        analytics.logScreenView(screenName: name.isEmpty ? '/' : name).ignore();
      }
    } catch (error) {
      debugPrint('analytics unavailable: $error');
    }
  }

  static Future<void> setEnabled(bool enabled) async =>
      _analytics?.setAnalyticsCollectionEnabled(enabled);

  /// A page view under the route's shape: IDs become `:id` so no player,
  /// post or account number leaves the device.
  static void screen(String route) {
    final path = Uri.parse(route).path;
    final name = path
        .split('/')
        .map(
          (part) =>
              RegExp(r'^\d+$|^[0-9a-f-]{16,}$').hasMatch(part) ? ':id' : part,
        )
        .join('/');
    if (name == _lastScreen) return;
    _lastScreen = name;
    final analytics = _analytics;
    if (analytics == null) {
      _pending = name;
      return;
    }
    analytics.logScreenView(screenName: name.isEmpty ? '/' : name).ignore();
  }
}
