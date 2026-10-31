import 'dart:async';
import 'dart:io';

import 'package:cassiopeia_plugin_our_notes/render_profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../account/haneoka_account.dart';
import '../catalog/browse.dart';
import '../chart_editor/editor_screen.dart';
import '../chart_editor/project.dart';
import '../core/app_state.dart';
import '../core/audio_track.dart';
import '../core/media_lifecycle.dart';
import '../core/page_audio.dart';
import '../rendering/native_chart_document.dart';
import '../rendering/native_chart_player_screen.dart';
import '../shell/links.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/detail.dart';
import '../ui/tile.dart';
import 'community_widgets.dart';
import 'entity_comments.dart';
import 'reactions.dart';

const communityChartsApi = '/api/v1/community/charts';

class CommunityChartsScreen extends StatefulWidget {
  const CommunityChartsScreen({super.key, this.mine = false});
  final bool mine;
  @override
  State<CommunityChartsScreen> createState() => _CommunityChartsScreenState();
}

class _CommunityChartsScreenState extends State<CommunityChartsScreen> {
  final _account = HaneokaAccount.instance;
  List<ChartMap>? _items;
  Object? _error, _owner;
  int _generation = 0;
  late bool _mine = widget.mine;
  bool _loading = false;
  String t(String key) => AppScope.of(context).text('community.charts.$key');
  @override
  void initState() {
    super.initState();
    _account.addListener(_accountChanged);
    unawaited(_account.load().then((_) => _accountChanged()));
  }

  void _accountChanged() {
    final owner = _account.user?['id'];
    if (_owner != owner || _items == null && !_loading) {
      _owner = owner;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _loading = true;
    if (mounted) {
      setState(() {
        _items = null;
        _error = null;
      });
    }
    try {
      final result = await communityRequest(
        'GET',
        '$communityChartsApi${_mine ? '?scope=mine' : ''}',
      );
      if (mounted && generation == _generation) {
        setState(
          () => _items = [
            for (final row in result['charts'] as List) chartMap(row),
          ],
        );
      }
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error);
    } finally {
      if (generation == _generation) _loading = false;
    }
  }

