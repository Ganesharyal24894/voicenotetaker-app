import 'package:flutter/material.dart';

import '../model/note_days.dart';
import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';
import 'widgets/home_widgets.dart';

/// Pick the days you want to see - `NotesCalendar.dc.html`.
///
/// Returns the days to show, or null when the sheet was dismissed without
/// deciding. An EMPTY set is a real answer: it means "every day", which is
/// what Clear sends back.
Future<Set<DateTime>?> showNotesCalendarSheet(
  BuildContext context, {
  required NoteDayIndex index,
  required Set<DateTime> selected,
  required DateTime now,
}) {
  return showHomeSheet<Set<DateTime>>(
    context,
    builder: (context) => NotesCalendarSheet(
      index: index,
      selected: selected,
      now: now,
    ),
  );
}

/// A month at a time. A day with notes carries a dot and can be tapped; a day
/// without is greyed and does nothing. Tapping toggles, so days add up.
class NotesCalendarSheet extends StatefulWidget {
  const NotesCalendarSheet({
    required this.index,
    required this.selected,
    required this.now,
    super.key,
  });

  /// How many notes each day holds.
  final NoteDayIndex index;

  /// The days already picked, so the sheet opens where the user left it.
  final Set<DateTime> selected;

  final DateTime now;

  /// Monday first, as the design draws it.
  static const List<String> weekdayInitials = <String>[
    'M',
    'T',
    'W',
    'T',
    'F',
    'S',
    'S',
  ];

  static const List<String> monthNames = <String>[
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  @override
  State<NotesCalendarSheet> createState() => _NotesCalendarSheetState();
}

class _NotesCalendarSheetState extends State<NotesCalendarSheet> {
  late final Set<DateTime> _picked = <DateTime>{...widget.selected};

  /// The month on screen, as its first day.
  late DateTime _month = _openingMonth();

  /// Where the calendar opens: the month of the newest day already picked,
  /// else the month that holds the newest note, else this month. Coming back
  /// to a filter you set last week should not start in today's month.
  DateTime _openingMonth() {
    final newestPicked = widget.selected.isEmpty
        ? null
        : (widget.selected.toList()..sort()).last;
    final at = newestPicked ?? widget.index.newestDay ?? widget.now;
    return DateTime(at.year, at.month);
  }

  /// The last month worth showing: no note can be recorded later than the
  /// newest one there is, or later than now.
  DateTime get _lastMonth {
    final newest = widget.index.newestDay;
    final now = DateTime(widget.now.year, widget.now.month);
    if (newest == null) return now;
    final month = DateTime(newest.year, newest.month);
    return month.isAfter(now) ? month : now;
  }

  bool get _canGoForward => _month.isBefore(_lastMonth);

  void _step(int months) {
    setState(() => _month = DateTime(_month.year, _month.month + months));
  }

  void _toggle(DateTime day) {
    setState(() {
      if (!_picked.remove(day)) _picked.add(day);
    });
  }

