/// One way to bring cards in, as every import surface lists it on the
/// website (`src/lit/shared/import-source-row.ts`), and the group heading
/// that says what a set of sources reads.
library;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class ImportSourceTile extends StatelessWidget {
  const ImportSourceTile({
    super.key,
    required this.icon,
    required this.title,
    required this.hint,
    this.onTap,
    this.expanded,
  });
  final IconData icon;
  final String title, hint;
  final VoidCallback? onTap;

  /// Set for a row that opens in place; true while open.
  final bool? expanded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      enabled: onTap != null,
      onTap: onTap,
      minVerticalPadding: 12,
      leading: CircleAvatar(
        backgroundColor: scheme.secondaryContainer,
        foregroundColor: scheme.onSecondaryContainer,
        child: Icon(icon, size: 20),
      ),
      title: Text(title),
      subtitle: Text(hint),
      trailing: Icon(switch (expanded) {
        null => Symbols.chevron_right_rounded,
        true => Symbols.expand_less_rounded,
        false => Symbols.expand_more_rounded,
      }),
    );
  }
}

/// `.import-sources__group`: a heading and what the sources under it read.
class ImportSourceGroup extends StatelessWidget {
  const ImportSourceGroup({
    super.key,
    required this.title,
    required this.tag,
    required this.children,
  });
  final String title, tag;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
              Text(
                tag,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        ...children,
      ],
    );
  }
}
