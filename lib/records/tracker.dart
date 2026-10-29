import '../core/catalog_source.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../catalog/catalog_screen.dart';
import '../catalog/profiles.dart';
import '../catalog/visuals.dart';
import '../core/app_state.dart';
import '../core/i18n.dart';
import '../shell/page.dart';
import '../shell/routes.dart';
import '../ui/app_image.dart';
import '../ui/detail.dart';
import '../ui/tile.dart';
import 'player.dart';
import 'records.dart';

/// The website's event tracker (`event-tracker`): the event running on the
/// chosen game server, its challenge songs and their live rankings, and the
/// point ranking where the event has one.
class EventTrackerScreen extends StatefulWidget {
  const EventTrackerScreen({super.key, this.initialRegion});
  final String? initialRegion;
  @override
  State<EventTrackerScreen> createState() => _EventTrackerScreenState();
}

class _EventTrackerScreenState extends State<EventTrackerScreen> {
  String? _region;
  String? _challenge;
  Future<(Map, Map?, Map, CatalogVisuals)>? _data;
  Timer? _clock;
  final _rankings = GlobalKey<RankingListState>();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    _region ??= const {'jp', 'tw', 'en', 'kr'}.contains(widget.initialRegion)
        ? widget.initialRegion
        : defaultRecordRegion(
            CatalogSourceScope.serverOf(context),
            state.text.locale,
          );
    _data ??= _load();
    _clock ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  Future<(Map, Map?, Map, CatalogVisuals)> _load() async {
    final api = AppScope.of(context).api;
    final current =
        await api.live('/api/v1/game/records/$_region/events/current') as Map;
    final event = current['event'] as Map?;
    final (events, songs, visuals) = await (
      api.catalog('events'),
      api.catalog('songs'),
      CatalogVisuals.of(api),
    ).wait;
    final info = ((events as Map?)?['entries'] as Map?)?.values
        .whereType<Map>()
        .where((e) => '${e['id']}' == '${event?['id']}')
        .firstOrNull;
    return (current, info, (songs as Map?) ?? const {}, visuals);
  }

