import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';

class CatalogSortControl extends StatelessWidget {
  const CatalogSortControl({
    super.key,
    required this.options,
    required this.value,
    required this.descending,
    required this.onSort,
    required this.onOrder,
  });
  final List<(String, String)> options;
  final String? value;
  final bool descending;
  final ValueChanged<String> onSort;
  final VoidCallback onOrder;
  @override
  Widget build(BuildContext context) {
    final text = AppScope.of(context).text;
    return Row(
      children: [
        Expanded(
          child: DropdownMenu<String>(
            key: ValueKey(value),
            expandedInsets: EdgeInsets.zero,
            initialSelection: value,
            onSelected: (value) {
              if (value != null) onSort(value);
            },
            dropdownMenuEntries: [
              for (final (key, label) in options)
                DropdownMenuEntry(value: key, label: label),
            ],
          ),
        ),
        const SizedBox(width: 8),
        IconButton.outlined(
          tooltip: text(
            descending ? 'common.layout.descending' : 'common.layout.ascending',
          ),
          onPressed: onOrder,
          icon: Icon(
            descending
                ? Symbols.arrow_downward_rounded
                : Symbols.arrow_upward_rounded,
          ),
        ),
      ],
    );
  }
}
