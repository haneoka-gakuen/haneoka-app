import 'package:flutter/widgets.dart';

/// Opens website pages in the app's web view from native screens.
class SiteLinks {
  SiteLinks._();

  /// Set by the web shell while it is mounted.
  static void Function(Uri page)? load;

  /// Closes the native screens above the web view and shows [path] there.
  static void open(BuildContext context, String path, Uri origin) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    load?.call(origin.resolve(path));
  }
}
