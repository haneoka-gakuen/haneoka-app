/// Building blocks the team builder's tabs share: tool sections, headings,
/// segmented choices, card art and song rows.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:material_new_shapes/material_new_shapes.dart';

import '../ui/app_image.dart';
import '../ui/card_artwork.dart';
import '../ui/shapes.dart';
import '../ui/theme.dart';
import 'catalog.dart';
import 'controller.dart';
import 'engine/api.dart';

class TeamToolLayout extends StatelessWidget {
  const TeamToolLayout({
    super.key,
    required this.controller,
    required this.summary,
    required this.conditions,
    required this.action,
    required this.results,
    this.storageKey = 'build',
  });
  final TeamBuilderController controller;
  final String storageKey;
  final String summary;
  final WidgetBuilder conditions, action, results;

  Future<void> _openConditions({
    required BuildContext context,
    required WidgetBuilder builder,
  }) async {
    BuildContext? dialog;
    bool busy() =>
        controller.running || controller.manualBusy || controller.pt.running;
    var wasBusy = busy(), closing = false;
    void changed() {
      final running = busy();
      if (!wasBusy && running && !closing && dialog?.mounted == true) {
        closing = true;
        Navigator.of(dialog!).pop();
      }
      wasBusy = running;
    }

    controller.addListener(changed);
    try {
      await showDialog<void>(
        context: context,
        builder: (context) {
          dialog = context;
          return builder(context);
        },
      );
    } finally {
      controller.removeListener(changed);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      Widget settings(BuildContext context) => Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              key: PageStorageKey('$storageKey:conditions'),
              padding: const EdgeInsets.all(16),
              child: conditions(context),
            ),
          ),
          Padding(padding: const EdgeInsets.all(16), child: action(context)),
        ],
      );
      if (box.maxWidth >= 960 && box.maxHeight >= 540) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 400, child: settings(context)),
            Expanded(
              child: ListView(
                key: PageStorageKey('$storageKey:results'),
                padding: const EdgeInsets.all(16),
                children: [results(context)],
              ),
            ),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: ToolSection(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: () => _openConditions(
                        context: context,
                        builder: (context) => Dialog(
                          insetPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 16,
                          ),
                          child: SizedBox(
                            width: 560,
                            height: MediaQuery.sizeOf(context).height * .88,
                            child: ListenableBuilder(
                              listenable: controller,
                              builder: (context, _) => Column(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      8,
                                      8,
                                      0,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            controller.tb(
                                              'adjustConditions',
                                              'Adjust conditions',
                                            ),
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium,
                                          ),
                                        ),
                                        CloseButton(),
                                      ],
                                    ),
                                  ),
                                  Expanded(child: settings(context)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      child: Text(
                        controller.tb('adjustConditions', 'Adjust conditions'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              key: PageStorageKey('$storageKey:results'),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [results(context)],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: action(context),
          ),
        ],
      );
    },
  );
}

/// A tool settings section (`.surface` with `detail-section-title`).
class ToolSection extends StatelessWidget {
  const ToolSection({
    super.key,
    this.icon,
    this.title,
    this.count,
    this.trailing,
    required this.children,
  });
  final IconData? icon;
  final String? title;
  final String? count;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(Corner.extraLarge),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: trailing == null
                    ? SectionHeading(icon: icon, title: title!, count: count)
                    : Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          SectionHeading(
                            icon: icon,
                            title: title!,
                            count: count,
                          ),
                          trailing!,
                        ],
                      ),
              ),
            ...[
              for (final (index, child) in children.indexed) ...[
                if (index > 0) const SizedBox(height: 12),
                child,
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class SectionHeading extends StatelessWidget {
  const SectionHeading({
    super.key,
    this.icon,
    required this.title,
    this.count,
    this.trailing,
  });
  final IconData? icon;
  final String title;
  final String? count;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: trailing == null ? MainAxisSize.min : MainAxisSize.max,
      children: [
        if (icon != null) ...[
          ShapedIcon(
            shape: MaterialShapes.cookie9Sided,
            size: 40,
            child: Icon(icon, size: 22),
          ),
          const SizedBox(width: 12),
        ],
        Flexible(child: Text(title, style: theme.textTheme.titleLarge)),
        if (count != null) ...[
          const SizedBox(width: 8),
          Text(
            count!,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (trailing != null) ...[const Spacer(), trailing!],
      ],
    );
  }
}

/// A labelled field: label above, control below (`.tb-field`).
class ToolField extends StatelessWidget {
  const ToolField({
    super.key,
    required this.label,
    this.value,
    required this.child,
  });
  final String label;
  final String? value;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (value != null) Text(value!, style: theme.textTheme.labelLarge),
          ],
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

class Choice<T> {
  const Choice(this.value, this.label, [this.icon]);
  final T value;
  final String label;
  final IconData? icon;
}

/// A single-choice segmented control that wraps rather than overflowing.
class Segmented<T> extends StatelessWidget {
  const Segmented({
    super.key,
    required this.value,
    required this.options,
    required this.onSelected,
    this.grow = true,
  });
  final T value;
  final List<Choice<T>> options;
  final ValueChanged<T> onSelected;
  final bool grow;

  @override
  Widget build(BuildContext context) {
    // Many options (difficulties, ranks) wrap as chips; few fill the width.
    if (options.length > 4 || !grow) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final option in options)
            ChoiceChip(
              avatar: option.icon == null ? null : Icon(option.icon, size: 18),
              showCheckmark: false,
              label: Text(option.label),
              selected: option.value == value,
              onSelected: (_) => onSelected(option.value),
            ),
        ],
      );
    }
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<T>(
        showSelectedIcon: false,
        segments: [
          for (final option in options)
            ButtonSegment(
              value: option.value,
              icon: option.icon == null ? null : Icon(option.icon, size: 18),
              label: Text(
                option.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        selected: {value},
        onSelectionChanged: (selected) => onSelected(selected.single),
      ),
    );
  }
}

