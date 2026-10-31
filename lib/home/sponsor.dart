import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_state.dart';
import '../core/site_date.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/tile.dart';

const _afdian = 'https://afdian.com/a/haneoka';
const _patreon = 'https://www.patreon.com/cw/haneoka';
const _kofi = 'https://ko-fi.com/haneoka';
const _patreonLogo =
    '<svg viewBox="0 0 24 24"><circle cx="14.5" cy="9.5" r="7" fill="#000"/><rect x="3" y="2.5" width="3.5" height="19" rx="0.6" fill="#000"/></svg>';

/// T.G.W CARD tiers, highest first, as `config/sponsor.ts`.
const _tiers = [
  ('black', 'T.G.W CARD Black'),
  ('platinum', 'T.G.W CARD Platinum'),
  ('gold', 'T.G.W CARD Gold'),
  ('normal', 'T.G.W CARD Normal'),
];

String _plate(String tier) =>
    'https://haneoka.org/assets/jp/Assets/AddressableResources/Image/Tgw/tgwcard_${tier}_small.png';

/// The website's sponsor page (`SponsorPage.astro`): where to sponsor and the
/// sponsor list layered by T.G.W CARD tier, from `/data/sponsors/v1.json`.
class SponsorScreen extends StatefulWidget {
  const SponsorScreen({super.key});

  @override
  State<SponsorScreen> createState() => _SponsorScreenState();
}

class _SponsorScreenState extends State<SponsorScreen> {
  Future<Map>? _list;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _list ??= _load();
  }

  Future<Map> _load() async =>
      await AppScope.of(context).api
              .live('https://haneoka.org/data/sponsors/v1.json')
          as Map;

  @override
  Widget build(BuildContext context) {
    final text = AppScope.of(context).text;
    String k(String key) => text('legal.sponsor.$key');
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    void open(String url) =>
        launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

    Widget hero = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(k('heroTitle'), style: theme.textTheme.displaySmall),
        const SizedBox(height: 16),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Text(
            text('legal.sponsor.body.0'),
            style: theme.textTheme.titleMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w400,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
              onPressed: () => open(_afdian),
              icon: const Icon(Symbols.electric_bolt_rounded, fill: 1),
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(k('afdian')),
                  const SizedBox(width: 8),
                  const Icon(Symbols.open_in_new_rounded, size: 20),
                ],
              ),
            ),
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
              onPressed: () => open(_patreon),
              icon: SvgPicture.string(
                _patreonLogo,
                width: 20,
                height: 20,
                colorFilter: ColorFilter.mode(
                  scheme.onSecondaryContainer,
                  BlendMode.srcIn,
                ),
              ),
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(k('patreon')),
                  const SizedBox(width: 8),
                  const Icon(Symbols.open_in_new_rounded, size: 20),
                ],
              ),
            ),
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
              onPressed: () => open(_kofi),
              icon: const Icon(Symbols.local_cafe_rounded, fill: 1),
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(k('kofi')),
                  const SizedBox(width: 8),
                  const Icon(Symbols.open_in_new_rounded, size: 20),
                ],
              ),
            ),
          ],
        ),
      ],
    );

    Widget count(int n) => Container(
      constraints: const BoxConstraints(minWidth: 28),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$n',
        textAlign: TextAlign.center,
        style: theme.textTheme.labelLarge?.copyWith(
          color: scheme.onSecondaryContainer,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );

    Widget name(Map sponsor) {
      final label = '${sponsor['name'] ?? ''}';
      final avatar = sponsor['avatar'];
      final initial = label.characters.isEmpty
          ? ''
          : label.characters.first.toUpperCase();
      return Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            ClipOval(
              child: SizedBox.square(
                dimension: 40,
                child: avatar is String
                    ? AppImage(
                        candidates: [avatar],
                        fit: BoxFit.cover,
                        localized: false,
                      )
                    : ColoredBox(
                        color: scheme.primaryContainer,
                        child: Center(
                          child: Text(
                            initial,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: scheme.onPrimaryContainer,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
            ),
          ],
        ),
      );
    }

    Widget names(List<Map> sponsors) => LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 208).floor().clamp(1, 6);
        final width = (constraints.maxWidth - 8 * (columns - 1)) / columns;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final sponsor in sponsors)
              SizedBox(width: width, child: name(sponsor)),
          ],
        );
      },
    );

    Widget tier(String id, String title, List<Map> sponsors) => Container(
      margin: const EdgeInsets.only(top: 16),
      padding: EdgeInsets.all(narrow ? 16 : 20),
      decoration: BoxDecoration(
        color: id == 'black'
            ? scheme.surfaceContainerHighest
            : scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: narrow ? 120 : 150,
                child: AspectRatio(
                  aspectRatio: 300 / 140,
                  child: AppImage(
                    candidates: [_plate(id)],
                    fit: BoxFit.contain,
                    localized: false,
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 12),
                  count(sponsors.length),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (sponsors.isEmpty)
            Text(
              k('tierEmpty'),
              style: theme.textTheme.bodyLarge?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            )
          else
            names(sponsors),
        ],
      ),
    );

    return ShellPage(
      title: k('title'),
      body: FutureBuilder<Map>(
        future: _list,
        builder: (context, snapshot) {
          final list = snapshot.data;
          final active = (list?['active'] as List? ?? const [])
              .whereType<Map>()
              .toList();
          final past = (list?['past'] as List? ?? const [])
              .whereType<Map>()
              .toList();
          final updated = DateTime.tryParse('${list?['updatedAt']}');
          return ListView(
            padding: pagePadding(context).add(const EdgeInsets.only(top: 16)),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1040),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      hero,
                      const SizedBox(height: 48),
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.end,
                        spacing: 16,
                        runSpacing: 8,
                        children: [
                          Text(
                            k('wallTitle'),
                            style: theme.textTheme.headlineMedium,
                          ),
                          if (updated != null)
                            Text(
                              k('wallUpdated').replaceAll(
                                '{date}',
                                SiteDate.day(text.locale).format(updated),
                              ),
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                      if (list == null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 48),
                          child: Center(
                            child: snapshot.hasError
                                ? FilledButton.tonal(
                                    onPressed: () =>
                                        setState(() => _list = _load()),
                                    child: Text(text('common.actions.retry')),
                                  )
                                : const CircularProgressIndicator(),
                          ),
                        )
                      else ...[
                        for (final (id, title) in _tiers)
                          tier(id, title, [
                            for (final sponsor in active)
                              if (sponsor['tier'] == id) sponsor,
                          ]),
                        if (past.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      k('pastTitle'),
                                      style: theme.textTheme.titleLarge
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                    const SizedBox(width: 12),
                                    count(past.length),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 16,
                                  runSpacing: 6,
                                  children: [
                                    for (final sponsor in past)
                                      Text(
                                        '${sponsor['name'] ?? ''}',
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                              color: scheme.onSurfaceVariant,
                                            ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                      ],
                      const SizedBox(height: 48),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