  String _countdown(SiteText t, num? end) {
    if (end == null) return t('tools.eventTracker.unknownDeadline', '');
    final left = Duration(
      milliseconds: (end - DateTime.now().millisecondsSinceEpoch).toInt(),
    );
    if (left.isNegative) return t('tools.eventTracker.ended', '');
    final clock =
        '${left.inHours % 24}:${(left.inMinutes % 60).toString().padLeft(2, '0')}:${(left.inSeconds % 60).toString().padLeft(2, '0')}';
    final time = left.inDays > 0
        ? t('tools.eventTracker.duration', '{days} {time}', {
            'days': left.inDays,
            'time': clock,
          })
        : clock;
    return t('tools.eventTracker.endsIn', '{time}', {'time': time});
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ShellPage(
      title: t('tools.eventTracker.title', 'Event tracker'),
      actions: [
        regionChoice(
          t,
          _region!,
          (region) => setState(() {
            _region = region;
            _challenge = null;
            _data = _load();
          }),
        ),
        BarAction(
          icon: Symbols.refresh_rounded,
          label: t('tools.eventTracker.refresh', 'Refresh'),
          onPressed: () {
            setState(() => _data = _load());
            _rankings.currentState?.refresh();
          },
        ),
      ],
      body: FutureBuilder(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t(
                      'tools.eventTracker.error',
                      'Event information could not be loaded.',
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonal(
                    onPressed: () => setState(() => _data = _load()),
                    child: Text(t('tools.eventTracker.retry', 'Retry')),
                  ),
                ],
              ),
            );
          }
          final data = snapshot.data;
          if (data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final (current, info, songs, visuals) = data;
          final event = current['event'] as Map?;
          if (event == null) {
            return Center(
              child: Text(
                t('tools.eventTracker.empty', 'No event to track right now.'),
              ),
            );
          }
          final challenges = (event['challenges'] as List? ?? const [])
              .whereType<Map>()
              .where((c) => c['enabled'] != false)
              .toList();
          final selected =
              challenges.where((c) => '${c['id']}' == _challenge).firstOrNull ??
              challenges.firstOrNull;
          final songProfile = catalogProfiles.firstWhere(
            (p) => p.resource == 'songs',
          );
          final songKit = CatalogKit(
            songProfile,
            t,
            CatalogSourceScope.apiOf(context),
            visuals,
            songTitles: state.songTitle,
          );
          final dates = DateFormat.yMd(t.locale).add_Hm();
          String date(Object? ms) => ms is num
              ? dates.format(DateTime.fromMillisecondsSinceEpoch(ms.toInt()))
              : '';
          final image = info?['image'];
          final padding = pagePadding(context);
          void openPlayer(String id) => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  PlayerProfileScreen(region: _region!, profileId: id),
            ),
          );
          return ListView(
            padding: padding,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (image is String)
                    InkWell(
                      onTap: () => openEntity(
                        context,
                        catalogProfiles.firstWhere(
                          (p) => p.resource == 'events',
                        ),
                        {...info!.cast<String, Object?>()},
                      ),
                      child: SizedBox(
                        width: 80,
                        height: 80,
                        child: AppImage(
                          candidates: [
                            CatalogSourceScope.apiOf(context)
                                .asset(image)
                                .toString(),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          info == null
                              ? t('tools.eventTracker.eventName', '', {
                                  'id': event['id'],
                                })
                              : t.text(info['title']),
                          style: theme.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${t('tools.eventTracker.event', 'Event')} · #${event['id']} · ${date(event['startAtMs'])} - ${date(event['endAtMs'])}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          _countdown(t, event['endAtMs'] as num?),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (current['stale'] == true)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    t('tools.eventTracker.cached', ''),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 24),
              DetailSection(
                icon: Symbols.bar_chart_rounded,
                title: t(
                  'tools.eventTracker.challengeRanking',
                  'Challenge song ranking',
                ),
                child: challenges.isEmpty
                    ? Text(t('tools.eventTracker.noChallenges', ''))
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final columns = constraints.maxWidth < 600 ? 2 : 4;
                          final width =
                              (constraints.maxWidth - 8 * (columns - 1)) /
                              columns;
                          return Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final challenge in challenges)
                                SizedBox(
                                  width: width,
                                  child: Builder(
                                    builder: (context) {
                                      final song =
                                          (songs['${challenge['musicId']}']
                                                  as Map?)
                                              ?.cast<String, Object?>() ??
                                          {'musicId': challenge['musicId']};
                                      final active = challenge == selected;
                                      return Tile(
                                        selected: active,
                                        title: songKit.title(song),
                                        subtitle: songKit.subtitle(song),
                                        adornments: songKit.adornments(song),
                                        images: songKit.images(song),
                                        marks: songKit.marks(song),
                                        onTap: () => setState(
                                          () =>
                                              _challenge = '${challenge['id']}',
                                        ),
                                      );
                                    },
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
              ),
              if (selected != null)
                RankingList(
                  key: _rankings,
                  region: _region!,
                  endpoint:
                      '/api/v1/game/records/$_region/events/${event['id']}/challenges/${selected['id']}/ranking',
                  onPlayer: openPlayer,
                ),
              const SizedBox(height: 24),
              DetailSection(
                icon: Symbols.leaderboard_rounded,
                title: t(
                  'tools.eventTracker.pointRanking',
                  'Event point ranking',
                ),
                child: event['pointRankingEnabled'] == true
                    ? RankingList(
                        region: _region!,
                        points: true,
                        endpoint:
                            '/api/v1/game/records/$_region/events/${event['id']}/latest',
                        onPlayer: openPlayer,
                      )
                    : Text(
                        t('tools.eventTracker.pointsDisabled', ''),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
