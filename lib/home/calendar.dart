import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/app_state.dart';
import '../core/i18n.dart';
import '../core/page_data.dart';
import '../shell/links.dart';
import '../shell/page.dart';
import '../ui/app_image.dart';
import '../ui/theme.dart';
import '../ui/tile.dart';

typedef Json = Map<String, Object?>;

/// Civil dates, kept apart from instants as `calendar-model.ts` does.
DateTime _day(DateTime d) => DateTime.utc(d.year, d.month, d.day);
DateTime _dayAt(num ms) =>
    _day(DateTime.fromMillisecondsSinceEpoch(ms.toInt()));
DateTime? _parse(Object? value) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch('${value ?? ''}');
  return m == null
      ? null
      : DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

const calendarFacets = [
  'our-notes:character',
  'our-notes:cast',
  'garupa:character',
  'garupa:cast',
  'event',
  'gacha',
  'login',
  'pass',
  'game-live',
  'external-live',
  'arena',
  'arena-rotation',
];
const _facetLabels = {
  'our-notes:character': 'ourNotesCharacterBirthday',
  'our-notes:cast': 'ourNotesCastBirthday',
  'garupa:character': 'garupaCharacterBirthday',
  'garupa:cast': 'garupaCastBirthday',
  'event': 'event',
  'gacha': 'gacha',
  'login': 'login',
  'pass': 'pass',
  'game-live': 'game-live',
  'external-live': 'externalLive',
  'arena': 'arena',
  'arena-rotation': 'arena-rotation',
};

/// One dated thing on the calendar (`CalendarOccurrence`).
class Occurrence {
  Occurrence(this.source, this.kind, this.start, this.end, this.facets);
  final Json source;
  final String kind;
  final DateTime start;
  final DateTime end;
  final List<String> facets;

  bool get birthday => kind == 'character' || kind == 'cast';
  String get category => birthday
      ? 'birthdays'
      : kind == 'live'
      ? 'lives'
      : 'activities';
  bool on(DateTime date) => !start.isAfter(date) && !end.isBefore(date);
}

/// Birthdays and activities between [first] and [last] (`calendarOccurrences`).
List<Occurrence> occurrences(Json data, DateTime first, DateTime last) {
  final result = <Occurrence>[];
  for (final person in (data['birthdays'] as List? ?? const []).cast<Json>()) {
    for (var year = first.year; year <= last.year; year++) {
      final month = (person['month'] as num).toInt(),
          day = (person['day'] as num).toInt();
      final date = DateTime.utc(year, month, day);
      if (date.month != month || date.isBefore(first) || date.isAfter(last)) {
        continue;
      }
      final games =
          (person['games'] as List?)?.cast<String>() ?? ['${person['game']}'];
      result.add(
        Occurrence(person, '${person['kind']}', date, date, [
          for (final game in games) '$game:${person['kind']}',
        ]),
      );
    }
  }
  for (final activity
      in (data['activities'] as List? ?? const []).cast<Json>()) {
    final startMs = activity['startAtMs'] as num?;
    final endMs = activity['endAtMs'] as num?;
    final timed = activity['allDay'] != true && startMs != null && startMs > 0;
    final date = _parse(activity['date']);
    if (!timed && date == null) continue;
    final start = timed ? _dayAt(startMs) : date!;
    DateTime end;
    if (timed && endMs != null && endMs > startMs) {
      end = _dayAt(endMs - (activity['endExclusive'] == false ? 0 : 1));
    } else if (timed) {
      end = start;
    } else {
      final endDate = _parse(activity['endDate']);
      end = endDate == null
          ? start
          : activity['endExclusive'] == true
          ? endDate.subtract(const Duration(days: 1))
          : endDate;
    }
    if (end.isBefore(start) || end.isBefore(first) || start.isAfter(last)) {
      continue;
    }
    final kind = '${activity['kind']}';
    result.add(
      Occurrence(
        activity,
        kind,
        start,
        end,
        (activity['facets'] as List?)?.cast<String>() ??
            [kind == 'live' ? 'external-live' : kind],
      ),
    );
  }
  int priority(String kind) => kind == 'character'
      ? 0
      : kind == 'cast'
      ? 1
      : 2;
  result.sort(
    (x, y) => x.start.compareTo(y.start) != 0
        ? x.start.compareTo(y.start)
        : priority(x.kind) != priority(y.kind)
        ? priority(x.kind) - priority(y.kind)
        : y.end.compareTo(x.end) != 0
        ? y.end.compareTo(x.end)
        : '${x.source['id']}'.compareTo('${y.source['id']}'),
  );
  return result;
}

