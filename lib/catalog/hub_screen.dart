import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/app_state.dart';
import '../shell/navigation.dart';
import '../shell/page.dart';
import '../ui/shapes.dart';
import '../ui/tile.dart';

/// Each hub route's API resource, whose size the hub shows (`CATALOG_HUB`).
const _counted = {
  '/catalog/songs': 'songs',
  '/catalog/characters': 'characters',
  '/catalog/member-cards': 'cards',
  '/catalog/support-cards': 'support-cards',
  '/catalog/comics': 'comics',
  '/catalog/events': 'events',
  '/catalog/gacha': 'gacha',
  '/catalog/login-campaigns': 'login-campaigns',
  '/catalog/missions': 'missions',
  '/catalog/passes': 'passes',
  '/catalog/tgw-card': 'tgw-card',
  '/catalog/shop': 'shop',
  '/catalog/exchange': 'exchange',
  '/catalog/stamps': 'stamps',
  '/catalog/stickers': 'stickers',
  '/catalog/backgrounds': 'backgrounds',
  '/catalog/items': 'items',
  '/catalog/band-items': 'band-items',
  '/catalog/real-lives': 'real-lives',
};

/// The catalogue destination's own page (`CatalogIndexPage`): the library
/// section as a grid of hub links with each collection's size.
class CatalogHubScreen extends StatefulWidget {
  const CatalogHubScreen({
    super.key,
    required this.navigate,
    this.section = 'library',
  });
  final ValueChanged<String> navigate;
  final String section;
  @override
  State<CatalogHubScreen> createState() => _CatalogHubScreenState();
}

class _CatalogHubScreenState extends State<CatalogHubScreen> {
  Future<Object?>? _summary;
  Object? _dataKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    if (_dataKey != state.publicDataKey) {
      _dataKey = state.publicDataKey;
      _summary = state.api.json(
        '/api/v1/servers/${state.server}/catalog/summary',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    final theme = Theme.of(context);
    final number = NumberFormat.decimalPattern(t.locale);
    final library = navSections.firstWhere((s) => s.id == widget.section);
    return ShellPage(
      title: t(
        widget.section == 'library'
            ? 'navigation.catalog'
            : 'navigation.${widget.section}',
        'Catalog',
      ),
      body: FutureBuilder(
        future: _summary,
        builder: (context, snapshot) {
          final resources =
              (snapshot.data as Map?)?['resources'] as Map? ?? const {};
          String? count(String route) {
            final value = (resources[_counted[route]] as Map?)?['count'];
            return value is num ? number.format(value) : null;
          }

          return LayoutBuilder(
            builder: (context, constraints) {
              final padding = pagePadding(context);
              final width = constraints.maxWidth - padding.horizontal;
              final columns = width < 600 - padding.horizontal
                  ? 2
                  : ((width + 8) / 228).floor().clamp(1, 8);
              return ListView(
                padding: padding,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
                    child: Text(
                      t(library.label),
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      mainAxisExtent: 64,
                    ),
                    itemCount: library.items.length,
                    itemBuilder: (context, index) {
                      final item = library.items[index];
                      return HubLink(
                        icon: item.icon,
                        label: t(item.label),
                        count: count(item.route),
                        onTap: () => widget.navigate(item.route),
                      );
                    },
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
