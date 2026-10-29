import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../catalog/song_summary.dart';
import '../ui/detail.dart';
import 'controller.dart';
import 'engine/num.dart';
import 'pickers.dart';
import 'song_comparison.dart';
import 'widgets.dart';
import 'build_tab.dart' show SongRulesEditor;

class SongComparisonTab extends StatelessWidget {
  const SongComparisonTab({super.key, required this.controller});
  final TeamBuilderController controller;
  SongComparison get c => controller.comparison;

  Future<void> _pick(BuildContext context, int slot, bool members) async {
    final view = controller.view!, manual = controller.manual;
    final id = await pickCard(
      context,
      controller.catalog!,
      members: members,
      ids: [...(members ? view.members.keys : view.snaps.keys)],
      current: (members ? manual.members : manual.snaps)[slot],
    );
    if (id == null) return;
    final list = [...(members ? manual.members : manual.snaps)];
    for (var i = 0; i < list.length; i++) {
      if (list[i] == id) list[i] = null;
    }
    list[slot] = id < 0 ? null : id;
    controller.manual = members
        ? manual.copyWith(members: list)
        : manual.copyWith(snaps: list);
    controller.manualResults = null;
    controller.changed();
  }

  Widget _formation(BuildContext context) {
    final host = controller, catalog = host.catalog!, manual = host.manual;
    return ToolSection(
      title: host.tb('manualTeam', 'Build a team by hand'),
      children: [
        if (host.view!.teams.isNotEmpty)
          DropdownButtonFormField<String>(
            isExpanded: true,
            decoration: InputDecoration(labelText: c.text('chooseTeam')),
            items: [
              for (final team in host.view!.teams)
                DropdownMenuItem(
                  value: team.id,
                  child: Text(team.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (id) {
              final team = host.view!.teams.firstWhere((row) => row.id == id);
              final leader = team.members.indexOf(
                team.leader ?? team.members.first,
              );
              host.manual = ManualTeam(
                members: team.members,
                snaps: team.snaps,
                leader: leader < 0 ? 0 : leader,
              );
              host.manualResults = null;
              host.changed();
            },
          ),
        for (final members in [true, false])
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < 5; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Column(
                      children: [
                        Tooltip(
                          message: c.text('slot', {'slot': i + 1}),
                          child: InkWell(
                            onTap: () => _pick(context, i, members),
                            child: switch ((members
                                ? manual.members
                                : manual.snaps)[i]) {
                              final int id => CardArt(
                                catalog: catalog,
                                members: members,
                                id: id,
                              ),
                              _ => AspectRatio(
                                aspectRatio: members ? 3 / 4 : 16 / 9,
                                child: const Center(
                                  child: Icon(Symbols.add_rounded),
                                ),
                              ),
                            },
                          ),
                        ),
                        if (members)
                          SizedBox(
                            height: 48,
                            child: IconButton(
                              tooltip: host.tb('leader', 'Leader'),
                              isSelected: manual.leader == i,
                              onPressed: () {
                                host.manual = manual.copyWith(leader: i);
                                host.changed();
                              },
                              icon: const Icon(Symbols.star_outline_rounded),
                              selectedIcon: const Icon(Symbols.star_rounded),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget _conditions(BuildContext context) {
    final s = c.settings, catalog = controller.catalog!;
    Widget number(String key, {int? max}) => TextFormField(
      key: ValueKey('sc-$key'),
      initialValue: s[key]?.toString() ?? '',
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: c.text(key == 'missEvery' ? 'miss' : key),
      ),
      onChanged: (value) => c.update({
        key: key == 'missEvery' ? int.tryParse(value) : double.tryParse(value),
      }),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _formation(context),
        const SizedBox(height: 16),
        ToolSection(
          title: c.text('conditions'),
          children: [
            FilledButton.tonalIcon(
              icon: const Icon(Symbols.library_music_rounded),
              label: Text(c.text('choose')),
              onPressed: () async {
                final songs = await pickSongs(
                  context,
                  catalog,
                  c.songs,
                  selectionContext: 'song-comparison',
                  songRules: c.songRules,
                  allowed: catalog.master.songs.keys
                      .where((id) => c.available('songs', id))
                      .toList(),
                );
                if (songs != null) {
                  c.update({
                    'songs': songs.map((row) => row.toJson()).toList(),
                  });
                }
              },
            ),
            ExpansionTile(
              title: Text(controller.tb('songRules', 'Song rules')),
              children: [
                SongRulesEditor(
                  controller: controller,
                  rules: c.ruleValues,
                  onChanged: (value) => c.update({'songRules': value}),
                ),
              ],
            ),
            for (final song in c.songs)
              SongRow(
                catalog: catalog,
                song: song,
                trailing: IconButton(
                  tooltip: c.text('remove'),
                  icon: const Icon(Symbols.close_rounded),
                  onPressed: () => c.update({
                    'songs': c.songs
                        .where((row) => row != song)
                        .map((row) => row.toJson())
                        .toList(),
                  }),
                ),
              ),
            Segmented<String>(
              value: '${s['target']}',
              options: const [Choice('S', 'S'), Choice('SS', 'SS')],
              onSelected: (value) => c.update({'target': value}),
            ),
            ToolField(
              label: c.text('players'),
              child: Segmented<int>(
                value: intOf(s['players']),
                options: [for (var n = 2; n <= 5; n++) Choice(n, '$n')],
                onSelected: (value) => c.update({'players': value}),
              ),
            ),
            DropdownButtonFormField<String>(
              initialValue: s['mode'] as String?,
              decoration: InputDecoration(labelText: c.text('mode')),
              items: [
                for (final mode in ['ap', 'custom'])
                  DropdownMenuItem(value: mode, child: Text(c.text(mode))),
              ],
              onChanged: (value) => c.update({'mode': value}),
            ),
            if (c.hasMission(3)) number('just'),
            if (s['mode'] == 'custom') ...[
              number('great'),
              number('missEvery'),
            ],
            DropdownButtonFormField<int>(
              key: ValueKey((s['rank'], s['players'])),
              initialValue: s['rank'] as int?,
              decoration: InputDecoration(labelText: c.text('rank')),
              items: [
                for (var n = 1; n <= intOf(s['players']); n++)
                  DropdownMenuItem(value: n, child: Text('$n')),
              ],
              onChanged: (value) => c.update({'rank': value}),
            ),
          ],
        ),
      ],
    );
  }

  Widget _action(BuildContext context) => SizedBox(
    width: double.infinity,
    child: FilledButton.icon(
      onPressed: c.running
          ? () {
              c.stop();
              controller.changed();
            }
          : controller.running || c.issues.isNotEmpty
          ? null
          : c.run,
      icon: Icon(c.running ? Symbols.stop_rounded : Symbols.monitoring_rounded),
      label: Text(
        c.running
            ? c.text('stop')
            : c.issues.isNotEmpty
            ? c.text(c.issues.first)
            : c.text('start'),
      ),
    ),
  );

  Widget _results(BuildContext context) {
    final catalog = controller.catalog!, locale = controller.state.text.locale;
    final rows = [...c.resultRows];
    final sort = '${c.settings['sort']}';
    double key(SongComparisonRow row) => switch (sort) {
      'score' => row.hit?.score?.mean ?? -1,
      'remaining' => -(c.metrics(row)?.remaining ?? double.infinity),
      _ => c.metrics(row)?.contribution ?? -1,
    };
    rows.sort((a, b) => key(b).compareTo(key(a)));
    final ids = rows.map((row) => row.song.songId).toSet();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ToolSection(
          title: c.text('title'),
          count: c.text('coverage', {
            'done': rows.where((row) => row.hit != null).length,
            'total': rows.length,
          }),
          children: [
            if (c.stale) Text(controller.tb('stale', 'Conditions changed')),
            Segmented<String>(
              value: sort,
              grow: false,
              options: [
                for (final key in ['contribution', 'score', 'remaining'])
                  Choice(key, c.text(key)),
              ],
              onSelected: (value) => c.update({'sort': value}),
            ),
            if (rows.isEmpty) Text(c.text('empty')),
            for (final id in ids)
              DetailFold(
                title: catalog.songTitle(id),
                open: true,
                meta: '${rows.where((row) => row.song.songId == id).length}',
                child: Column(
                  children: [
                    for (final row in rows.where(
                      (row) => row.song.songId == id,
                    )) ...[
                      SongRow(
                        catalog: catalog,
                        song: row.song,
                        trailing: Text(c.text(row.status)),
                      ),
                      if (row.hit?.score != null)
                        DataGrid(
                          cells: [
                            (
                              c.text('score'),
                              formatNumber(locale, row.hit!.score!.mean),
                            ),
                            (
                              c.text('contribution'),
                              c.metrics(row) == null
                                  ? '—'
                                  : '${formatNumber(locale, c.metrics(row)!.contribution, 1)}%',
                            ),
                            (
                              c.text('remaining'),
                              c.metrics(row) == null
                                  ? '—'
                                  : formatNumber(
                                      locale,
                                      c.metrics(row)!.remaining,
                                    ),
                            ),
                            (
                              c.text('total'),
                              c.metrics(row) == null
                                  ? '—'
                                  : formatNumber(locale, c.metrics(row)!.total),
                            ),
                          ],
                        ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    c.sync();
    return TeamToolLayout(
      controller: controller,
      storageKey: 'song-comparison',
      summary: '${c.text('choose')} · ${c.songs.length}',
      conditions: _conditions,
      action: _action,
      results: _results,
    );
  }
}
