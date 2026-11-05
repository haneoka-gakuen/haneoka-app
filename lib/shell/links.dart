import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import 'site.dart';
import 'web_shell.dart' show origin;

/// A website path opens in the app's web view; other addresses in the
/// system's apps.
Future<bool> openLink(
  BuildContext context,
  String href, {
  ValueChanged<String>? navigate,
}) async {
  final uri = Uri.tryParse(href);
  if (uri == null) return false;
  if (!uri.hasScheme || uri.host == origin.host) {
    SiteLinks.open(context, uri.hasScheme ? uri.toString() : href, origin);
    return true;
  }
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
