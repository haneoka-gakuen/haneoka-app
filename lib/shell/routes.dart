import 'package:flutter/material.dart';

import '../catalog/cross_server.dart' show serverKey;
import '../catalog/profiles.dart';
import '../core/api.dart';
import '../core/app_state.dart';
import 'links.dart';

/// An entity's website page, opened in the app's web view.
void openEntity(
  BuildContext context,
  CatalogProfile profile,
  Map<String, Object?> item, {
  List<Map<String, Object?>>? siblings,
  HaneokaApi? api,
}) {
  final state = AppScope.of(context);
  final itemServer = item[serverKey];
  final server =
      itemServer is String && const {'jp', 'intl'}.contains(itemServer)
      ? itemServer
      : (api?.server ?? state.server);
  final id = '${firstOf(item, profile.id) ?? item['_key']}';
  final kind = profile.resource == 'cards' ? 'member-cards' : profile.resource;
  openLink(
    context,
    '/$server/${state.text.locale}/$kind/${Uri.encodeComponent(id)}/',
  );
}

/// Other catalogue sources are website pages; no native screen exists.
Widget? screenFor(String path, {ValueChanged<String>? navigate}) => null;

class PendingScreen extends StatelessWidget {
  const PendingScreen({super.key, required this.label});
  final String label;
  @override
  Widget build(BuildContext context) =>
      Center(child: Text(AppScope.of(context).text(label)));
}
