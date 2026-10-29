import '../core/catalog_source.dart';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../shell/page.dart';
import '../ui/theme.dart';

List<Map> _values(Object? value) => switch (value) {
  Map() => value.values.whereType<Map>().toList(),
  List() => value.whereType<Map>().toList(),
  _ => <Map>[],
};

num _num(Object? value) => value is num ? value : 0;

Object? _helpText(Object? preferred, Object? other) {
  if (preferred is List && other is List) {
    return [
      for (
        var i = 0;
        i < (preferred.length > other.length ? preferred.length : other.length);
        i++
      )
        (preferred.elementAtOrNull(i) is String &&
                (preferred[i] as String).isNotEmpty)
            ? preferred[i]
            : other.elementAtOrNull(i),
    ];
  }
  return preferred == null || preferred == '' ? other : preferred;
}

Future<Map<String, Object?>> _loadHelp(BuildContext context) async {
  final selected = CatalogSourceScope.serverOf(context),
      apis = CatalogSourceScope.apisOf(context);
  final sources = await Future.wait([
    for (final entry in apis.entries)
      entry.value
          .catalog('help')
          .then((data) => (entry.key, (data as Map).cast<String, Object?>())),
  ]);
  final documents = {for (final (server, data) in sources) server: data},
      categories = <String, Map>{},
      tips = <String, Map>{};
  for (final server in [selected, ...apis.keys.where((s) => s != selected)]) {
    final data = documents[server]!;
    for (final category in _values(data['categories'])) {
      final target = categories.putIfAbsent(
        '${category['categoryId']}',
        () => {...category, 'subcategories': <String, Map>{}},
      );
      target['title'] = _helpText(target['title'], category['title']);
      final topics = target['subcategories'] as Map<String, Map>;
      for (final entry in _values(category['subcategories'])) {
        final id = '${entry['helpSubcategoryId']}';
        final old = topics[id];
        topics[id] = old == null
            ? {...entry, '_server': server}
            : {
                ...old,
                'title': _helpText(old['title'], entry['title']),
                'description': _helpText(
                  old['description'],
                  entry['description'],
                ),
              };
      }
    }
    for (final tip in _values(data['loadingTips'])) {
      final id = '${tip['tipId']}', old = tips[id];
      tips[id] = old == null
          ? {...tip, '_server': server}
          : {
              ...old,
              'title': _helpText(old['title'], tip['title']),
              'description': _helpText(old['description'], tip['description']),
            };
    }
  }
  return {
    ...documents[selected]!,
    'categories': [
      for (final row in categories.values)
        {
          ...row,
          'subcategories': (row['subcategories'] as Map).values.toList(),
        },
    ],
    'loadingTips': tips.values.toList(),
  };
}

