import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../shell/page.dart';
import '../catalog/arena_detail.dart' show arenaTime;
import 'build_tab.dart';
import 'controller.dart';
import 'engine/num.dart';
import 'widgets.dart';

class ArenaTab extends StatelessWidget {
  const ArenaTab({super.key, required this.controller});
  final TeamBuilderController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller, arena = c.arena;
    final rule = arena.rule;
    final period = arena.regulation;
    final end = period == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(intOf(period['endAt']));
    final missions = intListOf(rule['missions']);
    return BuildTab(
      controller: c,
      leading: ToolSection(
        icon: Symbols.swords_rounded,
        title: c.tb('arena.tab', 'Gekiso Arena'),
        children: [
          DropdownButtonFormField<String>(
            initialValue: c.server,
            decoration: InputDecoration(
              labelText: c.tb('arena.server', 'Server'),
            ),
            items: [
              for (final server in ['jp', 'intl'])
                DropdownMenuItem(
                  value: server,
                  child: Text(c.tb('arena.$server', server)),
                ),
            ],
            onChanged: (server) {
              if (server != null) {
                if (c.serverOverride != null) {
                  ShellScope.of(context)?.navigate(
                    Uri(
                      path: '/team-builder',
                      queryParameters: {
                        'tab': 'arena',
                        'league': '${arena.leagueId}',
                        'server': server,
                      },
                    ).toString(),
                  );
                } else {
                  c.state.setServer(server);
                }
              }
            },
          ),
          DropdownButtonFormField<int>(
            initialValue: arena.leagueId,
            decoration: InputDecoration(
              labelText: c.tb('arena.league', 'League'),
            ),
            items: [
              for (final id in [1, 2, 3, 4, 5])
                DropdownMenuItem(
                  value: id,
                  child: Text(c.catalog!.bandName(id)),
                ),
            ],
            onChanged: (id) {
              if (id != null) {
                c.updateArena({
                  'leagueId': id,
                  'build': {
                    ...objectRow(c.arenaDraft['build']),
                    'songs': [],
                    'leader': null,
                    'bindings': [],
                  },
                });
              }
            },
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(
                label: Text(
                  arena.season == null
                      ? c.tb('arena.noSeason', 'No active season')
                      : c.tb('arena.season', 'Season {count}', {
                          'count': arena.season!['id'],
                        }),
                ),
              ),
              if (end != null)
                Chip(
                  label: Text(
                    c.tb('arena.until', 'Until {time}', {
                      'time': arenaTime(
                        end.millisecondsSinceEpoch,
                        c.state.text.locale,
                      ),
                    }),
                  ),
                ),
            ],
          ),
          Segmented<bool>(
            value: arena.automatic,
            options: [
              Choice(true, c.tb('arena.current', 'Current rules')),
              Choice(false, c.tb('arena.custom', 'Custom')),
            ],
            onSelected: (value) => c.updateArena({'automatic': value}),
          ),
          SongRulesEditor(
            controller: c,
            rules: (musicType: intOf(rule['musicType']), missions: missions),
            onChanged: (value) => c.updateArena({
              'automatic': false,
              'customized': true,
              'rule':
                  value ??
                  {
                    'musicType': 0,
                    'missions': [0, 0, 0],
                  },
            }),
          ),
          Segmented<String>(
            value: arena.shared ? 'shared' : 'individual',
            options: [
              Choice('shared', c.tb('arena.shared', 'One team for all songs')),
              Choice(
                'individual',
                c.tb('arena.individual', 'A team for each song'),
              ),
            ],
            onSelected: (value) => c.updateArena({'mode': value}),
          ),
          TextButton.icon(
            onPressed: () => c.updateSettings({
              'songs': [for (final song in arena.pool) song.toJson()],
            }),
            icon: const Icon(Symbols.library_music_rounded),
            label: Text(c.tb('arena.usePool', 'Select league song pool')),
          ),
        ],
      ),
    );
  }
}
