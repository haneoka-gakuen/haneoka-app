import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'controller.dart';
import 'engine/num.dart';
import 'manual_event.dart';
import 'pickers.dart';
import 'widgets.dart';

class ManualEventControls extends StatelessWidget {
  const ManualEventControls({super.key, required this.controller});
  final TeamBuilderController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller,
        s = c.settings,
        catalog = c.catalog!,
        master = c.catalog!.master;
    final draft = s.manualEvent;
    String t(String key) => c.tb('manualEvent.$key', key);
    void set(Doc patch) => c.updateSettings({
      'manualEvent': {...draft, ...patch},
    });
    final options = catalog
        .events()
        .where(
          (row) =>
              catalog.available('events', row.id) &&
              objectRow(
                    objectRow(catalog.data['crossServer'])['owners'],
                  )['events']
                  is Map &&
              objectRow(
                    objectRow(
                      objectRow(catalog.data['crossServer'])['owners'],
                    )['events'],
                  )['${row.id}'] ==
                  c.server &&
              ManualEventTemplate.read(row.event, master) != null,
        )
        .toList();
    final event = master.events[intOf(draft['templateId'])];
    final template = event == null
        ? null
        : ManualEventTemplate.read(event, master);
    final attributes = intListOf(draft['attributes']),
        targets = intListOf(draft['targets']);
    final kind = '${draft['targetKind']}';
    Widget pickups(String key, List<BonusTier> profiles) {
      final selections = dataRows(draft[key]);
      final members = key == 'members';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextButton.icon(
            onPressed: profiles.isEmpty
                ? null
                : () async {
                    final id = await pickCard(
                      context,
                      catalog,
                      members: members,
                      ids: [
                        for (final id
                            in members
                                ? master.members.keys
                                : master.snaps.keys)
                          if (!selections.any((row) => row['cardId'] == id)) id,
                      ],
                    );
                    if (id != null && id > 0) {
                      set({
                        key: [
                          ...selections,
                          {'cardId': id, 'tier': profiles.first.key},
                        ],
                      });
                    }
                  },
            icon: const Icon(Symbols.add_rounded),
            label: Text(t(key)),
          ),
          for (final row in selections) ...[
            Row(
              children: [
                Expanded(
                  child: Text(catalog.cardName(members, intOf(row['cardId']))),
                ),
                IconButton(
                  tooltip: c.state.text('common.actions.remove', 'Remove'),
                  onPressed: () => set({
                    key: selections
                        .where((value) => value['cardId'] != row['cardId'])
                        .toList(),
                  }),
                  icon: const Icon(Symbols.close_rounded),
                ),
              ],
            ),
            DropdownButtonFormField<String>(
              key: ValueKey((key, row['cardId'], row['tier'])),
              initialValue:
                  profiles.any((profile) => profile.key == row['tier'])
                  ? '${row['tier']}'
                  : null,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: c.tb('eventBonus', 'Event bonus'),
              ),
              items: [
                for (final profile in profiles)
                  DropdownMenuItem(
                    value: profile.key,
                    child: Text(profile.label),
                  ),
              ],
              onChanged: (value) => set({
                key: [
                  for (final selection in selections)
                    selection['cardId'] == row['cardId']
                        ? {...selection, 'tier': value}
                        : selection,
                ],
              }),
            ),
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Segmented<bool>(
          value: s.manualEventEnabled,
          options: [Choice(false, t('choose')), Choice(true, t('manual'))],
          onSelected: (enabled) => c.updateSettings({
            'manualEventEnabled': enabled,
            if (enabled && draft['templateId'] == null)
              'manualEvent': {...draft, 'templateId': options.firstOrNull?.id},
          }),
        ),
        if (s.manualEventEnabled) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            key: ValueKey(draft['templateId']),
            initialValue: options.any((row) => row.id == draft['templateId'])
                ? intOf(draft['templateId'])
                : null,
            isExpanded: true,
            decoration: InputDecoration(labelText: t('rules')),
            items: [
              for (final option in options)
                DropdownMenuItem(
                  value: option.id,
                  child: Text(option.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (id) =>
                set({'templateId': id, 'members': [], 'snaps': []}),
          ),
          ToolField(
            label: t('attribute'),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilterChip(
                  label: Text(t('none')),
                  selected: draft['attributes'] is List && attributes.isEmpty,
                  onSelected: (_) => set({'attributes': []}),
                ),
                for (final id in [1, 2, 3, 4, 5])
                  FilterChip(
                    label: Text(catalog.attributeName(id)),
                    selected: attributes.contains(id),
                    onSelected: (_) => set({
                      'attributes': attributes.contains(id)
                          ? attributes.where((value) => value != id).toList()
                          : [...attributes, id],
                    }),
                  ),
              ],
            ),
          ),
          Segmented<String>(
            value: kind,
            options: [
              for (final value in ['band', 'character', 'none'])
                Choice(value, t(value)),
            ],
            onSelected: (value) => set({'targetKind': value, 'targets': []}),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (kind != 'none')
                for (final id
                    in kind == 'band'
                        ? master.members.values
                              .map((card) => card.bandId)
                              .toSet()
                        : master.characters.keys)
                  FilterChip(
                    label: Text(
                      kind == 'band'
                          ? catalog.bandName(id)
                          : catalog.characterName(id),
                    ),
                    selected: targets.contains(id),
                    onSelected: (_) => set({
                      'targets': targets.contains(id)
                          ? targets.where((value) => value != id).toList()
                          : [...targets, id],
                    }),
                  ),
            ],
          ),
          ExpansionTile(
            title: Text(t('pickups')),
            children: [
              pickups('members', template?.members ?? []),
              pickups('snaps', template?.snaps ?? []),
            ],
          ),
        ],
      ],
    );
  }
}
