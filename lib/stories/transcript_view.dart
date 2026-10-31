import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../catalog/song_video.dart';
import '../catalog/visuals.dart';
import '../core/api.dart';
import '../core/app_state.dart';
import '../core/voice.dart';
import '../ui/adv_text.dart';
import '../ui/app_image.dart';
import '../ui/detail.dart';
import '../ui/dialogue_row.dart';
import 'transcript.dart';

class StoryTranscript extends StatefulWidget {
  const StoryTranscript({
    super.key,
    required this.entries,
    required this.playback,
    required this.visuals,
    required this.api,
    this.provider = false,
    this.joiner,
  });
  final List<TranscriptEntry> entries;
  final VoicePlayback playback;
  final CatalogVisuals? visuals;
  final HaneokaApi api;
  final bool provider;
  final Object? joiner;
  @override
  State<StoryTranscript> createState() => _StoryTranscriptState();
}

class _StoryTranscriptState extends State<StoryTranscript> {
  String _query = '';
  final _speakers = <String>{};
  final _search = TextEditingController();
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    final theme = Theme.of(context);
    final speakers = <TranscriptEntry, TranscriptSpeaker>{
      for (final entry in widget.entries)
        entry: transcriptSpeaker(
          entry.command,
          widget.visuals,
          t,
          provider: widget.provider,
        ),
    };
    String name(TranscriptEntry entry) {
      final speaker = speakers[entry]!;
      final joiner = widget.joiner;
      final separator = joiner is String
          ? joiner
          : t.textIn(joiner, speaker.locale);
      return speaker.text(
        separator.isNotEmpty
            ? separator
            : t('story.relationships.speakerNameSeparator', ' & '),
      );
    }

