import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../catalog/songs.dart';
import '../catalog/visuals.dart';
import '../core/i18n.dart';
import '../core/api.dart';
import '../core/app_state.dart';
import '../core/net.dart';
import '../core/provider_api.dart';
import '../core/resource_file_cache.dart';
import '../shell/page.dart';
import 'audio.dart';
import 'chart_input.dart';
import 'controller.dart';
import 'project.dart';

class ChartLibrarySelection {
  const ChartLibrarySelection(
    this.api,
    this.song,
    this.chart,
    this.mode, {
    this.disposeApi = false,
  });
  final bool disposeApi;
  final HaneokaApi api;
  final ChartMap song, chart;
  final String mode;
}

Future<ChartLibrarySelection?> openChartLibrary(
  BuildContext context, {
  bool bestdori = false,
  Map<String, String>? linked,
  String? mediaKind,
}) => Navigator.of(context).push<ChartLibrarySelection>(
  MaterialPageRoute(
    builder: (_) => _ChartLibraryScreen(
      bestdori: bestdori,
      linked: linked,
      mediaKind: mediaKind,
    ),
  ),
);

class _ChartLibraryScreen extends StatefulWidget {
  const _ChartLibraryScreen({
    required this.bestdori,
    this.linked,
    this.mediaKind,
  });
  final String? mediaKind;
  final bool bestdori;
  final Map<String, String>? linked;
  @override
  State<_ChartLibraryScreen> createState() => _ChartLibraryScreenState();
}