/// A card's art at its frame ratio, with the catalogue's emblems.
class CardArt extends StatelessWidget {
  const CardArt({
    super.key,
    required this.catalog,
    required this.members,
    required this.id,
    this.emblems = true,
    this.growth,
    this.outline,
  });
  final TeamCatalog catalog;
  final bool members;
  final int id;
  final bool emblems;
  final CardGrowthDisplay? growth;
  final Color? outline;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: members ? 3 / 4 : 16 / 9,
      child: Container(
        foregroundDecoration: outline == null
            ? null
            : BoxDecoration(
                borderRadius: BorderRadius.circular(Corner.small),
                border: Border.all(color: outline!, width: 2),
              ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Corner.small),
          child: ColoredBox(
            color: scheme.surfaceContainerHighest,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CardArtwork(
                  kind: members ? GameCardKind.member : GameCardKind.support,
                  image: catalog.cardImage(members, id),
                  attribute: emblems
                      ? catalog.attributeIcon(catalog.attribute(members, id))
                      : null,
                  attributeLabel: catalog.attributeName(
                    catalog.attribute(members, id),
                  ),
                  rarity: emblems
                      ? catalog.rarityIcon(catalog.rarity(members, id))
                      : null,
                  growth: growth,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A chosen song: jacket, title and difficulty.
class SongRow extends StatelessWidget {
  const SongRow({
    super.key,
    required this.catalog,
    required this.song,
    this.trailing,
    this.onTap,
  });
  final TeamCatalog catalog;
  final SongRef song;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    onTap: onTap,
    leading: ClipRRect(
      borderRadius: BorderRadius.circular(Corner.small),
      child: SizedBox.square(
        dimension: 48,
        child: AppImage(
          candidates: [catalog.songJacket(song.songId)],
          fit: BoxFit.cover,
        ),
      ),
    ),
    title: Text(
      catalog.songTitle(song.songId),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    subtitle: Text(catalog.difficultyLabel(song.songId, song.difficulty)),
    trailing: trailing,
  );
}

/// A labelled value chip (`.tb-chip`).
class ValueChip extends StatelessWidget {
  const ValueChip({
    super.key,
    required this.label,
    required this.value,
    this.icon,
  });
  final String label;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Corner.small),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              value,
              style: theme.textTheme.labelLarge?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String formatNumber(String locale, num value, [int digits = 0]) =>
    (NumberFormat.decimalPattern(locale)
          ..minimumFractionDigits = digits
          ..maximumFractionDigits = digits)
        .format(value);

/// Pill tabs in a tonal bar (`.tabs--pills`), scrolling sideways when narrow.
class PillTabs<T> extends StatelessWidget {
  const PillTabs({
    super.key,
    required this.value,
    required this.tabs,
    required this.onSelected,
  });
  final T value;
  final List<(T, IconData, String, int?)> tabs;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Corner.large),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            for (final (tab, icon, label, count) in tabs)
              Material(
                color: tab == value
                    ? scheme.secondaryContainer
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(40),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => onSelected(tab),
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    alignment: Alignment.center,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          icon,
                          size: 18,
                          color: tab == value
                              ? scheme.onSecondaryContainer
                              : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          label,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: tab == value
                                ? scheme.onSecondaryContainer
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                        if (count != null) ...[
                          const SizedBox(width: 6),
                          Text(
                            '$count',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// LUCK sampling: automatic, or a typed sample count.
class LuckSamplingField extends StatelessWidget {
  const LuckSamplingField({
    super.key,
    required this.label,
    required this.autoLabel,
    required this.customLabel,
    required this.samplesLabel,
    required this.manual,
    required this.samples,
    required this.onMode,
    required this.onSamples,
  });
  final String label;
  final String autoLabel;
  final String customLabel;
  final String samplesLabel;
  final bool manual;
  final int samples;
  final ValueChanged<bool> onMode;
  final ValueChanged<int> onSamples;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 8,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelLarge),
      Segmented<bool>(
        value: manual,
        options: [Choice(false, autoLabel), Choice(true, customLabel)],
        onSelected: onMode,
      ),
      if (manual)
        TextFormField(
          key: ValueKey('luck-samples-$label'),
          initialValue: '$samples',
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: samplesLabel),
          onChanged: (value) => onSamples(int.tryParse(value) ?? samples),
        ),
    ],
  );
}
