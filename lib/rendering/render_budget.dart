/// Rendering budget of the story, chart and Live2D players on phones.
///
/// Phones render the native stages at no more than two physical pixels per
/// logical pixel and refresh them at most 60 times a second; desktops keep the
/// display's full resolution and rate.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

bool get _phone =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// The device pixel ratio a native stage renders at.
double renderPixelRatio(BuildContext context) {
  final ratio = MediaQuery.devicePixelRatioOf(context);
  return _phone && ratio > 2 ? 2 : ratio;
}

/// Admits at most one stage frame per 60 Hz interval on phones, so 90/120 Hz
/// displays do not render every vsync.
class FrameThrottle {
  Duration? _last;
  bool admit(Duration elapsed) {
    if (!_phone) return true;
    final last = _last;
    if (last != null &&
        elapsed - last < const Duration(microseconds: 15500) &&
        elapsed >= last) {
      return false;
    }
    _last = elapsed;
    return true;
  }

  void reset() => _last = null;
}