  void _open(BuildContext context, ChartMap row) =>
      Navigator.of(context)
          .push<void>(
            MaterialPageRoute(
              settings: RouteSettings(name: '/community/charts/${row['id']}'),
              builder: (_) => CommunityChartScreen(id: '${row['id']}'),
            ),
          )
          .then((_) => _load());
  void _scope(bool mine) {
    if (_mine == mine) return;
    setState(() => _mine = mine);
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    _account.removeListener(_accountChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = AppScope.of(context).text;
    return BrowseScreen(
      title: t('title'),
      items: _items,
      error: _error,
      onRetry: _load,
      itemId: (row) => '${row['id']}',
      searchText: (row) => [
        'title',
        'artist',
        'charter',
        'ownerName',
        'id',
      ].map((key) => row[key] ?? '').join(' '),
      grid: const GridSpec(minWidth: 180),
      onOpen: _open,
      tile: (context, row) => Tile(
        title: '${row['title']}',
        subtitle: '${row['artist']}',
        images: [
          if ('${row['coverUrl']}'.isNotEmpty)
            absoluteUrl('${row['coverUrl']}'),
        ],
        marks: [
          TileMark.text(
            MarkAt.end,
            '${row['difficulty']} ${row['level']}'.toUpperCase(),
          ),
        ],
        onTap: () => _open(context, row),
      ),
      listRow: (context, row) => ListTile(
        leading: SizedBox.square(
          dimension: 56,
          child: AppImage(
            candidates: [absoluteUrl('${row['coverUrl']}')],
            fit: BoxFit.cover,
            localized: false,
          ),
        ),
        title: Text(
          '${row['title']}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${row['artist']} / ${row['difficulty']} ${row['level']}',
        ),
        onTap: () => _open(context, row),
      ),
      columns: [
        TableColumn(t('chart'), (row) => '${row['title']}'),
        TableColumn(t('artist'), (row) => '${row['artist']}'),
        TableColumn(t('charter'), (row) => '${row['charter']}'),
        TableColumn(t('difficulty'), (row) => '${row['difficulty']}'),
        TableColumn(t('authorLevel'), (row) => '${row['level']}'),
        TableColumn(t('likes'), (row) => '${row['likeCount']}', numeric: true),
      ],
      facets: [
        FacetSpec(
          key: 'difficulty',
          label: t('difficulty'),
          values: (row) => ['${row['difficulty']}'],
          option: (value) => FacetOption(value.toUpperCase()),
        ),
      ],
      sorts: [
        SortSpec(
          'newest',
          t('newest'),
          (row) => row['publishedAt'] ?? row['updatedAt'],
        ),
        SortSpec('popular', t('popular'), (row) => row['likeCount']),
        SortSpec('title', t('chart'), (row) => row['title']),
      ],
      defaultSort: 'newest',
      actions: (_) => [
        BarAction.choice(
          label: t('community'),
          options: [
            BarChoice(
              icon: Symbols.public_rounded,
              label: t('all'),
              selected: !_mine,
              onSelected: () => _scope(false),
            ),
            BarChoice(
              icon: Symbols.person_rounded,
              label: t('mine'),
              selected: _mine,
              onSelected: () => _scope(true),
            ),
          ],
        ),
        BarAction(
          icon: Symbols.add_rounded,
          label: t('create'),
          onPressed: () =>
              ShellScope.of(context)?.navigate('/chart-editor/create'),
        ),
        BarAction(
          icon: Symbols.refresh_rounded,
          label: text('common.actions.refresh'),
          onPressed: _load,
        ),
      ],
    );
  }
}

class CommunityChartScreen extends StatefulWidget {
  const CommunityChartScreen({
    super.key,
    required this.id,
    this.revision,
    this.playerOnly = false,
    this.draft = false,
  });
  final String id;
  final int? revision;
  final bool playerOnly, draft;
  @override
  State<CommunityChartScreen> createState() => _CommunityChartScreenState();
}

class _CommunityChartScreenState extends State<CommunityChartScreen> {
  final _audio = PageAudio(), _account = HaneokaAccount.instance;
  ChartMap? _chart;
  List<ChartMap> _versions = [];
  Object? _error, _owner;
  bool _busy = false, _routeCurrent = true, _closed = false;
  int _generation = 0;
  final _scores = <File>[];
  NativeChartDocument? _document;
  String t(String key) => AppScope.of(context).text('community.charts.$key');
  @override
  void initState() {
    super.initState();
    _audio.addListener(_changed);
    _account.addListener(_accountChanged);
    MediaLifecycle.register(this, _close);
    unawaited(_account.load().then((_) => _load()));
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _accountChanged() {
    final owner = _account.user?['id'];
    if (owner != _owner) {
      _owner = owner;
      unawaited(_audio.pause());
      unawaited(_load());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.of(context)?.isCurrent ?? true;
    if (_routeCurrent && !current) unawaited(_audio.pause());
    _routeCurrent = current;
  }

  Map<String, String> get _selection => {
    if (widget.revision != null) 'revision': '${widget.revision}',
    if (widget.draft) 'draft': '1',
  };
  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final uri = Uri(
        path: '$communityChartsApi/${widget.id}',
        queryParameters: _selection,
      );
      final response = await communityRequest('GET', uri.toString()),
          chart = chartMap(response['chart']);
      var versions = <ChartMap>[];
      if (chart['canEdit'] == true) {
        final data = await communityRequest(
          'GET',
          '$communityChartsApi/${widget.id}/revisions?draft=1',
        );
        versions = chartRows(data['revisions']);
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _chart = chart;
        _versions = versions;
        _error = null;
      });
      if (widget.playerOnly) await _player(replace: true);
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error);
    }
  }

  void _notice(Object error) {
    if (!mounted) return;
    final code = error is AccountError ? error.code : 'service_unavailable',
        message = t('errors.$code');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message.isEmpty ? t('errors.service_unavailable') : message,
        ),
      ),
    );
  }

  Future<void> _like() async {
    if (_busy || !await requireSession(context)) return;
    setState(() => _busy = true);
    try {
      final result = await communityRequest(
        'PUT',
        '$communityChartsApi/${widget.id}/like',
        body: {'liked': _chart!['liked'] != true},
      );
      if (mounted) {
        setState(() => _chart = {..._chart!, ...chartMap(result['chart'])});
      }
    } catch (error) {
      _notice(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _manage(bool delete) async {
    final text = AppScope.of(context).text;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t(delete ? 'delete' : 'unpublish')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(text('common.actions.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(text('common.actions.confirm')),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await communityRequest(
        delete ? 'DELETE' : 'POST',
        '$communityChartsApi/${widget.id}${delete ? '' : '/unpublish'}',
        body: {'version': _chart!['version']},
      );
      if (!mounted) return;
      if (delete) {
        Navigator.of(context).pop();
      } else {
        await _load();
      }
    } catch (error) {
      _notice(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _playAudio() async {
    final chart = _chart!;
    try {
      if (_audio.current?.id != widget.id) {
        await _audio.loadPaused(
          Track(
            id: widget.id,
            title: '${chart['title']}',
            url: absoluteUrl('${chart['audioUrl']}'),
          ),
        );
      }
      if (_audio.playing) {
        await _audio.pause();
      } else {
        await _audio.resume();
      }
    } catch (error) {
      _notice(error);
    }
  }

  Future<void> _player({bool replace = false}) async {
    if (_busy || _chart == null) return;
    final state = AppScope.of(context), chart = _chart!, api = state.api;
    setState(() => _busy = true);
    try {
      await _audio.pause();
      final selection = {..._selection, 'revision': '${chart['revision']}'};
      final result = await communityRequest(
        'GET',
        Uri(
          path: '$communityChartsApi/${widget.id}/playback',
          queryParameters: selection,
        ).toString(),
      );
      final root = await getTemporaryDirectory(),
          file = File(
            p.join(
              root.path,
              'community-chart-${widget.id}-${chart['revision']}.json',
            ),
          );
      await file.writeAsString(result['ss'] as String, flush: true);
      _scores.add(file);
      final release = await api.release(),
          doc = NativeChartDocument(
            source: RenderSource(
              server: api.server,
              release: release,
              document: 'community:${widget.id}:${chart['revision']}',
            ),
            sourceId: api.sourceId,
            scoreUri: file.uri,
            musicUri: Uri.parse(absoluteUrl('${chart['audioUrl']}')),
            resourceBase: Uri.parse(api.origin),
            jacketUri: Uri.parse(absoluteUrl('${chart['coverUrl']}')),
            bandId: 1,
            title: '${chart['title']}',
            difficulty: 3,
            canonicalSong: {
              'musicTitle': {'ja': chart['title']},
              'jacketUrl': absoluteUrl('${chart['coverUrl']}'),
              'musicType': 1,
              'bandId': 1,
            },
            audioOffsetMs: chartNumber(result['offsetMs']).toDouble(),
            timeScaleChanges: [
              for (final row in chartRows(
                result['timeScaleChanges'] ?? const [],
              ))
                (
                  timeMs: chartNumber(row['timeMs']).toDouble(),
                  scale: chartNumber(row['scale'], 1).toDouble(),
                ),
            ],
          );
      if (!mounted) return;
      final route = MaterialPageRoute<void>(
        builder: (_) => NativeChartPlayerScreen(document: doc, difficulty: 3),
      );
      if (replace) {
        setState(() => _document = doc);
      } else {
        await Navigator.of(context).push(route);
      }
    } catch (error) {
      _notice(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _editor({int? revision, bool remix = false}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChartEditorScreen(
          initialQuery: {
            'communityId': widget.id,
            if (revision != null) 'revision': '$revision',
            if (!remix) 'draft': '1',
            if (remix) 'remix': '1',
          },
        ),
      ),
    );
  }

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    _generation++;
    _audio.removeListener(_changed);
    await _audio.close();
    for (final score in _scores) {
      if (await score.exists()) await score.delete();
    }
    MediaLifecycle.unregister(this);
  }

  @override
  void dispose() {
    _account.removeListener(_accountChanged);
    unawaited(_close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.playerOnly && _document != null) {
      return NativeChartPlayerScreen(document: _document, difficulty: 3);
    }
    final text = AppScope.of(context).text, row = _chart;
    if (row == null) {
      return ShellPage(
        title: t('title'),
        body: Center(
          child: _error == null
              ? const CircularProgressIndicator()
              : FilledButton.tonal(
                  onPressed: _load,
                  child: Text(text('common.actions.retry')),
                ),
        ),
      );
    }
    final analysis = row['analysis'] is Map
            ? chartMap(row['analysis'])
            : const <String, Object?>{},
        estimate = analysis['difficultyEstimate'] is Map
            ? chartMap(analysis['difficultyEstimate'])
            : const <String, Object?>{};
    return ShellPage(
      title: '${row['title']}',
      showBack: true,
      status: _busy
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      actions: [
        BarAction(
          icon: Symbols.sports_esports_rounded,
          label: t('viewChart'),
          onPressed: _busy ? null : _player,
        ),
        BarAction(
          icon: _audio.playing
              ? Symbols.pause_rounded
              : Symbols.play_arrow_rounded,
          label: text(
            _audio.playing ? 'common.actions.pause' : 'common.actions.play',
          ),
          onPressed: _playAudio,
        ),
        BarAction(
          icon: row['liked'] == true
              ? Symbols.favorite_rounded
              : Symbols.favorite_border_rounded,
          label: '${t('likes')} ${row['likeCount']}',
          onPressed: _busy ? null : _like,
        ),
        BarAction(
          icon: Symbols.share_rounded,
          label: t('share'),
          onPressed: () => Clipboard.setData(
            ClipboardData(
              text:
                  'https://haneoka.org/${AppScope.of(context).server}/${text.locale}/charts/${widget.id}/',
            ),
          ),
        ),
        if (row['canEdit'] == true) ...[
          BarAction(
            icon: Symbols.edit_rounded,
            label: t('edit'),
            onPressed: _editor,
          ),
          BarAction(
            icon: Symbols.unpublished_rounded,
            label: t('unpublish'),
            onPressed: _busy || row['publishedRevision'] == null
                ? null
                : () => _manage(false),
          ),
          BarAction(
            icon: Symbols.delete_rounded,
            label: t('delete'),
            onPressed: _busy ? null : () => _manage(true),
          ),
        ] else if (row['remix'] == true)
          BarAction(
            icon: Symbols.edit_note_rounded,
            label: t('remixAction'),
            onPressed: () => _editor(remix: true),
          ),
      ],
      body: DetailLayout(
        media: ImageGallery(
          images: [absoluteUrl('${row['coverUrl']}')],
          aspectRatio: 1,
        ),
        sections: [
          DetailSection(
            icon: Symbols.music_note_rounded,
            title: t('chart'),
            child: SpecList(
              facts: [
                for (final key in ['artist', 'charter', 'difficulty'])
                  Fact(t(key), '${row[key]}'),
                Fact(t('authorLevel'), '${row['level']}'),
                Fact(
                  t('recommendedLevel'),
                  '${estimate['estimatedConstant'] ?? '—'}',
                ),
                Fact(t('version'), '${row['revision']}'),
                Fact(
                  text('catalog.analysis.fields.n'),
                  '${analysis['n'] ?? '—'}',
                ),
                Fact(text('common.fields.time'), '${analysis['time'] ?? '—'}'),
                Fact(
                  text('catalog.analysis.fields.nps'),
                  '${analysis['nps'] ?? '—'}',
                ),
                Fact(
                  text('catalog.analysis.fields.bpm'),
                  '${analysis['firstBpm'] ?? '—'}',
                ),
                Fact(
                  t('owner'),
                  '${row['ownerName']}',
                  widget: TextButton(
                    onPressed: () => openLink(
                      context,
                      '/community/users/${row['ownerUid']}',
                    ),
                    child: Text('${row['ownerName']}'),
                  ),
                ),
                Fact(
                  t('remix'),
                  t(row['remix'] == true ? 'remixAllowed' : 'remixClosed'),
                ),
                Fact(t('visibility'), t('${row['visibility']}')),
                if ('${row['summary']}'.isNotEmpty)
                  Fact(t('summary'), '${row['summary']}', full: true),
              ],
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _player,
                icon: const Icon(Symbols.sports_esports_rounded),
                label: Text(t('viewChart')),
              ),
              OutlinedButton.icon(
                onPressed: () => openLink(
                  context,
                  'https://open.sonolus.com/haneoka.org/sonolus/levels/haneoka-community-${widget.id}',
                ),
                icon: const Icon(Symbols.open_in_new_rounded),
                label: Text(t('playSonolus')),
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (_versions.isNotEmpty)
            DetailSection(
              icon: Symbols.history_rounded,
              title: t('versions'),
              folded: true,
              child: Column(
                children: [
                  for (final revision in _versions)
                    ListTile(
                      title: Text('${revision['revision']}'),
                      trailing: TextButton(
                        onPressed: () =>
                            _editor(revision: revision['revision'] as int),
                        child: Text(t('restore')),
                      ),
                    ),
                ],
              ),
            ),
          if (row['upstreamId'] != null)
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      CommunityChartScreen(id: '${row['upstreamId']}'),
                ),
              ),
              child: Text(t('original')),
            ),
          if (row['publishedRevision'] != null)
            EntityComments(
              type: 'community-charts',
              id: widget.id,
              server: AppScope.of(context).server,
            ),
        ],
      ),
    );
  }
}
