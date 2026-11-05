import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import 'site.dart';
import '../core/site_origin.dart';

/// A website path opens in the app's web view; other addresses in the
/// system's apps.
Future<bool> openLink(
  BuildContext context,
  String href, {
  ValueChanged<String>? navigate,
}) async {
  final uri = Uri.tryParse(href);
  if (uri == null) return false;
  final site = SiteOrigin.instance;
  if (!uri.hasScheme || site.contains(uri)) {
    SiteLinks.open(
      context,
      uri.hasScheme ? site.local(uri).toString() : href,
      site.value,
    );
    return true;
  }
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