    final options = <String, String>{
      for (final entry in widget.entries.where((e) => e.dialogue))
        for (final key in speakers[entry]!.keys)
          key: key == 'anonymous'
              ? t('story.reading.anonymous', 'Anonymous speaker (???)')
              : key == 'unnamed'
              ? t('story.reading.unnamed', 'Unnamed text')
              : AdvText.plain(key.substring(5)),
    };
    String normalize(String text) =>
        text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    final needle = normalize(_query);
    final entries = widget.entries
        .where(
          (entry) =>
              needle.isEmpty && _speakers.isEmpty ||
              entry.dialogue &&
                  (_speakers.isEmpty ||
                      speakers[entry]!.keys.any(_speakers.contains)) &&
                  (needle.isEmpty ||
                      normalize(
                        '${AdvText.plain(name(entry))} ${AdvText.plain(t.text(entry.command['text']))}',
                      ).contains(needle)),
        )
        .toList();
    final content = <Widget>[];
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      if (const {'image', 'video', 'stamp', 'voice'}.contains(entry.kind)) {
        final group = [entry];
        while (index + 1 < entries.length &&
            entries[index + 1].kind == entry.kind &&
            entries[index + 1].mediaKind == entry.mediaKind) {
          group.add(entries[++index]);
        }
        final key = entry.kind == 'image'
            ? entry.mediaKind == 'background'
                  ? 'background'
                  : 'illustration'
            : entry.kind;
        content.add(
          DetailFold(
            title: t('story.labels.$key', key),
            meta: '${group.length}',
            child: Column(
              children: [
                for (final row in group)
                  _row(context, row, speakers[row]!, name(row)),
              ],
            ),
          ),
        );
      } else {
        content.add(_row(context, entry, speakers[entry]!, name(entry)));
      }
    }
    return DetailSection(
      icon: Symbols.article_rounded,
      title: t('navigation.storyText', 'Story text'),
      count: entries.where((e) => e.dialogue).length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _search,
            onChanged: (value) => setState(() => _query = value),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Symbols.search_rounded),
              labelText:
                  '${t('common.actions.search', 'Search')} / ${t('navigation.storyText', 'Story text')}',
              helperText:
                  '${entries.where((e) => e.dialogue).length} / ${widget.entries.where((e) => e.dialogue).length}',
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: t('common.actions.reset', 'Reset'),
                      onPressed: () => setState(() {
                        _query = '';
                        _search.clear();
                      }),
                      icon: const Icon(Symbols.close_rounded),
                    ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            t('story.reading.speakers', 'Speakers'),
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in options.entries)
                FilterChip(
                  label: Text(option.value),
                  selected: _speakers.contains(option.key),
                  onSelected: (_) => setState(() {
                    if (!_speakers.remove(option.key)) {
                      _speakers.add(option.key);
                    }
                  }),
                ),
              if (_query.isNotEmpty || _speakers.isNotEmpty)
                ActionChip(
                  label: Text(t('common.actions.clear', 'Clear')),
                  onPressed: () => setState(() {
                    _query = '';
                    _search.clear();
                    _speakers.clear();
                  }),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (content.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(t('common.states.empty', 'No results')),
            ),
          SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: content,
            ),
          ),
        ],
      ),
    );
  }

  List<VoiceClip> _tracks(TranscriptEntry entry, String speaker, String text) =>
      [
        for (final voice in entry.voices)
          if ((voice['playableUrl'] ?? voice['url']) case final String url
              when url.isNotEmpty)
            VoiceClip(
              id: '${widget.api.asset(url)}',
              url: '${widget.api.asset(url)}',
            ),
      ];

  Widget _row(
    BuildContext context,
    TranscriptEntry entry,
    TranscriptSpeaker speaker,
    String name,
  ) {
    final state = AppScope.of(context);
    final t = state.text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = t.text(entry.command['text']);
    if (entry.kind == 'image' && entry.source != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: ImageGallery(
          images: [widget.api.asset(entry.source!).toString()],
          aspectRatio: 16 / 9,
        ),
      );
    }
    if (entry.kind == 'video' && entry.source != null) {
      return SongVideos(
        song: {'mvUrl': widget.api.asset(entry.source!).toString()},
      );
    }
    if (entry.kind == 'location' || entry.kind == 'conversation') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(
              entry.kind == 'location'
                  ? Symbols.location_on_rounded
                  : Symbols.chat_rounded,
              size: 20,
              color: scheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: AdvText(
                text.isNotEmpty
                    ? text
                    : name.isNotEmpty
                    ? name
                    : t('story.labels.conversation', 'Conversation'),
                style: theme.textTheme.titleSmall,
              ),
            ),
          ],
        ),
      );
    }
    if (entry.kind == 'choices') {
      return DetailFold(
        title: t('choices', 'Choices'),
        open: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final choice
                in (entry.command['choices'] as List? ?? const [])
                    .whereType<Map>())
              Padding(
                padding: const EdgeInsets.all(8),
                child: AdvText('• ${t.text(choice['text'])}'),
              ),
          ],
        ),
      );
    }
    final tracks = _tracks(entry, name, AdvText.plain(text));
    final faces = <String>{...speaker.faces};
    final chatIcon = entry.command['chatIconAssetName'];
    if (speaker.status == 0 &&
        chatIcon is String &&
        chatIcon.isNotEmpty &&
        const {'message', 'stamp'}.contains(entry.kind)) {
      faces
        ..clear()
        ..add(
          '/assets/${widget.api.server}/Assets/AddressableResources/Adv/Chat/Icon/$chatIcon.png',
        );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: DialogueRow.spacing / 2),
      child: ListenableBuilder(
        listenable: widget.playback,
        builder: (context, _) => DialogueRow(
          name: name,
          faces: [for (final face in faces) widget.api.asset(face).toString()],
          playing: tracks.any((track) => widget.playback.isPlaying(track.id)),
          content: entry.kind == 'stamp'
              ? entry.source != null && entry.source!.isNotEmpty
                    ? SizedBox(
                        height: 160,
                        child: AppImage(
                          candidates: [
                            widget.api.asset(entry.source!).toString(),
                          ],
                        ),
                      )
                    : Icon(
                        Symbols.sentiment_satisfied_rounded,
                        color: scheme.onSurfaceVariant,
                      )
              : AdvText(
                  text.isEmpty && entry.kind == 'voice'
                      ? t('navigation.voice', 'Voice')
                      : text,
                  nativeBase: entry.kind == 'message' ? 24 : 36,
                ),
          action: tracks.isEmpty
              ? null
              : Wrap(
                  children: [
                    for (final (index, track) in tracks.indexed)
                      IconButton(
                        tooltip:
                            '${t('story.labels.playVoice', 'Play voice')}${tracks.length > 1 ? ' ${index + 1}' : ''}',
                        onPressed: () => widget.playback.toggle(track),
                        icon: Icon(
                          widget.playback.isPlaying(track.id)
                              ? Symbols.pause_rounded
                              : Symbols.play_arrow_rounded,
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}