class _Segment {
  _Segment(
    this.item,
    this.column,
    this.span,
    this.lane,
    this.before,
    this.after,
  );
  final Occurrence item;
  final int column, span, lane;
  final bool before, after;
}

/// Greedy stable lanes for one week (`calendarWeekSegments`).
List<_Segment> _segments(List<Occurrence> items, List<DateTime> week) {
  final first = week.first, last = week.last;
  final ends = <int>[];
  final result = <_Segment>[];
  for (final item in items) {
    if (item.start.isAfter(last) || item.end.isBefore(first)) continue;
    final start = item.start.isBefore(first) ? first : item.start;
    final end = item.end.isAfter(last) ? last : item.end;
    final column = start.difference(first).inDays;
    final finalColumn = end.difference(first).inDays;
    var lane = ends.indexWhere((previous) => previous < column);
    if (lane < 0) {
      lane = ends.length;
      ends.add(finalColumn);
    } else {
      ends[lane] = finalColumn;
    }
    result.add(
      _Segment(
        item,
        column,
        finalColumn - column + 1,
        lane,
        item.start.isBefore(first),
        item.end.isAfter(last),
      ),
    );
  }
  return result;
}

/// The website's calendar (`calendar-page`): a month grid with each week's
/// bars and the selected day's agenda, or the agenda alone; birthdays and
/// activities filtered by facet.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});
  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  Future<(Json, Map<String, String>)>? _data;
  DateTime _selected = _day(DateTime.now());
  final DateTime _today = _day(DateTime.now());
  bool _agenda = false;
  Set<String> _categories = {...calendarFacets};

  Object? _dataKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final key = AppScope.of(context).publicDataKey;
    if (_dataKey != key) {
      _dataKey = key;
      _data = _load();
    }
  }

  /// The calendar the website publishes with its page (`loadCalendarData`).
  Future<(Json, Map<String, String>)> _load() async {
    final state = AppScope.of(context);
    final page = await pageData(
      '/${state.server}/${state.text.locale}/calendar/',
      'calendar-data-${state.server}',
    );
    return (
      page['calendar'] as Json,
      {
        for (final MapEntry(:key, :value)
            in ((page['labels'] as Map?) ?? const {}).entries)
          if (value is String) '$key': value,
      },
    );
  }

  int get _weekStart =>
      MaterialLocalizations.of(context).firstDayOfWeekIndex % 7;

  List<DateTime> _monthDays() {
    final first = DateTime.utc(_selected.year, _selected.month, 1);
    final offset = (first.weekday % 7 - _weekStart + 7) % 7;
    final start = first.subtract(Duration(days: offset));
    return [for (var i = 0; i < 42; i++) start.add(Duration(days: i))];
  }

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    return FutureBuilder(
      future: _data,
      builder: (context, snapshot) {
        final labels = snapshot.data?.$2 ?? const <String, String>{};
        String label(String key, String fallback) =>
            labels[key] ?? t('tools.calendar.$key', fallback);
        final data = snapshot.data?.$1;
        final present = <String>{
          if (data != null) ...[
            for (final b in (data['birthdays'] as List).cast<Json>())
              for (final game
                  in (b['games'] as List?)?.cast<String>() ?? ['${b['game']}'])
                '$game:${b['kind']}',
            for (final a in (data['activities'] as List).cast<Json>())
              ...?(a['facets'] as List?)?.cast<String>(),
            for (final a in (data['activities'] as List).cast<Json>())
              if (a['facets'] == null)
                a['kind'] == 'live' ? 'external-live' : '${a['kind']}',
          ],
        };
        final available = calendarFacets.where(present.contains).toList();
        final days = _monthDays();
        final items = data == null
            ? <Occurrence>[]
            : occurrences(
                data,
                days.first,
                days.last,
              ).where((o) => o.facets.any(_categories.contains)).toList();
        return ShellPage(
          title: label('title', 'Calendar'),
          actions: [
            BarAction(
              icon: Symbols.filter_alt_rounded,
              label: t('common.actions.filter', 'Filter'),
              badge: available.where((k) => !_categories.contains(k)).length,
              onPressed: () => _filters(context, available, label),
            ),
            BarAction.choice(
              label: t('common.actions.view', 'View'),
              options: [
                BarChoice(
                  icon: Symbols.event_rounded,
                  label: label('month', 'Month'),
                  selected: !_agenda,
                  onSelected: () => setState(() => _agenda = false),
                ),
                BarChoice(
                  icon: Symbols.view_list_rounded,
                  label: label('agenda', 'Agenda'),
                  selected: _agenda,
                  onSelected: () => setState(() => _agenda = true),
                ),
              ],
            ),
          ],
          body: snapshot.hasError
              ? Center(
                  child: FilledButton.tonalIcon(
                    icon: const Icon(Symbols.refresh_rounded),
                    label: Text(t('common.actions.retry', 'Retry')),
                    onPressed: () => setState(() => _data = _load()),
                  ),
                )
              : data == null
              ? const Center(child: CircularProgressIndicator())
              : _body(context, items, days, label),
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    List<Occurrence> items,
    List<DateTime> days,
    String Function(String, String) label,
  ) {
    final t = AppScope.of(context).text;
    final theme = Theme.of(context);
    final locale = t.locale;
    final onDay = items.where((o) => o.on(_selected)).toList();
    final agenda = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_agenda) _strip(context),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                DateFormat.MMMMEEEEd(locale).format(_selected),
                style: theme.textTheme.titleMedium,
              ),
              Text(
                DateTime.now().timeZoneName,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (onDay.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                Icon(
                  Symbols.event_rounded,
                  size: 32,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 8),
                Text(label('empty', 'No events')),
              ],
            ),
          )
        else
          for (final (index, item) in onDay.indexed) ...[
            if (index > 0) const Divider(height: 1),
            _Entry(item: item, range: _range(item, label)),
          ],
      ],
    );
    return ListView(
      padding: pagePadding(context),
      children: [
        _toolbar(context, label),
        if (!_agenda) _month(context, items, days, label),
        agenda,
      ],
    );
  }

  Widget _toolbar(BuildContext context, String Function(String, String) label) {
    final theme = Theme.of(context);
    final t = AppScope.of(context).text;
    return Row(
      children: [
        Expanded(
          child: Text(
            DateFormat.yMMMM(t.locale).format(_selected),
            style: theme.textTheme.headlineSmall,
          ),
        ),
        TextButton(
          onPressed: () => setState(() => _selected = _today),
          child: Text(label('today', 'Today')),
        ),
        IconButton(
          tooltip: label('previous', 'Previous month'),
          onPressed: () => setState(() => _selected = _shiftMonth(-1)),
          icon: const Icon(Symbols.chevron_left_rounded),
        ),
        IconButton(
          tooltip: label('next', 'Next month'),
          onPressed: () => setState(() => _selected = _shiftMonth(1)),
          icon: const Icon(Symbols.chevron_right_rounded),
        ),
        IconButton(
          tooltip: label('chooseDate', 'Choose date'),
          onPressed: () async {
            final date = await showDatePicker(
              context: context,
              initialDate: _selected,
              firstDate: DateTime.utc(2020),
              lastDate: DateTime.utc(2040),
            );
            if (date != null) setState(() => _selected = _day(date));
          },
          icon: const Icon(Symbols.event_rounded),
        ),
      ],
    );
  }

  DateTime _shiftMonth(int step) {
    final first = DateTime.utc(_selected.year, _selected.month + step, 1);
    final cap = DateTime.utc(first.year, first.month + 1, 0).day;
    return DateTime.utc(first.year, first.month, _selected.day.clamp(1, cap));
  }

  /// The week around the selected day, as the agenda view's date strip.
  Widget _strip(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final offset = (_selected.weekday % 7 - _weekStart + 7) % 7;
    final first = _selected.subtract(Duration(days: offset));
    return Row(
      children: [
        for (var i = 0; i < 7; i++)
          Builder(
            builder: (context) {
              final date = first.add(Duration(days: i));
              final selected = date == _selected;
              return Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(Corner.large),
                  onTap: () => setState(() => _selected = date),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: selected ? scheme.primaryContainer : null,
                      borderRadius: BorderRadius.circular(Corner.large),
                    ),
                    child: Column(
                      children: [
                        Text(
                          DateFormat.E(AppScope.of(context).text.locale)
                              .format(date)
                              .characters
                              .first,
                          style: theme.textTheme.labelSmall,
                        ),
                        Text('${date.day}', style: theme.textTheme.titleMedium),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _month(
    BuildContext context,
    List<Occurrence> items,
    List<DateTime> days,
    String Function(String, String) label,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final locale = AppScope.of(context).text.locale;
    final month = _selected.month;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(Corner.large),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          SizedBox(
            height: 44,
            child: Row(
              children: [
                for (final date in days.take(7))
                  Expanded(
                    child: Center(
                      child: Text(
                        DateFormat.E(locale).format(date),
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          for (var w = 0; w < 6; w++)
            Builder(
              builder: (context) {
                final week = days.sublist(w * 7, w * 7 + 7);
                final segments = _segments(items, week);
                return SizedBox(
                  height: 140,
                  child: Stack(
                    children: [
                      Row(
                        children: [
                          for (final date in week)
                            Expanded(
                              child: _Cell(
                                date: date,
                                other: date.month != month,
                                selected: date == _selected,
                                today: date == _today,
                                overflow: segments
                                    .where(
                                      (s) => s.lane >= 3 && s.item.on(date),
                                    )
                                    .length,
                                more: label('more', '{count} more'),
                                onTap: () => setState(() => _selected = date),
                              ),
                            ),
                        ],
                      ),
                      Positioned.fill(
                        top: 48,
                        left: 3,
                        right: 3,
                        child: IgnorePointer(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final column = constraints.maxWidth / 7;
                              return Stack(
                                children: [
                                  for (final s in segments.where(
                                    (s) => s.lane < 3,
                                  ))
                                    Positioned(
                                      left: s.column * column + 2,
                                      width: s.span * column - 4,
                                      top: s.lane * 23.0,
                                      height: 20,
                                      child: _Bar(
                                        segment: s,
                                        t: AppScope.of(context).text,
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  String _range(Occurrence item, String Function(String, String) label) {
    final t = AppScope.of(context).text;
    if (item.birthday) return label('allDay', 'All day');
    final start = item.source['startAtMs'] as num?;
    if (item.source['allDay'] == true || start == null) {
      final dates = DateFormat.MMMMd(t.locale);
      return item.kind == 'live'
          ? '${dates.format(item.start)}${item.end != item.start ? ' – ${dates.format(item.end)}' : ''} · ${label('allDay', 'All day')}'
          : label('allDay', 'All day');
    }
    final format = DateFormat.yMMMd(t.locale).add_Hm();
    final end = item.source['endAtMs'] as num?;
    return '${format.format(DateTime.fromMillisecondsSinceEpoch(start.toInt()))}'
        '${end == null ? '' : ' – ${format.format(DateTime.fromMillisecondsSinceEpoch(end.toInt()))}'}';
  }

  void _filters(
    BuildContext context,
    List<String> available,
    String Function(String, String) label,
  ) {
    final t = AppScope.of(context).text;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          Widget group(String title, Iterable<String> keys) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              for (final key in keys.where(available.contains))
                CheckboxListTile(
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _categories.contains(key),
                  title: Text(label(_facetLabels[key]!, key)),
                  onChanged: (_) {
                    setState(() {
                      _categories = {..._categories};
                      if (!_categories.remove(key)) _categories.add(key);
                    });
                    setSheet(() {});
                  },
                ),
            ],
          );
          return ListView(
            shrinkWrap: true,
            children: [
              Row(
                children: [
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      t('common.actions.filter', 'Filter'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() => _categories = {...calendarFacets});
                      setSheet(() {});
                    },
                    child: Text(t('common.actions.reset', 'Reset')),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
              group(
                label('birthdays', 'Birthdays'),
                calendarFacets.where((k) => k.contains(':')),
              ),
              group(
                label('activities', 'Game events'),
                calendarFacets.where((k) => !k.contains(':')),
              ),
              const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.date,
    required this.other,
    required this.selected,
    required this.today,
    required this.overflow,
    required this.more,
    required this.onTap,
  });
  final DateTime date;
  final bool other, selected, today;
  final int overflow;
  final String more;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: selected
              ? scheme.secondaryContainer.withValues(alpha: 0.35)
              : null,
          border: Border(
            top: BorderSide(color: scheme.outlineVariant),
            left: BorderSide(color: scheme.outlineVariant, width: 0.5),
            right: BorderSide(color: scheme.outlineVariant, width: 0.5),
          ),
        ),
        child: Column(
          children: [
            const SizedBox(height: 6),
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: today
                  ? BoxDecoration(
                      color: scheme.primaryContainer,
                      shape: BoxShape.circle,
                    )
                  : null,
              child: Text(
                '${date.day}',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: today
                      ? scheme.onPrimaryContainer
                      : other
                      ? scheme.onSurfaceVariant.withValues(alpha: 0.6)
                      : scheme.onSurface,
                ),
              ),
            ),
            const Spacer(),
            if (overflow > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  more.replaceAll('{count}', '$overflow'),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.segment, required this.t});
  final _Segment segment;
  final SiteText t;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (segment.item.category) {
      'birthdays' => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      'lives' => (scheme.primaryContainer, scheme.onPrimaryContainer),
      _ => (scheme.secondaryContainer, scheme.onSecondaryContainer),
    };
    final title = t.text(
      segment.item.source['title'] ?? segment.item.source['name'],
    );
    const radius = Radius.circular(Corner.extraSmall);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.horizontal(
          left: segment.before ? Radius.zero : radius,
          right: segment.after ? Radius.zero : radius,
        ),
        border: Border(
          left: segment.before
              ? BorderSide(color: foreground, width: 3)
              : BorderSide.none,
          right: segment.after
              ? BorderSide(color: foreground, width: 3)
              : BorderSide.none,
        ),
      ),
      child: Row(
        children: [
          if (segment.item.birthday && MediaQuery.sizeOf(context).width >= 600)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(Symbols.cake_rounded, size: 14, color: foreground),
            ),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}

/// One entry in the day's agenda: artwork, title, kind and time, opening
/// its page in the app.
class _Entry extends StatelessWidget {
  const _Entry({required this.item, required this.range});
  final Occurrence item;
  final String range;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final t = state.text;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final image = item.source['image'];
    final href = item.source['href'] as String?;
    final kindLabel = t('tools.calendar.${item.kind}', item.kind);
    return InkWell(
      onTap: href == null ? null : () => openLink(context, href),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(Corner.small),
              child: Container(
                width: 56,
                height: 56,
                color: scheme.surfaceContainerHighest,
                child: image is String
                    ? AppImage(
                        candidates: [state.api.asset(image).toString()],
                        fit: BoxFit.cover,
                      )
                    : Icon(
                        item.kind == 'live'
                            ? Symbols.festival_rounded
                            : Symbols.event_rounded,
                        color: scheme.onSurfaceVariant,
                      ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.text(item.source['title'] ?? item.source['name']),
                    style: theme.textTheme.bodyLarge,
                  ),
                  Text(
                    kindLabel,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    range,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (item.source['venue'] is String)
                    Text(
                      '${item.source['venue']}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (href != null)
              Icon(
                Symbols.chevron_right_rounded,
                color: scheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }
}
