import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/app_state.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/tile.dart';

const progressionPages = {
  'player-ranks': 'playerRank',
  'friendship-ranks': 'friendshipRank',
  'band-rating': 'bandRating',
  'high-score-rating': 'highScoreRating',
};

class ProgressionScreen extends StatefulWidget {
  const ProgressionScreen({super.key, required this.kind, this.server});
  final String kind;
  final String? server;

  @override
  State<ProgressionScreen> createState() => _ProgressionScreenState();
}

class _ProgressionScreenState extends State<ProgressionScreen> {
  Object? _identity;
  Future<List<Object?>>? _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    final identity = (state.publicDataKey, widget.server, widget.kind);
    if (_identity == identity) return;
    _identity = identity;
    _load();
  }

  void _load() {
    final state = AppScope.of(context);
    final api = state.apiFor(widget.server ?? state.server);
    _data = Future.wait([
      api.catalog(
        widget.kind == 'high-score-rating' ? 'live-tools' : 'progression',
      ),
      if (widget.kind == 'high-score-rating')
        api.catalog(
          'sources/Assets/AddressableResources/UI/Atlas/FixUiSpriteAtlas.spriteatlasv2',
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    String label(String key) => t('catalog.progression.$key');
    final api = state.apiFor(widget.server ?? state.server);
    final number = NumberFormat.decimalPattern(t.locale);
    return ShellPage(
      title: label(progressionPages[widget.kind]!),
      body: FutureBuilder(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: FilledButton.tonal(
                onPressed: () => setState(_load),
                child: Text(t('common.actions.retry')),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snapshot.data!.first as Map;
          List<Map> rows(String key) => (data[key] as List).cast<Map>();
          Widget value(Object? v) => Text(number.format(v));
          late final List<String> headings;
          late final List<List<Widget>> cells;
          if (widget.kind.endsWith('-ranks')) {
            final ranks = rows(
              widget.kind == 'player-ranks' ? 'playerRanks' : 'friendshipRanks',
            );
            headings = ['level', 'requiredExp', 'cumulativeExp'];
            cells = [
              for (final (index, row) in ranks.indexed)
                [
                  value(row['rank']),
                  value(
                    (row['exp'] as num) -
                        (index == 0 ? 0 : ranks[index - 1]['exp'] as num),
                  ),
                  value(row['exp']),
                ],
            ];
          } else if (widget.kind == 'band-rating') {
            final totals = rows('bandRanks');
            final singles = {
              for (final row in rows('bandTypeRanks'))
                (row['raw'] as Map)['_rank']: (row['raw'] as Map)['_value'],
            };
            headings = ['level', 'totalBandRating', 'singleBandRating'];
            cells = [
              for (final row in totals)
                [
                  Builder(
                    builder: (context) {
                      final rank = (row['raw'] as Map)['_rank'] as int;
                      final name =
                          '${['D', 'C', 'B', 'A', 'S', 'SS'][(rank - 1) ~/ 4]}${(rank - 1) % 4 + 1}';
                      return Semantics(
                        label: name,
                        child: SizedBox(
                          width: 64,
                          height: 53,
                          child: AppImage(
                            localized: false,
                            candidates: [
                              api
                                  .asset(
                                    '/assets/${api.server}/Assets/AddressableResources/UI/Texture/BandRank/ImgScorerank_$name.png',
                                  )
                                  .toString(),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  value((row['raw'] as Map)['_value']),
                  value(singles[(row['raw'] as Map)['_rank']]),
                ],
            ];
          } else {
            final atlas = snapshot.data![1] as Map;
            final sprites = {
              for (final row in (atlas['outputs'] as List).cast<Map>())
                if (row['type'] == 'Sprite')
                  (row['path'] as String)
                      .split('/')
                      .last
                      .replaceFirst(RegExp(r'--Sprite-?-?\d+\.png$'), ''): api
                      .asset(
                        '/runtime/${api.server}/${(row['path'] as String).replaceFirst(RegExp(r'^runtime/'), '')}',
                      )
                      .toString(),
            };
            final totals = {
              for (final row in rows('totalHighScoreRatings'))
                '${(row['raw'] as Map)['_grade']}:${(row['raw'] as Map)['_step']}':
                    (row['raw'] as Map)['_rating'],
            };
            final bands =
                rows('bandHighScoreRatings')
                    .map((row) => row['raw'] as Map)
                    .where((raw) => raw['_bandId'] == 0)
                    .toList()
                  ..sort(
                    (a, b) =>
                        (a['_grade'] as int).compareTo(b['_grade'] as int) *
                            10 +
                        (a['_step'] as int).compareTo(b['_step'] as int),
                  );
            headings = ['grade', 'bandHighScoreRating', 'totalHighScoreRating'];
            Widget sprite(String name, double width, double height) => SizedBox(
              width: width,
              height: height,
              child: AppImage(localized: false, candidates: [sprites[name]!]),
            );
            cells = [
              for (final row in bands)
                [
                  Semantics(
                    label:
                        '${label(['bronze', 'silver', 'gold'][row['_grade'] as int])} ${['', 'I', 'II', 'III', 'IV', 'V'][row['_step'] as int]}',
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        sprite(
                          [
                            'GradeBronze',
                            'GradeSilver',
                            'GradeGold',
                          ][row['_grade'] as int],
                          40,
                          40,
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var i = 1; i <= 5; i++)
                              sprite(
                                i <= (row['_step'] as int)
                                    ? 'GradeStar_on'
                                    : 'GradeStar_off',
                                8,
                                9,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  value(row['_rating']),
                  value(totals['${row['_grade']}:${row['_step']}']),
                ],
            ];
          }
          return SingleChildScrollView(
            padding: pagePadding(context),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                clipBehavior: Clip.antiAlias,
                headingRowColor: WidgetStatePropertyAll(
                  Theme.of(context).colorScheme.surfaceContainerHigh,
                ),
                dataRowMinHeight: 56,
                dataRowMaxHeight: 56,
                columns: [
                  for (final key in headings)
                    DataColumn(label: Text(label(key)), numeric: true),
                ],
                rows: [
                  for (final row in cells)
                    DataRow(cells: [for (final cell in row) DataCell(cell)]),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