  @override
  Widget build(BuildContext context) {
    final shown = widget.index.countForAll(_picked);
    final bare = !widget.index.hasMonth(_month);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Transform.translate(
              offset: const Offset(-10, 0),
              child: TapTarget(
                onTap: () => _step(-1),
                semanticLabel: 'Previous month',
                child: const AppIcon(
                  AppGlyph.chevronLeft,
                  size: 20,
                  color: AppColors.textSecondary,
                  strokeWidth: 1.7,
                ),
              ),
            ),
            Expanded(
              child: Text(
                _monthLabel(_month),
                textAlign: TextAlign.center,
                style: AppText.rowTitle.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
            Transform.translate(
              offset: const Offset(10, 0),
              child: TapTarget(
                onTap: _canGoForward ? () => _step(1) : null,
                semanticLabel: 'Next month',
                child: AppIcon(
                  AppGlyph.chevronRight,
                  size: 20,
                  color: _canGoForward
                      ? AppColors.textSecondary
                      : AppColors.waveFloor,
                  strokeWidth: 1.7,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            for (final initial in NotesCalendarSheet.weekdayInitials)
              Expanded(
                child: Text(
                  initial,
                  textAlign: TextAlign.center,
                  style: AppText.captionSmall,
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        _MonthGrid(
          month: _month,
          index: widget.index,
          picked: _picked,
          onToggle: _toggle,
        ),
        if (bare) ...<Widget>[
          const SizedBox(height: 10),
          const Text(
            'No notes this month.',
            textAlign: TextAlign.center,
            style: AppText.meta13,
          ),
        ],
        const SizedBox(height: 14),
        Row(
          children: <Widget>[
            if (_picked.isNotEmpty) ...<Widget>[
              Semantics(
                button: true,
                label: 'Clear',
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () =>
                      Navigator.of(context).pop(const <DateTime>{}),
                  child: Container(
                    constraints: const BoxConstraints(
                      minHeight: AppShape.minTapTarget,
                    ),
                    padding: const EdgeInsets.only(right: 4),
                    alignment: Alignment.center,
                    child: const Text('Clear', style: AppText.label13),
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: SheetButton(
                label: _picked.isEmpty
                    ? 'Show all notes'
                    : 'Show $shown ${shown == 1 ? 'note' : 'notes'}',
                onPressed: () =>
                    Navigator.of(context).pop(<DateTime>{..._picked}),
              ),
            ),
          ],
        ),
      ],
    );
  }

  static String _monthLabel(DateTime month) =>
      '${NotesCalendarSheet.monthNames[month.month - 1]} ${month.year}';
}

/// Seven columns, Monday first, with the leading blanks a month starts on.
class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.index,
    required this.picked,
    required this.onToggle,
  });

  final DateTime month;
  final NoteDayIndex index;
  final Set<DateTime> picked;
  final ValueChanged<DateTime> onToggle;

  @override
  Widget build(BuildContext context) {
    final first = DateTime(month.year, month.month);
    // `weekday` is 1 for Monday, so this is how many blanks come first.
    final lead = first.weekday - 1;
    final length = DateTime(month.year, month.month + 1, 0).day;
    final cells = <Widget>[
      for (var i = 0; i < lead; i++) const SizedBox.shrink(),
      for (var day = 1; day <= length; day++)
        Builder(
          builder: (context) {
            final at = DateTime(month.year, month.month, day);
            return _DayCell(
              day: day,
              count: index.countFor(at),
              picked: picked.contains(at),
              onTap: index.has(at) ? () => onToggle(at) : null,
            );
          },
        ),
    ];
    // Whole weeks, so the grid does not change height month to month.
    while (cells.length % 7 != 0) {
      cells.add(const SizedBox.shrink());
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var row = 0; row < cells.length ~/ 7; row++)
          Row(
            children: <Widget>[
              for (var column = 0; column < 7; column++)
                Expanded(child: cells[row * 7 + column]),
            ],
          ),
      ],
    );
  }
}

/// One day: the number, a purple dot when it holds notes, a filled circle
/// when it is picked, and grey and dead when it holds nothing.
class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.count,
    required this.picked,
    required this.onTap,
  });

  final int day;
  final int count;
  final bool picked;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final has = count > 0;
    final number = Text(
      '$day',
      style: AppText.rowTitle.copyWith(
        height: 1,
        color: has ? AppColors.textPrimary : AppColors.waveFloor,
      ),
    );

    return Semantics(
      button: onTap != null,
      selected: picked,
      enabled: onTap != null,
      label: has
          ? '$day, $count ${count == 1 ? 'note' : 'notes'}'
          : '$day, no notes',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: picked
              ? Center(
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: const BoxDecoration(
                      color: AppColors.primaryFill,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: number,
                  ),
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    number,
                    const SizedBox(height: 4),
                    SizedBox.square(
                      dimension: 4,
                      child: has
                          ? const DecoratedBox(
                              decoration: BoxDecoration(
                                color: AppColors.purpleText,
                                shape: BoxShape.circle,
                              ),
                            )
                          : null,
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