/// The game's help (`help-workspace`): the manual by category, or the
/// loading tips; each topic opens in place.
class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key, this.id, this.initialMode});
  final String? id, initialMode;
  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  Future<Object?>? _data;
  Object? _dataKey;
  late String _mode = widget.initialMode == 'tips' ? 'tips' : 'manual';
  int? _category;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final key = CatalogSourceScope.keyOf(context);
    if (_dataKey != key) {
      _dataKey = key;
      _data = _loadHelp(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (widget.id != null) {
      return FutureBuilder(
        future: _data,
        builder: (context, snapshot) {
          final document = snapshot.data as Map?;
          final entries = [
            for (final category in _values(document?['categories']))
              ..._values(category['subcategories']),
          ];
          final entry = entries
              .where((e) => '${e['helpSubcategoryId']}' == widget.id)
              .firstOrNull;
          return ShellPage(
            title: entry == null
                ? t('navigation.help')
                : t.text(entry['title']),
            showBack: true,
            body: entry == null
                ? Center(
                    child: snapshot.connectionState == ConnectionState.waiting
                        ? const CircularProgressIndicator()
                        : Text(t('common.states.unavailable')),
                  )
                : ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      SelectableText(
                        t.text(entry['description']).replaceAll('\r', ''),
                        style: theme.textTheme.bodyLarge,
                      ),
                    ],
                  ),
          );
        },
      );
    }
    return ShellPage(
      title: t('navigation.help', 'Help'),
      actions: [
        BarAction.choice(
          label: t('common.actions.view', 'View'),
          options: [
            BarChoice(
              icon: Symbols.menu_book_rounded,
              label: t('settings.labels.manual', 'Manual'),
              selected: _mode == 'manual',
              onSelected: () => setState(() => _mode = 'manual'),
            ),
            BarChoice(
              icon: Symbols.lightbulb_rounded,
              label: t('settings.labels.loadingTips', 'Loading tips'),
              selected: _mode == 'tips',
              onSelected: () => setState(() => _mode = 'tips'),
            ),
          ],
        ),
      ],
      body: FutureBuilder(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: FilledButton.tonal(
                onPressed: () => setState(() => _data = _loadHelp(context)),
                child: Text(t('common.actions.retry', 'Retry')),
              ),
            );
          }
          final document = snapshot.data as Map?;
          if (document == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final categories = _values(document['categories'])
            ..sort((a, b) => _num(a['order']).compareTo(_num(b['order'])));
          final tips = _values(document['loadingTips'])
            ..sort((a, b) => _num(a['tipId']).compareTo(_num(b['tipId'])));
          final category = categories.firstWhere(
            (c) => c['categoryId'] == _category,
            orElse: () => categories.isEmpty ? const {} : categories.first,
          );
          final entries = _mode == 'tips'
              ? tips
              : _values(category['subcategories']);
          final wide = MediaQuery.sizeOf(context).width > 760;

          Widget categoryButton(Map item) {
            final selected = identical(item, category);
            return Material(
              color: selected ? scheme.secondaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(Corner.large),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => setState(
                  () => _category = (item['categoryId'] as num?)?.toInt(),
                ),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 48),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
                    children: [
                      Icon(
                        Symbols.topic_rounded,
                        size: 20,
                        color: selected ? scheme.onSecondaryContainer : null,
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        fit: wide ? FlexFit.tight : FlexFit.loose,
                        child: Text(
                          t.text(item['title']).isEmpty
                              ? '—'
                              : t.text(item['title']),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: selected
                                ? scheme.onSecondaryContainer
                                : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${_values(item['subcategories']).length}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          final list = ListView(
            key: ValueKey('$_mode:${category['categoryId']}'),
            padding: EdgeInsets.all(wide ? 16 : 12),
            children: [
              for (final (index, item) in entries.indexed)
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: scheme.outlineVariant),
                    ),
                  ),
                  child: Theme(
                    data: theme.copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      initiallyExpanded: index == 0 && entries.length < 8,
                      trailing: _mode != 'manual'
                          ? null
                          : IconButton(
                              tooltip: t('common.actions.open'),
                              icon: const Icon(Symbols.open_in_new_rounded),
                              onPressed: () {
                                final api = CatalogSourceScope.apiOf(context);
                                Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    settings: RouteSettings(
                                      name: Uri(
                                        path:
                                            '/catalog/help/${item['helpSubcategoryId']}',
                                        queryParameters: {'server': api.server},
                                      ).toString(),
                                    ),
                                    builder: (_) => CatalogSourceScope(
                                      api: api,
                                      child: HelpScreen(
                                        id: '${item['helpSubcategoryId']}',
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                      shape: const Border(),
                      collapsedShape: const Border(),
                      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                      title: Text(
                        t.text(item['title']).isEmpty
                            ? '—'
                            : t.text(item['title']),
                        style: theme.textTheme.titleSmall,
                      ),
                      expandedAlignment: Alignment.centerLeft,
                      childrenPadding: EdgeInsets.fromLTRB(
                        wide ? 16 : 12,
                        0,
                        wide ? 48 : 12,
                        wide ? 20 : 16,
                      ),
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 640),
                          child: SelectableText(
                            t.text(item['description']).replaceAll('\r', ''),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                              height: 1.7,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
          if (_mode == 'tips') return list;
          final rail = wide
              ? Container(
                  width: 260,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    border: Border(
                      right: BorderSide(color: scheme.outlineVariant),
                    ),
                  ),
                  child: ListView(
                    padding: const EdgeInsets.all(8),
                    children: [
                      for (final item in categories)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: categoryButton(item),
                        ),
                    ],
                  ),
                )
              : Container(
                  height: 64,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    border: Border(
                      bottom: BorderSide(color: scheme.outlineVariant),
                    ),
                  ),
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(8),
                    children: [
                      for (final item in categories)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: categoryButton(item),
                        ),
                    ],
                  ),
                );
          return Flex(
            direction: wide ? Axis.horizontal : Axis.vertical,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              rail,
              Expanded(child: list),
            ],
          );
        },
      ),
    );
  }
}