class _ChartLibraryScreenState extends State<_ChartLibraryScreen> {
  HaneokaApi? _api;
  final _owned = <ProviderApi>[];
  String? _scope;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context),
        scope = '${state.text.locale}:${state.server}';
    if (_scope == scope) return;
    _scope = scope;
    if (widget.bestdori) {
      final api = ProviderApi(
        provider: 'bestdori',
        locale: state.text.locale,
        region: widget.linked?['region'],
      );
      _owned.add(api);
      _api = api;
    } else {
      _api = state.api;
    }
    if (widget.linked?['songId'] case final id?) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _open({'musicId': id}, difficulty: widget.linked?['difficulty']),
      );
    }
  }

  Future<void> _source() async {
    final state = AppScope.of(context), t = state.text;
    final selected = await showDialog<(String, String)>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(t('editors.chart.catalogSource')),
        children: [
          for (final server in ['jp', 'intl'])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, ('our-notes', server)),
              child: Text(t('tools.teamBuilder.boxImport.servers.$server')),
            ),
          for (final server in ['jp', 'en', 'tw', 'cn', 'kr'])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, ('bestdori', server)),
              child: Text(
                'GBP / ${t('tools.teamBuilder.boxImport.servers.$server', server.toUpperCase())}',
              ),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      if (selected.$1 == 'our-notes') {
        _api = state.apiFor(selected.$2);
      } else {
        final api = ProviderApi(
          provider: 'bestdori',
          locale: t.locale,
          region: selected.$2,
        );
        _owned.add(api);
        _api = api;
      }
    });
  }

  Future<void> _open(ChartMap item, {String? difficulty}) async {
    final api = _api!, state = AppScope.of(context), t = state.text;
    final song = chartMap(await api.catalog('songs', '${item['musicId']}'));
    if (!mounted) return;
    if (widget.mediaKind != null) {
      final owned = api is ProviderApi && _owned.remove(api);
      Navigator.of(context).pop(
        ChartLibrarySelection(
          api,
          song,
          const {},
          widget.mediaKind!,
          disposeApi: owned,
        ),
      );
      return;
    }
    final charts = (song['difficulty'] as List? ?? const [])
        .whereType<Map>()
        .where((row) => row['file'] is String)
        .map(chartMap)
        .toList();
    var chart =
        charts
            .where((row) => '${row['difficulty']}' == difficulty)
            .firstOrNull ??
        charts
            .where((r) => r['difficulty'] == 3 || r['difficulty'] == 'expert')
            .firstOrNull ??
        charts.firstOrNull;
    if (chart == null) return;
    final selection = await showDialog<ChartLibrarySelection>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(state.songTitle(song['musicTitle'])),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: '${chart!['difficulty']}',
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: t('editors.chart.difficulty'),
                  ),
                  items: [
                    for (final row in charts)
                      DropdownMenuItem(
                        value: '${row['difficulty']}',
                        child: Text(
                          '${row['difficulty'] is num ? const ['EASY', 'NORMAL', 'HARD', 'EXPERT', 'SPECIAL'][(row['difficulty'] as num).toInt().clamp(0, 4)] : '${row['difficulty']}'.toUpperCase()} / ${row['playLevel'] ?? ''}',
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(
                    () => chart = charts.firstWhere(
                      (row) => '${row['difficulty']}' == value,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t('common.actions.cancel')),
            ),
            for (final mode in ['chart', 'audio', 'both'])
              TextButton(
                onPressed: mode != 'chart' && song['musicUrl'] is! String
                    ? null
                    : () => Navigator.pop(
                        context,
                        ChartLibrarySelection(api, song, chart!, mode),
                      ),
                child: Text(
                  t(
                    'editors.chart.${mode == 'chart'
                        ? 'chartOnly'
                        : mode == 'audio'
                        ? 'audioOnly'
                        : 'chartAndAudio'}',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (selection != null && mounted) {
      final owned = api is ProviderApi && _owned.remove(api);
      Navigator.of(context).pop(
        ChartLibrarySelection(
          selection.api,
          selection.song,
          selection.chart,
          selection.mode,
          disposeApi: owned,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    return SongsScreen(
      key: ValueKey(_api),
      api: _api,
      title: t('editors.chart.serverLibrary'),
      extraActions: [
        BarAction(
          icon: Symbols.source_rounded,
          label: t('editors.chart.catalogSource'),
          onPressed: _source,
        ),
      ],
      onOpen: (context, song) => _open(song),
    );
  }

  @override
  void dispose() {
    for (final api in _owned) {
      api.dispose();
    }
    super.dispose();
  }
}

Future<void> importChartLibrarySelection(
  ChartEditorController controller,
  ChartLibrarySelection selection,
  SiteText labels,
) async {
  try {
    await controller.importResource(() async {
      final api = selection.api, song = selection.song, chart = selection.chart;
      final release = api is ProviderApi ? null : await api.release();
      final provider = api is ProviderApi ? 'bestdori' : 'our-notes',
          server = api is ProviderApi ? api.region : api.server;
      final sourceDifficulty = chart['difficulty'] is num
          ? const [
              'easy',
              'normal',
              'hard',
              'expert',
              'special',
            ][(chart['difficulty'] as num).toInt().clamp(0, 4)]
          : '${chart['difficulty']}';
      final uri = api is ProviderApi && api.provider == 'bestdori'
          ? api
                .asset(
                  '${api.base}/raw/api/charts/${song['musicId']}/$sourceDifficulty.json',
                )
                .replace(
                  queryParameters: {
                    'lang': labels.locale,
                    'projection': 'v29-chart-original-widths',
                  },
                )
          : api.asset('${chart['file']}');
      String? text;
      if (selection.mode != 'audio') {
        final response = await netClient
            .get(uri)
            .timeout(const Duration(seconds: 30));
        if (response.statusCode != 200) {
          throw const FormatException('loadFailed');
        }
        if (response.bodyBytes.length > 2 * 1024 * 1024) {
          throw const FormatException('chart_size');
        }
        text = utf8.decode(response.bodyBytes);
      }
      final imported = text == null ? null : importChartInput(text);
      final meta = imported?.project.meta;
      if (meta != null) {
        final visuals = await CatalogVisuals.of(api);
        meta['title'] = labels.text(song['musicTitle']);
        meta['artist'] = labels.text(
          song['bandName'] ??
              visuals.bands[(song['bandId'] as num?)?.toInt()]?['bandName'],
        );
        meta['difficulty'] = sourceDifficulty;
        meta['level'] = '${chart['displayLevel'] ?? chart['playLevel'] ?? ''}';
        if (imported!.format == 'bestdori') {
          chartMap(
            imported.project.extensions['bestdoriSource'],
          )['provenance'] = {
            'provider': 'bestdori',
            'game': 'garupa',
            'region': server,
            'songId': '${song['musicId']}',
            'difficulty': sourceDifficulty,
            'sourceUrl': uri.toString(),
            'chartSha256': sha256.convert(utf8.encode(text!)).toString(),
          };
        }
      }
      NativeChartAudio? audio;
      if (selection.mode != 'chart') {
        final lease = await resourceFileCache.acquire(
          api.asset('${song['musicUrl']}'),
          kind: ResourceFileKind.media,
        );
        try {
          audio = await decodeChartAudio(
            controller.store,
            lease.file,
            name: Uri.parse('${song['musicUrl']}').pathSegments.last,
          );
        } finally {
          await lease.release();
        }
      }
      if (imported != null && audio != null) {
        final ref = <String, Object?>{
          'kind': 'server',
          'provider': provider,
          'server': server,
          'songId': '${song['musicId']}',
          'releaseId': ?release,
        };
        imported.project.extensions['communityMedia'] = {
          'audio': {...ref, 'sha256': audio.ref.sha},
          'cover': ref,
          'audioSha': audio.ref.sha,
        };
      }
      return (
        chart: imported,
        audio: audio,
        source: text == null
            ? null
            : {
                'name': '${song['musicId']}-${chart['difficulty']}.json',
                'text': text,
              },
      );
    });
  } finally {
    if (selection.disposeApi) selection.api.dispose();
  }
}
