import 'dart:math';

import 'package:flutter/material.dart';

import '../ui/theme.dart';

class GachaHistoryChart extends StatelessWidget {
  const GachaHistoryChart({
    super.key,
    required this.title,
    this.caption,
    this.details = const [],
    required this.labels,
    required this.rows,
    this.grouped = false,
  });
  final String title;
  final String? caption;
  final List<String> details;
  final bool grouped;
  final List<String> labels;
  final List<(String, List<num>)> rows;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), scheme = Theme.of(context).colorScheme;
    final colors = [
      scheme.primary,
      scheme.tertiary,
      scheme.outline,
      scheme.secondary,
    ];
    final displayRows = grouped
        ? [
            for (final row in rows)
              for (var i = 0; i < labels.length; i++)
                (
                  '${row.$1} / ${labels[i]}',
                  [
                    for (var j = 0; j < labels.length; j++)
                      i == j ? row.$2[i] : 0,
                  ],
                ),
          ]
        : rows;
    final maximum = displayRows.fold<num>(
      1,
      (value, row) => max(value, row.$2.fold<num>(0, (sum, n) => sum + n)),
    );
    return Card.filled(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            if (caption != null)
              Text(caption!, style: theme.textTheme.bodySmall),
            const SizedBox(height: 16),
            SizedBox(
              height: displayRows.length > 6 ? 360 : null,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (rowIndex, row) in displayRows.indexed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              row.$1,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge,
                            ),
                            const SizedBox(height: 4),
                            Tooltip(
                              message: [
                                for (var i = 0; i < labels.length; i++)
                                  '${labels[i]} ${row.$2[i]}',
                                if (rowIndex < details.length)
                                  details[rowIndex],
                              ].join(' / '),
                              child: LayoutBuilder(
                                builder: (context, box) => Row(
                                  children: [
                                    SizedBox(
                                      width:
                                          (box.maxWidth - 40) *
                                          row.$2.fold<num>(
                                            0,
                                            (sum, n) => sum + n,
                                          ) /
                                          maximum,
                                      height: 28,
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(
                                          Corner.small,
                                        ),
                                        child: Row(
                                          children: [
                                            for (
                                              var i = 0;
                                              i < row.$2.length;
                                              i++
                                            )
                                              if (row.$2[i] > 0)
                                                Expanded(
                                                  flex: (row.$2[i] * 1000)
                                                      .round(),
                                                  child: ColoredBox(
                                                    color:
                                                        colors[i %
                                                            colors.length],
                                                    child: Center(
                                                      child: Text(
                                                        '${row.$2[i]}',
                                                        maxLines: 1,
                                                        overflow:
                                                            TextOverflow.clip,
                                                        style: theme
                                                            .textTheme
                                                            .labelSmall
                                                            ?.copyWith(
                                                              color: i == 1
                                                                  ? scheme
                                                                        .onTertiary
                                                                  : i == 2
                                                                  ? scheme
                                                                        .surface
                                                                  : scheme
                                                                        .onPrimary,
                                                            ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      '${row.$2.fold<num>(0, (sum, n) => sum + n)}',
                                      style: theme.textTheme.labelLarge,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                for (var i = 0; i < labels.length; i++)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox.square(
                        dimension: 10,
                        child: ColoredBox(color: colors[i % colors.length]),
                      ),
                      const SizedBox(width: 6),
                      Text(labels[i], style: theme.textTheme.labelMedium),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
