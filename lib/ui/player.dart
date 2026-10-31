import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../core/audio.dart';
import 'app_image.dart';
import 'theme.dart';

String _clock(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// The collapsed player (`now-playing`): the cover inside a ring showing how
/// much has played. It sits in the title bar on phones and in the navigation
/// elsewhere; tapping it opens the full player.
class NowPlaying extends StatelessWidget {
  const NowPlaying({super.key, this.expanded = false});

  /// The drawer's version adds the title, artist and play/pause.
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final audio = AppScope.of(context).audio;
    return ListenableBuilder(
      listenable: audio,
      builder: (context, _) {
        final track = audio.current;
        if (track == null ||
            (!audio.collapsed && MediaQuery.sizeOf(context).width >= 600)) {
          return const SizedBox.shrink();
        }
        final theme = Theme.of(context);
        final cover = _Ring(
          audio: audio,
          track: track,
          size: expanded ? 52 : 40,
        );
        if (!expanded) {
          return IconButton(
            tooltip: track.title,
            onPressed: () => showPlayer(context),
            icon: cover,
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Material(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(Corner.large),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => showPlayer(context),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    cover,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                          Text(
                            track.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: audio.playing ? audio.pause : audio.resume,
                      icon: Icon(
                        audio.playing
                            ? Symbols.pause_rounded
                            : Symbols.play_arrow_rounded,
                        fill: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({required this.audio, required this.track, required this.size});
  final AudioService audio;
  final Track track;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ValueListenableBuilder(
            valueListenable: audio.position,
            builder: (context, position, _) {
              final total = audio.duration.value.inMilliseconds;
              return CircularProgressIndicator(
                value: total <= 0
                    ? 0
                    : (position.inMilliseconds / total).clamp(0.0, 1.0),
                strokeWidth: 3,
                backgroundColor: scheme.surfaceContainerHighest,
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.all(5),
            child: ClipOval(
              child: ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: track.artwork == null
                    ? Icon(
                        Symbols.music_note_rounded,
                        color: scheme.onSurfaceVariant,
                      )
                    : AppImage(candidates: [track.artwork!], fit: BoxFit.cover),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The full player as the website's compact bottom sheet: large artwork,
/// title, the seek row with times, a 96 dp play button and the queue
/// controls.
Future<void> showPlayer(BuildContext context) async {
  final audio = AppScope.of(context).audio;
  if (MediaQuery.sizeOf(context).width >= 600) {
    audio.setExpanded(true);
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (context) => const SingleChildScrollView(child: _FullPlayer()),
  );
}

class _FullPlayer extends StatelessWidget {
  const _FullPlayer();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final audio = state.audio;
    final t = state.text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: audio,
      builder: (context, _) {
        final track = audio.current;
        if (track == null) return const SizedBox(height: 120);
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.4,
                ),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(Corner.extraLarge),
                    child: ColoredBox(
                      color: scheme.surfaceContainerHighest,
                      child: track.artwork == null
                          ? null
                          : AppImage(
                              candidates: [track.artwork!],
                              fit: BoxFit.cover,
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                track.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineSmall,
              ),
              Text(
                track.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              ValueListenableBuilder(
                valueListenable: audio.position,
                builder: (context, position, _) {
                  final total = audio.duration.value;
                  final max = total.inMilliseconds.toDouble().clamp(
                    1.0,
                    double.infinity,
                  );
                  return Column(
                    children: [
                      Slider(
                        value: position.inMilliseconds.toDouble().clamp(0, max),
                        max: max,
                        onChanged: (value) =>
                            audio.seek(Duration(milliseconds: value.round())),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _clock(position),
                              style: theme.textTheme.labelMedium,
                            ),
                            Text(
                              _clock(total),
                              style: theme.textTheme.labelMedium,
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
              Row(
                children: [
                  IconButton(
                    tooltip: _modeLabel(audio, t),
                    onPressed: audio.cycleMode,
                    icon: Icon(_modeIcon(audio.mode)),
                  ),
                  IconButton(
                    tooltip: t(
                      audio.volume > 0
                          ? 'common.actions.mute'
                          : 'common.actions.unmute',
                    ),
                    onPressed: audio.toggleMute,
                    icon: Icon(
                      audio.volume > 0
                          ? Symbols.volume_up_rounded
                          : Symbols.volume_off_rounded,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: audio.volume,
                      onChanged: audio.setVolume,
                    ),
                  ),
                  Text('${(audio.volume * 100).round()}%'),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: t(
                      'media.audio.closePlayerAndClearQueue',
                      'Close player and clear queue',
                    ),
                    onPressed: () {
                      audio.stop();
                      Navigator.of(context).pop();
                    },
                    icon: const Icon(Symbols.close_rounded),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: t('common.actions.previous', 'Previous'),
                    iconSize: 32,
                    onPressed: audio.previous,
                    icon: const Icon(Symbols.skip_previous_rounded, fill: 1),
                  ),
                  const SizedBox(width: 16),
                  SizedBox.square(
                    dimension: 96,
                    child: IconButton.filled(
                      tooltip: t(
                        audio.playing
                            ? 'common.actions.pause'
                            : 'common.actions.play',
                      ),
                      iconSize: 48,
                      style: IconButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            audio.playing ? Corner.extraLarge : 48,
                          ),
                        ),
                      ),
                      onPressed: audio.playing ? audio.pause : audio.resume,
                      icon: Icon(
                        audio.playing
                            ? Symbols.pause_rounded
                            : Symbols.play_arrow_rounded,
                        fill: 1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  IconButton(
                    tooltip: t('common.actions.next', 'Next'),
                    iconSize: 32,
                    onPressed: audio.hasNext ? () => audio.next() : null,
                    icon: const Icon(Symbols.skip_next_rounded, fill: 1),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: t('media.audio.queue', 'Queue'),
                    onPressed: () => _showQueue(context, audio),
                    icon: Badge(
                      label: Text('${audio.queue.length}'),
                      child: const Icon(Symbols.queue_music_rounded),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

IconData _modeIcon(PlaybackMode mode) => switch (mode) {
  PlaybackMode.sequential => Symbols.playlist_play_rounded,
  PlaybackMode.repeatAll => Symbols.repeat_rounded,
  PlaybackMode.repeatOne => Symbols.repeat_one_rounded,
  PlaybackMode.shuffle => Symbols.shuffle_rounded,
};

String _modeLabel(AudioService audio, dynamic t) => t(switch (audio.mode) {
  PlaybackMode.sequential => 'media.audio.playInOrder',
  PlaybackMode.repeatAll => 'media.audio.repeatQueue',
  PlaybackMode.repeatOne => 'media.audio.repeatTrack',
  PlaybackMode.shuffle => 'common.actions.shuffle',
});

Future<void> _showQueue(
  BuildContext context,
  AudioService audio,
) => showModalBottomSheet<void>(
  context: context,
  useSafeArea: true,
  showDragHandle: true,
  isScrollControlled: true,
  constraints: const BoxConstraints(maxWidth: 560),
  builder: (context) => ListenableBuilder(
    listenable: audio,
    builder: (context, _) {
      final t = AppScope.of(context).text;
      return SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: [
            Row(
              children: [
                const SizedBox(width: 24),
                Expanded(
                  child: Text(
                    '${t('media.audio.queue', 'Queue')} / ${audio.queue.length}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: _modeLabel(audio, t),
                  onPressed: audio.cycleMode,
                  icon: Icon(_modeIcon(audio.mode)),
                ),
                IconButton(
                  tooltip: t('media.audio.closePlayerAndClearQueue'),
                  onPressed: () {
                    audio.stop();
                    Navigator.pop(context);
                  },
                  icon: const Icon(Symbols.close_rounded),
                ),
              ],
            ),
            Expanded(
              child: ReorderableListView.builder(
                itemCount: audio.queue.length,
                onReorderItem: audio.move,
                itemBuilder: (context, index) {
                  final track = audio.queue[index];
                  return ListTile(
                    key: ObjectKey(track),
                    selected: index == audio.index,
                    leading: SizedBox.square(
                      dimension: 44,
                      child: track.artwork == null
                          ? const Icon(Symbols.music_note_rounded)
                          : AppImage(candidates: [track.artwork!]),
                    ),
                    title: Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      track.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => audio.select(index),
                    trailing: Padding(
                      padding: const EdgeInsets.only(right: 32),
                      child: IconButton(
                        tooltip: t('common.actions.remove', 'Remove'),
                        onPressed: () => audio.remove(index),
                        icon: const Icon(Symbols.delete_rounded),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  ),
);

/// Medium/wide website player: docked transport with page space reserved.
class DockedPlayer extends StatelessWidget {
  const DockedPlayer({super.key});
  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final audio = state.audio;
    final t = state.text;
    return ListenableBuilder(
      listenable: audio,
      builder: (context, _) {
        final track = audio.current;
        if (track == null || audio.collapsed) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Material(
            elevation: 4,
            color: Theme.of(context).colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(28),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      SizedBox.square(
                        dimension: 56,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: track.artwork == null
                              ? const Icon(Symbols.music_note_rounded)
                              : AppImage(candidates: [track.artwork!]),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            Text(
                              track.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: t('common.actions.previous'),
                        onPressed: audio.previous,
                        icon: const Icon(
                          Symbols.skip_previous_rounded,
                          fill: 1,
                        ),
                      ),
                      SizedBox.square(
                        dimension: 56,
                        child: IconButton.filled(
                          tooltip: t(
                            audio.playing
                                ? 'common.actions.pause'
                                : 'common.actions.play',
                          ),
                          onPressed: audio.playing ? audio.pause : audio.resume,
                          icon: Icon(
                            audio.playing
                                ? Symbols.pause_rounded
                                : Symbols.play_arrow_rounded,
                            fill: 1,
                            size: 32,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: t('common.actions.next'),
                        onPressed: () => audio.next(),
                        icon: const Icon(Symbols.skip_next_rounded, fill: 1),
                      ),
                      const SizedBox(width: 24),
                      IconButton(
                        tooltip: _modeLabel(audio, t),
                        onPressed: audio.cycleMode,
                        icon: Icon(_modeIcon(audio.mode)),
                      ),
                      IconButton(
                        tooltip: t('media.audio.queue'),
                        onPressed: () => _showQueue(context, audio),
                        icon: Badge(
                          label: Text('${audio.queue.length}'),
                          child: const Icon(Symbols.queue_music_rounded),
                        ),
                      ),
                      IconButton(
                        tooltip: t(
                          audio.volume > 0
                              ? 'common.actions.mute'
                              : 'common.actions.unmute',
                        ),
                        onPressed: audio.toggleMute,
                        icon: Icon(
                          audio.volume > 0
                              ? Symbols.volume_up_rounded
                              : Symbols.volume_off_rounded,
                        ),
                      ),
                      if (MediaQuery.sizeOf(context).width >= 900)
                        SizedBox(
                          width: 110,
                          child: Slider(
                            value: audio.volume,
                            onChanged: audio.setVolume,
                          ),
                        ),
                      IconButton(
                        tooltip: t('common.actions.collapse'),
                        onPressed: () => audio.setExpanded(false),
                        icon: const Icon(Symbols.keyboard_arrow_down_rounded),
                      ),
                      IconButton(
                        tooltip: t('media.audio.closePlayerAndClearQueue'),
                        onPressed: audio.stop,
                        icon: const Icon(Symbols.close_rounded),
                      ),
                    ],
                  ),
                  ListenableBuilder(
                    listenable: Listenable.merge([
                      audio.position,
                      audio.duration,
                    ]),
                    builder: (context, _) {
                      final total = audio.duration.value.inMilliseconds;
                      return Row(
                        children: [
                          Text(
                            _clock(audio.position.value),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                          Expanded(
                            child: Slider(
                              value: audio.position.value.inMilliseconds
                                  .toDouble()
                                  .clamp(0, total > 0 ? total.toDouble() : 1),
                              max: total > 0 ? total.toDouble() : 1,
                              onChanged: total > 0
                                  ? (value) => audio.seek(
                                      Duration(milliseconds: value.round()),
                                    )
                                  : null,
                            ),
                          ),
                          Text(
                            _clock(audio.duration.value),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
