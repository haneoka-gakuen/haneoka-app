import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../account/haneoka_account.dart';
import '../core/app_state.dart';
import '../shell/page.dart';
import '../core/catalog_source.dart';
import 'source_route.dart';

BarAction catalogSourceAction(BuildContext context, String path) => BarAction(
  icon: Symbols.source_rounded,
  label: AppScope.of(context).text('common.fields.source'),
  onPressed: () => openCatalogSources(context, path),
);

Future<void> openCatalogSources(BuildContext context, String path) async {
  final state = AppScope.of(context), t = state.text;
  final currentSource = CatalogSourceScope.serverOf(context);
  Future<Object?> load() =>
      HaneokaAccount.instance.request('GET', '/api/v1/account/content-access');
  var loading = load();
  final selected = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(t('common.fields.source')),
        content: SizedBox(
          width: 400,
          height: 360,
          child: FutureBuilder(
            future: loading,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: FilledButton.tonal(
                    onPressed: () => setState(() => loading = load()),
                    child: Text(t('common.actions.retry')),
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final access = snapshot.data as Map;
              final sources = <String>{
                'jp',
                'intl',
                if (access['allowed'] == true)
                  ...(access['sources'] as List).cast<String>(),
              };
              return ListView(
                children: [
                  for (final source in sources)
                    ListTile(
                      title: Text(
                        t(
                          'tools.teamBuilder.boxImport.servers.$source',
                          source,
                        ),
                      ),
                      trailing: currentSource == source
                          ? const Icon(Symbols.check_rounded)
                          : null,
                      onTap: () => Navigator.pop(context, source),
                    ),
                ],
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('common.actions.cancel')),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted || selected == null) return;
  if (const ['jp', 'intl'].contains(selected)) {
    await state.setServer(selected);
    if (context.mounted && CatalogSourceScope.maybeApi(context) != null) {
      final api = CatalogSourceScope.maybeApi(context)!;
      if (const {'jp', 'intl'}.contains(api.server)) {
        ShellScope.of(context)?.navigate(path);
      } else {
        Navigator.of(context).pop();
      }
    }
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: RouteSettings(name: '$path?source=$selected'),
      builder: (_) =>
          NativeCatalogSourceRoute(route: Uri.parse(path), source: selected),
    ),
  );
}
