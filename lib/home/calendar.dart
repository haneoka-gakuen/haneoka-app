import '../core/site_date.dart';
import '../core/catalog_source.dart';

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
  String? get href => source['href'] as String?;
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
  const CalendarScreen({super.key, this.initialQuery = const {}});
  final Map<String, String> initialQuery;
  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  Future<(Json, Map<String, String>)>? _data;
  DateTime _selected = _day(DateTime.now());
  final DateTime _today = _day(DateTime.now());
  bool _agenda = false;
  Set<String> _categories = {...calendarFacets};

  @override
  void initState() {
    super.initState();
    final query = widget.initialQuery;
    _selected = _parse(query['date']) ?? _selected;
    _agenda = query['view'] == 'agenda';
    if (query.containsKey('kinds')) {
      _categories = {
        for (final kind in query['kinds']!.split(','))
          ...switch (kind) {
            'character' => ['our-notes:character', 'garupa:character'],
            'cast' => ['our-notes:cast', 'garupa:cast'],
            'live' => ['external-live'],
            _ => [kind],
          },
      }.where(calendarFacets.contains).toSet();
    }
  }

  Object? _dataKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final key = CatalogSourceScope.keyOf(context);
    if (_dataKey != key) {
      _dataKey = key;
      _data = _load();
    }
  }

  /// The calendar the website publishes with its page (`loadCalendarData`).
  Future<(Json, Map<String, String>)> _load() async {
    final state = AppScope.of(context);
    final page = await pageData(
      '/${CatalogSourceScope.serverOf(context)}/${state.text.locale}/calendar/',
      'calendar-data-${CatalogSourceScope.serverOf(context)}',
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
    final next = DateTime.utc(first.year, first.month + 1, 1);
    final weeks = (next.difference(start).inDays / 7).ceil();
    return [for (var i = 0; i < weeks * 7; i++) start.add(Duration(days: i))];
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
          title:
              '${label('title', 'Calendar')} · ${DateFormat.yMMMM(t.locale).format(_selected)}',
          actions: [
            BarAction(
              icon: Symbols.chevron_left_rounded,
              label: label('previous', 'Previous month'),
              onPressed: () => setState(() => _selected = _shiftMonth(-1)),
            ),
            BarAction(
              icon: Symbols.chevron_right_rounded,
              label: label('next', 'Next month'),
              onPressed: () => setState(() => _selected = _shiftMonth(1)),
            ),
            BarAction(
              icon: Symbols.today_rounded,
              label: label('today', 'Today'),
              onPressed: () => setState(() => _selected = _today),
            ),
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
              : _body(context, data, items, days, label),
        );
      },
    );
  }

  Json? _arena(Json data) =>
      _categories.contains('arena') ? data['arena'] as Json? : null;
  List<Object?> _rulesOn(Json? arena, DateTime date) =>
      (arena?['days'] as Map?)?[_key(date)] as List? ?? const [];
  String _key(DateTime date) =>
      '${date.year}-${'${date.month}'.padLeft(2, '0')}-${'${date.day}'.padLeft(2, '0')}';
  String _mission(Object? rule) =>
      switch (((rule as Map?)?['missions'] as List?)?.firstOrNull) {
        1 => 'COMBO',
        2 => 'LUCK',
        3 => 'JUST',
        _ => '—',
      };
  Widget _mark(String? source, double size) => SizedBox(
    width: size,
    height: size,
    child: source == null
        ? null
        : AppImage(
            candidates: [AppScope.of(context).api.asset(source).toString()],
          ),
  );
  String? _missionImage(Json arena, Object? rule) {
    final id = ((rule as Map?)?['missions'] as List?)?.firstOrNull;
    final value = (arena['missions'] as Map?)?['$id'];
    return value is String ? value : null;
  }

  Widget _body(
    BuildContext context,
    Json data,
    List<Occurrence> items,
    List<DateTime> days,
    String Function(String, String) label,
  ) {
    if (_agenda) {
      return ListView(
        padding: pagePadding(context),
        children: [_agendaList(context, data, items, days, label)],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        final side = constraints.maxWidth >= 960;
        final month = _month(context, data, items, days, label, wide);
        final detail = _detail(context, data, items, label);
        if (!side) {
          return ListView(
            padding: pagePadding(context),
            children: [month, const SizedBox(height: 16), detail],
          );
        }
        return SingleChildScrollView(
          padding: pagePadding(context),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 16,
            children: [
              Expanded(child: month),
              SizedBox(width: 300, child: detail),
            ],
          ),
        );
      },
    );
  }

  Widget _detail(
    BuildContext context,
    Json data,
    List<Occurrence> items,
    String Function(String, String) label,
  ) {
    final t = AppScope.of(context).text;
    final theme = Theme.of(context);
    final arena = _arena(data);
    final rules = _rulesOn(arena, _selected);
    final leagues = (arena?['leagues'] as List?)?.cast<Json>() ?? const [];
    final onDay = items
        .where((o) => o.on(_selected) && o.kind != 'arena')
        .toList();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Corner.extraLarge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  DateFormat.MMMEd(t.locale).format(_selected),
                  style: theme.textTheme.titleLarge,
                ),
              ),
              Text(
                DateTime.now().timeZoneName,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          if (rules.isNotEmpty && arena != null) ...[
            Row(
              spacing: 8,
              children: [
                const Icon(Symbols.swords_rounded, size: 18),
                Text(
                  label('arena', 'Gekiso Arena'),
                  style: theme.textTheme.titleSmall,
                ),
              ],
            ),
            for (final (index, rule) in rules.indexed)
              if (rule != null && index < leagues.length)
                InkWell(
                  borderRadius: BorderRadius.circular(Corner.medium),
                  onTap: () => openLink(context, '${arena['href']}'),
                  child: SizedBox(
                    height: 48,
                    child: Row(
                      spacing: 8,
                      children: [
                        _mark('${leagues[index]['image']}', 28),
                        Expanded(
                          child: Text(
                            t.text(leagues[index]['name']),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        _mark(_missionImage(arena, rule), 20),
                        Text(_mission(rule), style: theme.textTheme.labelSmall),
                      ],
                    ),
                  ),
                ),
          ],
          if (onDay.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Center(child: Text(label('empty', 'No events'))),
            )
          else
            for (final (index, item) in onDay.indexed) ...[
              if (index > 0) const Divider(height: 1),
              _Entry(item: item, range: _range(item, label)),
            ],
        ],
      ),
    );
  }

  /// Each day of the month with what starts or ends on it.
  Widget _agendaList(
    BuildContext context,
    Json data,
    List<Occurrence> items,
    List<DateTime> days,
    String Function(String, String) label,
  ) {
    final t = AppScope.of(context).text;
    final theme = Theme.of(context);
    final arena = _arena(data);
    final leagues = (arena?['leagues'] as List?)?.cast<Json>() ?? const [];
    final rows = [
      for (final date in days)
        if (date.month == _selected.month)
          (
            date: date,
            changes: items
                .where(
                  (o) =>
                      o.kind != 'arena' && (o.start == date || o.end == date),
                )
                .toList(),
          ),
    ].where((row) => row.changes.isNotEmpty || row.date == _today).toList();
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Center(child: Text(label('empty', 'No events'))),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        for (final row in rows)
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(Corner.large),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 12,
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(Corner.medium),
                  onTap: () => setState(() {
                    _selected = row.date;
                    _agenda = false;
                  }),
                  child: Container(
                    width: 56,
                    padding: const EdgeInsets.all(4),
                    decoration: row.date == _today
                        ? BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(Corner.medium),
                          )
                        : null,
                    child: Column(
                      children: [
                        Text(
                          DateFormat.E(t.locale).format(row.date),
                          style: theme.textTheme.labelSmall,
                        ),
                        Text(
                          '${row.date.day}',
                          style: theme.textTheme.titleLarge,
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (arena != null && _rulesOn(arena, row.date).isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Wrap(
                            spacing: 12,
                            runSpacing: 4,
                            children: [
                              for (final (index, rule) in _rulesOn(
                                arena,
                                row.date,
                              ).indexed)
                                if (rule != null && index < leagues.length)
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    spacing: 2,
                                    children: [
                                      _mark('${leagues[index]['image']}', 20),
                                      _mark(_missionImage(arena, rule), 18),
                                    ],
                                  ),
                            ],
                          ),
                        ),
                      for (final item in row.changes)
                        InkWell(
                          onTap: item.kind != 'cast' && item.href != null
                              ? () => openLink(context, item.href!)
                              : null,
                          child: SizedBox(
                            height: 48,
                            child: Row(
                              spacing: 8,
                              children: [
                                Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _tone(
                                      theme.colorScheme,
                                      item.kind,
                                    ).$3,
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    t.text(
                                      item.source['title'] ??
                                          item.source['name'],
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  [
                                    if (item.start != item.end)
                                      item.start == row.date
                                          ? label('starts', 'Starts')
                                          : label('ends', 'Ends'),
                                    label(item.kind, item.kind),
                                  ].join(' · '),
                                  style: theme.textTheme.labelSmall,
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  DateTime _shiftMonth(int step) {
    final first = DateTime.utc(_selected.year, _selected.month + step, 1);
    final cap = DateTime.utc(first.year, first.month + 1, 0).day;
    return DateTime.utc(first.year, first.month, _selected.day.clamp(1, cap));
  }

  Widget _month(
    BuildContext context,
    Json data,
    List<Occurrence> items,
    List<DateTime> days,
    String Function(String, String) label,
    bool wide,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = AppScope.of(context).text;
    final arena = _arena(data);
    final leagues = (arena?['leagues'] as List?)?.cast<Json>() ?? const [];
    final bars = items.where((item) => item.kind != 'arena').toList()
      ..sort(
        (a, b) =>
            _barOrder.indexOf(_toneOf(a.kind)) -
            _barOrder.indexOf(_toneOf(b.kind)),
      );
    final weeks = [
      for (var w = 0; w < days.length ~/ 7; w++) days.sublist(w * 7, w * 7 + 7),
    ].where((week) => week.any((d) => d.month == _selected.month)).toList();
    final seen = <int>{
      for (final date in days)
        for (final rule in _rulesOn(arena, date))
          if (((rule as Map?)?['missions'] as List?)?.firstOrNull
              case final int id)
            id,
    }.toList()..sort();
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Corner.extraLarge),
      ),
      child: Column(
        spacing: 2,
        children: [
          SizedBox(
            height: 28,
            child: Row(
              children: [
                for (final date in days.take(7))
                  Expanded(
                    child: Center(
                      child: Text(
                        DateFormat.E(t.locale).format(date),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          for (final week in weeks)
            Builder(
              builder: (context) {
                final segments = _segments(bars, week);
                final hasArena = week.any(
                  (date) => _rulesOn(arena, date).isNotEmpty,
                );
                final head = wide ? (hasArena ? 80.0 : 44.0) : 46.0;
                final lane = wide ? 22.0 : 6.0;
                final height = head + lane * 3 + (wide ? 18 : 6);
                return SizedBox(
                  height: height,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final cell = constraints.maxWidth / 7;
                      return Stack(
                        children: [
                          Row(
                            spacing: 0,
                            children: [
                              for (final date in week)
                                Expanded(
                                  child: _Cell(
                                    date: date,
                                    other: date.month != _selected.month,
                                    selected: date == _selected,
                                    today: date == _today,
                                    wide: wide,
                                    arena: arena,
                                    rules: _rulesOn(arena, date),
                                    leagues: leagues,
                                    overflow: segments
                                        .where(
                                          (s) => s.lane >= 3 && s.item.on(date),
                                        )
                                        .length,
                                    mark: _mark,
                                    missionImage: _missionImage,
                                    onTap: () =>
                                        setState(() => _selected = date),
                                  ),
                                ),
                            ],
                          ),
                          for (final segment in segments)
                            if (segment.lane < 3)
                              Positioned(
                                left: segment.column * cell + 2,
                                width: segment.span * cell - 4,
                                top: head + segment.lane * lane,
                                height: wide ? lane - 1 : 4,
                                child: IgnorePointer(
                                  child: _Bar(
                                    segment: segment,
                                    t: t,
                                    wide: wide,
                                  ),
                                ),
                              ),
                        ],
                      );
                    },
                  ),
                );
              },
            ),
          if (arena != null && seen.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: Wrap(
                spacing: 16,
                runSpacing: 4,
                children: [
                  for (final id in seen)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 6,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _missionColor(scheme, id),
                          ),
                        ),
                        _mark(
                          _missionImage(arena, {
                            'missions': [id],
                          }),
                          16,
                        ),
                        Text(
                          _mission({
                            'missions': [id],
                          }),
                          style: theme.textTheme.labelMedium,
                        ),
                      ],
                    ),
                ],
              ),
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
    final format = SiteDate.day(t.locale).withTime();
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

const _barOrder = ['event', 'gacha', 'live', 'birthday', 'other'];
String _toneOf(String kind) => kind == 'character' || kind == 'cast'
    ? 'birthday'
    : kind == 'live' || kind == 'game-live'
    ? 'live'
    : kind == 'gacha'
    ? 'gacha'
    : kind == 'event'
    ? 'event'
    : 'other';
(Color, Color, Color) _tone(ColorScheme scheme, String kind) => switch (_toneOf(
  kind,
)) {
  'event' => (
    scheme.primaryContainer,
    scheme.onPrimaryContainer,
    scheme.primary,
  ),
  'gacha' => (
    scheme.tertiaryContainer,
    scheme.onTertiaryContainer,
    scheme.tertiary,
  ),
  'birthday' => (scheme.errorContainer, scheme.onErrorContainer, scheme.error),
  'live' => (
    scheme.secondaryContainer,
    scheme.onSecondaryContainer,
    scheme.secondary,
  ),
  _ => (
    scheme.surfaceContainerHighest,
    scheme.onSurfaceVariant,
    scheme.outline,
  ),
};
Color _missionColor(ColorScheme scheme, Object? mission) => switch (mission) {
  1 => scheme.primary,
  2 => scheme.tertiary,
  3 => scheme.error,
  _ => scheme.outline,
};

class _Cell extends StatelessWidget {
  const _Cell({
    required this.date,
    required this.other,
    required this.selected,
    required this.today,
    required this.wide,
    required this.arena,
    required this.rules,
    required this.leagues,
    required this.overflow,
    required this.mark,
    required this.missionImage,
    required this.onTap,
  });
  final DateTime date;
  final bool other, selected, today, wide;
  final Json? arena;
  final List<Object?> rules;
  final List<Json> leagues;
  final int overflow;
  final Widget Function(String?, double) mark;
  final String? Function(Json, Object?) missionImage;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final faded = other ? 0.45 : 1.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Material(
        color: selected
            ? scheme.secondaryContainer
            : other
            ? Colors.transparent
            : scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(Corner.medium),
        child: InkWell(
          borderRadius: BorderRadius.circular(Corner.medium),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              crossAxisAlignment: wide
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.center,
              spacing: 4,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: today
                      ? BoxDecoration(
                          color: scheme.primary,
                          shape: BoxShape.circle,
                        )
                      : null,
                  child: Text(
                    '${date.day}',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: today
                          ? scheme.onPrimary
                          : other
                          ? scheme.onSurfaceVariant
                          : null,
                    ),
                  ),
                ),
                if (rules.isNotEmpty && arena != null)
                  Opacity(
                    opacity: faded,
                    child: wide
                        ? Row(
                            children: [
                              for (final (index, rule) in rules.indexed)
                                Expanded(
                                  child: rule == null || index >= leagues.length
                                      ? const SizedBox.shrink()
                                      : Column(
                                          spacing: 2,
                                          children: [
                                            mark(
                                              '${leagues[index]['image']}',
                                              16,
                                            ),
                                            mark(
                                              missionImage(arena!, rule),
                                              16,
                                            ),
                                          ],
                                        ),
                                ),
                            ],
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            spacing: 2,
                            children: [
                              for (final rule in rules)
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _missionColor(
                                      scheme,
                                      ((rule as Map?)?['missions'] as List?)
                                          ?.firstOrNull,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                  ),
                if (wide && overflow > 0) ...[
                  const Spacer(),
                  Text(
                    '+$overflow',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.segment, required this.t, required this.wide});
  final _Segment segment;
  final SiteText t;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final (background, foreground, solid) = _tone(
      Theme.of(context).colorScheme,
      segment.item.kind,
    );
    final title = t.text(
      segment.item.source['title'] ?? segment.item.source['name'],
    );
    const radius = Radius.circular(Corner.small);
    return Container(
      padding: wide ? const EdgeInsets.symmetric(horizontal: 6) : null,
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: wide ? background : solid,
        borderRadius: BorderRadius.horizontal(
          left: segment.before ? Radius.zero : radius,
          right: segment.after ? Radius.zero : radius,
        ),
      ),
      child: wide
          ? Text(
              title,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: foreground),
            )
          : null,
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
                        candidates: [
                          CatalogSourceScope.apiOf(context)
                              .asset(image)
                              .toString(),
                        ],
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
