import '../core/analytics.dart';
import '../core/site_date.dart';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../catalog/visuals.dart';
import '../core/app_state.dart';
import '../ui/schemes.g.dart';
import '../ui/app_updates.dart';
import '../ui/storage_settings.dart';
import '../ui/distribution_settings.dart';
import '../ui/theme.dart';
import '../ui/tile.dart';
import 'links.dart';
import 'page.dart';
import '../ui/app_image.dart';
import '../ui/themes.dart';

/// One choice in a settings group (`SettingsOption.astro`): a 56 dp face with
/// an icon, an image or a palette; the chosen one fills with primary and its
/// corners tighten.
class _Option {
  const _Option(
    this.value,
    this.label, {
    this.icon,
    this.image,
    this.swatch,
    this.portrait,
    this.ring,
    this.badge,
  });
  final String value;
  final String label;
  final IconData? icon;
  final String? image;
  final List<Color>? swatch;

  /// A round network picture: a band icon or a character's face.
  final String? portrait;
  final Color? ring;
  final IconData? badge;
}

/// The website's settings page (`SettingsDocument.astro`): appearance, theme
/// colour and density in one card; language with Japanese song titles and
/// difficulty estimates in the next; the release server in the last.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final themeOptions = [
      _Option(
        'light',
        t('settings.labels.themeLight', 'Light'),
        icon: Symbols.light_mode_rounded,
      ),
      _Option(
        'system',
        t('settings.labels.themeSystem', 'Follow system'),
        icon: Symbols.brightness_auto_rounded,
      ),
      _Option(
        'dark',
        t('settings.labels.themeDark', 'Dark'),
        icon: Symbols.dark_mode_rounded,
      ),
    ];
    return ShellPage(
      title: t('navigation.settings', 'Settings'),
      body: FutureBuilder(
        future: CatalogVisuals.of(state.api),
        builder: (context, snapshot) {
          final visuals = snapshot.data;
          final jp = state.apiFor('jp');
          final now = DateTime.now();
          final open = openSeasons(now);
          final born = birthdaysOn(state.themeCharacters, now);
          final seasonalOpen = open.isNotEmpty || born.isNotEmpty;
          String characterName(int id) =>
              t.text(visuals?.characters[id]?['characterName']);
          String face(ThemeCharacter character) =>
              jp.asset(character.face).toString();
          final themeRows = <List<_Option>>[
            [
              _Option(
                'haneoka',
                t('settings.labels.tuneDefault', 'Original key'),
                swatch: const [
                  Color(0xFF31356E),
                  Color(0xFFDFE0FF),
                  Color(0xFF79BBC8),
                ],
              ),
              for (final season in open)
                _Option(
                  season.seed,
                  t('settings.seasons.${season.key}', season.id),
                  icon: season.ornament,
                ),
              for (final character in born)
                _Option(
                  character.birthdaySeed,
                  characterName(character.id),
                  portrait: face(character),
                  ring: character.color,
                  badge: birthdayOrnament,
                ),
            ],
            for (final MapEntry(:key, :value) in bandSwatches.entries)
              [
                if (visuals?.bands[int.parse(key.split('-').last)]?['icon']
                    case final String icon)
                  _Option(
                    key,
                    t.text(
                      visuals?.bands[int.parse(
                        key.split('-').last,
                      )]?['bandName'],
                    ),
                    portrait: state.api.asset(icon).toString(),
                  )
                else
                  _Option(
                    key,
                    t.text(
                      visuals?.bands[int.parse(
                        key.split('-').last,
                      )]?['bandName'],
                    ),
                    swatch: dark ? value.$2 : value.$1,
                  ),
                for (final character in state.themeCharacters)
                  if ('band-${character.bandId}' == key)
                    _Option(
                      character.seed,
                      characterName(character.id),
                      portrait: face(character),
                      ring: character.color,
                    ),
              ],
          ];
          return ListView(
            padding: pagePadding(context),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 880),
                  child: Column(
                    children: [
                      _Card(
                        children: [
                          _Group(
                            icon: Symbols.palette_rounded,
                            title: t(
                              'settings.labels.appearance',
                              'Appearance',
                            ),
                            value: state.themeMode.name,
                            options: themeOptions,
                            onSelected: (v) =>
                                state.setThemeMode(ThemeMode.values.byName(v)),
                          ),
                          _ThemeGroup(
                            title: t(
                              'settings.labels.themeColor',
                              'Theme color',
                            ),
                            value: state.shownSeed,
                            rows: themeRows,
                            onSelected: state.setSeed,
                          ),
                          if (seasonalOpen)
                            _Switch(
                              icon: Symbols.auto_awesome_rounded,
                              label: t(
                                'settings.labels.seasonEffects',
                                'Seasonal effects',
                              ),
                              value: state.seasonEffects,
                              onChanged: (v) =>
                                  state.setFlag('seasonEffects', v),
                            ),
                          _Group(
                            icon: Symbols.density_medium_rounded,
                            title: t('common.layout.density', 'Spacing'),
                            value: state.compact ? 'compact' : 'comfortable',
                            options: [
                              _Option(
                                'comfortable',
                                t('common.layout.comfortable', 'Comfortable'),
                                icon: Symbols.density_medium_rounded,
                              ),
                              _Option(
                                'compact',
                                t('common.layout.compact', 'Compact'),
                                icon: Symbols.density_small_rounded,
                              ),
                            ],
                            onSelected: (v) =>
                                state.setFlag('compact', v == 'compact'),
                          ),
                        ],
                      ),
                      _Card(
                        children: [
                          _Group(
                            icon: Symbols.language_rounded,
                            title: t('settings.labels.language', 'Language'),
                            value: t.locale,
                            options: const [
                              _Option(
                                'ja',
                                '日本語',
                                image: 'assets/settings/flag-jp.svg',
                              ),
                              _Option(
                                'en',
                                'English',
                                image: 'assets/settings/flag-en.svg',
                              ),
                              _Option(
                                'zh-TW',
                                '繁體中文',
                                image: 'assets/settings/flag-hk.svg',
                              ),
                              _Option(
                                'zh-CN',
                                '简体中文',
                                image: 'assets/settings/flag-cn.svg',
                              ),
                              _Option(
                                'ko',
                                '한국어',
                                image: 'assets/settings/flag-kr.svg',
                              ),
                            ],
                            onSelected: state.setLocale,
                          ),
                          _Switch(
                            icon: Symbols.music_note_rounded,
                            label: t(
                              'settings.labels.forceJapaneseTitles',
                              'Show Japanese song titles',
                            ),
                            value: state.japaneseTitles,
                            onChanged: (v) =>
                                state.setFlag('japaneseTitles', v),
                          ),
                          _Switch(
                            icon: Symbols.bar_chart_rounded,
                            label: t(
                              'settings.labels.showDifficultyEstimates',
                              'Show estimated difficulty',
                            ),
                            beta: true,
                            value: state.difficultyEstimates,
                            onChanged: (v) =>
                                state.setFlag('difficultyEstimates', v),
                          ),
                          if (AppAnalytics.supported)
                            _Switch(
                              icon: Symbols.monitoring_rounded,
                              label: t(
                                'settings.labels.usageAnalytics',
                                'Share usage statistics',
                              ),
                              value: state.analytics,
                              onChanged: (v) => state.setFlag('analytics', v),
                            ),
                        ],
                      ),
                      _Card(
                        children: [
                          _Group(
                            icon: Symbols.dns_rounded,
                            title: t(
                              'settings.labels.releaseServer',
                              'Release server',
                            ),
                            value: state.server,
                            options: [
                              _Option(
                                'jp',
                                t('settings.labels.settingsJapan', 'Japan'),
                                image: 'assets/settings/bushimo.svg',
                              ),
                              _Option(
                                'intl',
                                t('settings.labels.settingsGlobal', 'Global'),
                                image: 'assets/settings/bilibili.svg',
                              ),
                            ],
                            onSelected: state.setServer,
                          ),
                        ],
                      ),
                      _Card(children: _dateGroups(context)),
                      const _Card(children: [StorageSettings()]),
                      const _Card(children: [AppUpdateSettings()]),
                      const _Card(children: [DistributionSettings()]),
                      const _About(),
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

/// `.settings-card`: surface-container-low, 28 dp corners, groups divided by rules.
class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Corner.extraLarge),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Column(
            children: [
              for (final (index, child) in children.indexed) ...[
                if (index > 0) Divider(height: 1, color: scheme.outlineVariant),
                child,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// `.settings-row`: icon, title and the current choice's name, then the options.
class _Group extends StatelessWidget {
  const _Group({
    required this.icon,
    required this.title,
    required this.value,
    required this.options,
    required this.onSelected,
  });
  final IconData icon;
  final String title;
  final String value;
  final List<_Option> options;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = options.where((o) => o.value == value).firstOrNull;
    final header = Row(
      children: [
        Icon(icon, color: scheme.onSurfaceVariant),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                current?.label ?? '',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    final Widget faces = options.length > 12
        ? DropdownMenu<String>(
            enableFilter: true,
            requestFocusOnTap: true,
            initialSelection: value,
            dropdownMenuEntries: [
              for (final option in options)
                DropdownMenuEntry(value: option.value, label: option.label),
            ],
            onSelected: (selected) {
              if (selected != null) onSelected(selected);
            },
          )
        : Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in options)
                _Face(
                  option: option,
                  selected: option.value == value,
                  onTap: () => onSelected(option.value),
                ),
            ],
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth >= 560
            ? Row(
                children: [
                  Expanded(child: header),
                  const SizedBox(width: 24),
                  faces,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [header, const SizedBox(height: 16), faces],
              ),
      ),
    );
  }
}

class _Face extends StatelessWidget {
  const _Face({
    required this.option,
    required this.selected,
    required this.onTap,
  });
  final _Option option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final swatch = option.swatch;
    final size = MediaQuery.sizeOf(context).width < 600 ? 48.0 : 56.0;
    final Widget content = swatch != null
        ? ClipOval(
            child: SizedBox.square(
              dimension: size * 0.64,
              child: Column(
                children: [
                  Expanded(
                    child: ColoredBox(
                      color: swatch[0],
                      child: const SizedBox.expand(),
                    ),
                  ),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: ColoredBox(
                            color: swatch[1],
                            child: const SizedBox.expand(),
                          ),
                        ),
                        Expanded(
                          child: ColoredBox(
                            color: swatch[2],
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          )
        : option.portrait != null
        ? Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: size * 0.72,
                height: size * 0.72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.surfaceContainerHighest,
                  border: option.ring == null
                      ? null
                      : Border.all(color: option.ring!, width: 2),
                ),
                child: ClipOval(
                  child: AppImage(
                    candidates: [option.portrait!],
                    fit: BoxFit.cover,
                    localized: false,
                  ),
                ),
              ),
              if (option.badge != null)
                Positioned(right: -6, bottom: -6, child: _Badge(option.badge!)),
            ],
          )
        : option.image != null
        ? SvgPicture.asset(option.image!, width: 28, height: 28)
        : Icon(
            option.icon,
            color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
          );
    return Tooltip(
      message: option.label,
      child: Semantics(
        selected: selected,
        button: true,
        label: option.label,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Easing.emphasizedDecelerate,
          width: size,
          height: size,
          decoration: ShapeDecoration(
            color: selected ? scheme.primary : scheme.surface,
            shape: RoundedRectangleBorder(
              side: BorderSide(
                color: selected ? scheme.primary : scheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(
                selected ? Corner.large : Corner.extraLarge,
              ),
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              customBorder: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(
                  selected ? Corner.large : Corner.extraLarge,
                ),
              ),
              onTap: onTap,
              child: Center(child: content),
            ),
          ),
        ),
      ),
    );
  }
}

/// A switch row under a group: icon, label (with the Beta mark), switch.
class _Switch extends StatelessWidget {
  const _Switch({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.beta = false,
  });
  final IconData icon;
  final String label;
  final bool value;
  final bool beta;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            Icon(icon, size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: 20),
            Expanded(
              child: Text.rich(
                TextSpan(
                  text: label,
                  children: [
                    if (beta)
                      TextSpan(
                        text: ' Beta',
                        style: theme.textTheme.labelSmall,
                      ),
                  ],
                ),
                style: theme.textTheme.bodyLarge,
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              thumbIcon: WidgetStateProperty.resolveWith(
                (states) => Icon(
                  states.contains(WidgetState.selected)
                      ? Symbols.check_rounded
                      : Symbols.close_rounded,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _About extends StatelessWidget {
  const _About();

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    return _Card(
      children: [
        FutureBuilder(
          future: PackageInfo.fromPlatform(),
          builder: (context, snapshot) {
            final version = snapshot.data;
            return Column(
              children: [
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  leading: Image.asset(
                    'assets/brand/android-chrome-512x512.png',
                    width: 40,
                  ),
                  title: Text(t('navigation.about', 'About')),
                  subtitle: Text(
                    version == null ? 'haneoka' : 'haneoka ${version.version}',
                  ),
                ),
                for (final (icon, key, route) in const [
                  (Symbols.policy_rounded, 'legal.privacy.title', '/privacy'),
                  (Symbols.gavel_rounded, 'legal.terms.title', '/terms'),
                ])
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(icon),
                    title: Text(t(key)),
                    trailing: const Icon(Symbols.chevron_right_rounded),
                    onTap: () => openLink(context, route),
                  ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Symbols.license_rounded),
                  title: Text(t('legal.license.title', 'Licences')),
                  trailing: const Icon(Symbols.chevron_right_rounded),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'haneoka',
                    applicationVersion: version?.version,
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

List<Widget> _dateGroups(BuildContext context) {
  final t = AppScope.of(context).text;
  final sample = DateTime.utc(2026, 3, 5, 21, 7, 9);
  final morning = DateTime.utc(2026, 3, 5, 9, 7, 9);
  String date(Map<String, String> overrides) => SiteDatePreferences.preview({
    'weekday': 'none',
    'zone': 'UTC',
    ...overrides,
  }, () => SiteDate.day(t.locale).format(sample));
  String time(Map<String, String> overrides, [DateTime? at]) {
    return SiteDatePreferences.preview({
      'zone': 'UTC',
      'seconds': 'off',
      'zoneName': 'none',
      ...overrides,
    }, () => SiteDate.day(t.locale).formatTime(at ?? sample));
  }

  String named(String key, String fallback) =>
      t('settings.labels.$key', fallback);
  final titles = <String, (String, String, IconData)>{
    'order': ('dateOrder', 'Date order', Symbols.swap_horiz_rounded),
    'month': ('dateMonth', 'Month', Symbols.calendar_month_rounded),
    'day': ('dateDay', 'Day', Symbols.event_rounded),
    'separator': ('dateSeparator', 'Separator', Symbols.more_horiz_rounded),
    'year': ('dateYear', 'Year', Symbols.calendar_month_rounded),
    'yearDigits': ('dateYearDigits', 'Year digits', Symbols.pin_rounded),
    'weekday': ('dateWeekday', 'Weekday', Symbols.event_rounded),
    'cycle': ('timeFormat', 'Time format', Symbols.schedule_rounded),
    'hour': ('timeHour', 'Hour', Symbols.schedule_rounded),
    'seconds': ('timeSeconds', 'Seconds', Symbols.schedule_rounded),
    'zoneName': ('timeZoneName', 'Time zone label', Symbols.public_rounded),
  };
  String option(String key, String value) => switch (key) {
    'order' =>
      value == 'auto'
          ? named('dateAuto', 'Auto')
          : date({'order': value, 'year': 'always'}),
    'month' => date({'month': value, 'year': 'never'}),
    'day' => date({'day': value, 'year': 'never'}),
    'separator' => date({
      'month': 'numeric',
      'separator': value,
      'year': 'always',
    }),
    'year' => switch (value) {
      'auto' => named('yearAuto', 'Other years'),
      'always' => named('yearAlways', 'Always'),
      _ => named('yearNever', 'Never'),
    },
    'yearDigits' => date({'yearDigits': value, 'year': 'always'}),
    'weekday' => date({'weekday': value, 'year': 'never'}),
    'cycle' => time({'cycle': value}),
    'hour' => time({'hour': value, 'cycle': 'h23'}, morning),
    'seconds' => time({'seconds': value}),
    _ => time({'zoneName': value, 'zone': 'Asia/Tokyo'}),
  };
  return [
    _Group(
      icon: Symbols.public_rounded,
      title: named('timeZone', 'Time zone'),
      value: SiteDatePreferences.value('zone'),
      options: [
        for (final zone in SiteDatePreferences.zones)
          _Option(
            zone,
            zone == 'local' ? named('zoneLocal', 'Device time zone') : zone,
          ),
      ],
      onSelected: (value) => SiteDatePreferences.set('zone', value),
    ),
    for (final MapEntry(:key, value: values) in dateChoices.entries)
      _Group(
        icon: titles[key]!.$3,
        title: named(titles[key]!.$1, titles[key]!.$2),
        value: SiteDatePreferences.value(key),
        options: [
          for (final value in values)
            if (key != 'day' || value != 'ordinal' || t.locale.startsWith('en'))
              _Option(value, option(key, value)),
        ],
        onSelected: (value) => SiteDatePreferences.set(key, value),
      ),
  ];
}

class _Badge extends StatelessWidget {
  const _Badge(this.icon);
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.tertiaryContainer,
      ),
      child: Icon(icon, size: 14, color: scheme.onTertiaryContainer),
    );
  }
}

/// The theme colour row (`.settings-options--seed`): the original theme and
/// any open seasonal or birthday themes, then each band's icon followed by
/// its members' portraits.
class _ThemeGroup extends StatelessWidget {
  const _ThemeGroup({
    required this.title,
    required this.value,
    required this.rows,
    required this.onSelected,
  });
  final String title;
  final String value;
  final List<List<_Option>> rows;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = rows.expand((row) => row).where((o) => o.value == value);
    final header = Row(
      children: [
        Icon(Symbols.format_paint_rounded, color: scheme.onSurfaceVariant),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                current.firstOrNull?.label ?? '',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    final faces = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                for (final option in row)
                  _Face(
                    option: option,
                    selected: option.value == value,
                    onTap: () => onSelected(option.value),
                  ),
              ],
            ),
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth >= 720
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: header),
                  const SizedBox(width: 24),
                  faces,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  header,
                  const SizedBox(height: 16),
                  Align(alignment: Alignment.centerLeft, child: faces),
                ],
              ),
      ),
    );
  }
}
