import 'dart:async';

import 'package:flutter/material.dart';

import '../controller/app_controller.dart';
import '../controller/assistant_controller.dart';
import '../model/note_days.dart';
import '../model/recording_info.dart';
import 'note_list.dart';
import 'notes_calendar_sheet.dart';
import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';
import 'widgets/edge_state.dart';

/// Every note, newest first, transcript first - `AllNotes.dc.html` and
/// `canvas-notes/AllNotesDates.dc.html`.
///
/// Rows quote what was said, or say where the transcript stands. Search looks
/// through every transcript and the times; the calendar beside it picks the
/// days to show. Deleting lives on the note itself, so a mis-tap here can only
/// ever open something.
class AllNotesView extends StatefulWidget {
  const AllNotesView({
    required this.controller,
    required this.onOpen,
    this.assistant,
    this.onBack,
    this.now,
    super.key,
  });

  final AppController controller;

  /// Only so a row that was an instruction is quoted without the wake phrase
  /// in front of it. Null lists every note exactly as it was transcribed.
  final AssistantController? assistant;

  /// Opens one note, and hands over the list it was opened FROM - every row
  /// on screen, in the order they are shown. That list is what the note
  /// screen swipes through, so a note opened from a filtered list swipes
  /// through the filtered notes and nothing else.
  final void Function(RecordingInfo recording, List<RecordingInfo> shown)
      onOpen;

  final VoidCallback? onBack;

  /// Day headings are relative to this; the wall clock when null.
  final DateTime? now;

  /// Typing is let settle this long before the list is filtered again.
  static const Duration searchDebounce = Duration(milliseconds: 250);

  @override
  State<AllNotesView> createState() => _AllNotesViewState();
}

class _AllNotesViewState extends State<AllNotesView> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  String _query = '';

  /// The days picked in the calendar; empty is every day.
  ///
  /// It lives with the screen, so leaving All notes and coming back shows
  /// everything again. A filter you cannot see is a filter you forget about.
  Set<DateTime> _days = <DateTime>{};

  /// The day counts, and the listing they were counted from.
  ///
  /// [AppController.recordings] hands back the same list object until the
  /// library is re-read, so this rebuilds exactly when the library changes -
  /// never per frame, and never a stale count after a new note lands.
  List<RecordingInfo>? _countedFrom;
  NoteDayIndex _counts = NoteDayIndex.empty;

  AppController get _controller => widget.controller;

  DateTime get _now => widget.now ?? DateTime.now();

  NoteDayIndex get _dayCounts {
    final recordings = _controller.recordings;
    if (!identical(recordings, _countedFrom)) {
      _countedFrom = recordings;
      _counts = NoteDayIndex.of(recordings);
    }
    return _counts;
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    unawaited(_controller.loadTranscripts(_controller.recordings));
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    // A note that has just been transcribed, or has just appeared: read it.
    // Notifies only when there was something to read, so this cannot loop.
    unawaited(_controller.loadTranscripts(_controller.recordings));
    setState(() {});
  }

  void _onQueryChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(AllNotesView.searchDebounce, () {
      if (mounted) setState(() => _query = text);
    });
  }

  /// Opens the calendar and takes back whatever it decided. Dismissing it
  /// changes nothing.
  Future<void> _pickDays() async {
    final picked = await showNotesCalendarSheet(
      context,
      index: _dayCounts,
      selected: _days,
      now: _now,
    );
    if (picked == null || !mounted) return;
    setState(() => _days = picked);
  }

  void _dropDay(DateTime day) => setState(() => _days = <DateTime>{
        for (final picked in _days)
          if (picked != day) picked,
      });

  List<NoteListItem> get _items {
    final controller = _controller;
    final writing = controller.writingNotePath;
    final total = controller.transcriptionTotal;
    final progress = total == 0 ? 0.0 : controller.transcriptionDone / total;
    return <NoteListItem>[
      for (final recording in controller.recordings)
        NoteListItem.from(
          recording,
          status: controller.transcriptionAvailable || recording.hasTranscript
              ? controller.listTranscriptStatusFor(recording)
              : null,
          transcript: controller.transcriptFor(recording),
          isWriting: recording.path == writing,
          progress: progress,
          autoDeleteAudio: controller.autoDeleteAudio,
          quoteAs: widget.assistant?.titleFor,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final now = _now;
    final all = _items;
    // Days first, then search inside them: both are applied, always.
    final matches = NoteList.filter(all, _query, days: _days);
    final groups = NoteList.group(matches, now: now);
    final filtering = _days.isNotEmpty || _query.isNotEmpty;
    final shown = filtering ? matches.length : all.length;
    // What the note screen swipes through: these rows, in this order.
    final order = <RecordingInfo>[
      for (final item in matches) item.recording,
    ];

    return ScreenScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (widget.onBack != null)
            Transform.translate(
              offset: const Offset(-12, 0),
              child: TapTarget(
                onTap: widget.onBack,
                semanticLabel: 'Back',
                child: const AppIcon(
                  AppGlyph.chevronLeft,
                  size: 20,
                  color: AppColors.textSecondary,
                  strokeWidth: 1.7,
                ),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              const Expanded(child: Text('Notes', style: AppText.h1)),
              const SizedBox(width: 10),
              Text(
                '$shown ${shown == 1 ? 'note' : 'notes'}',
                style: AppText.meta13,
              ),
            ],
          ),
          if (all.isEmpty)
            const Expanded(
              child: EdgeState(
                glyph: AppGlyph.levels,
                tint: AppColors.purpleText,
                headline: 'No notes yet',
                body: 'Notes from your recorder show up here.',
              ),
            )
          else ...<Widget>[
            const SizedBox(height: 18),
            SizedBox(
              height: AppShape.minTapTarget,
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: _SearchField(
                      controller: _search,
                      onChanged: _onQueryChanged,
                    ),
                  ),
                  const SizedBox(width: 10),
                  _CalendarButton(
                    lit: _days.isNotEmpty,
                    onTap: () => unawaited(_pickDays()),
                  ),
                ],
              ),
            ),
            if (_days.isNotEmpty) ...<Widget>[
              const SizedBox(height: 14),
              _DayChips(days: _days, now: now, onDrop: _dropDay),
            ],
            SizedBox(height: _days.isEmpty ? 22 : 16),
            Expanded(
              child: matches.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('No notes match', style: AppText.meta13),
                    )
                  : CustomScrollView(
                      slivers: <Widget>[
                        for (final group in groups)
                          // Each day keeps its own heading: pinned while that
                          // day's rows are on screen, pushed off by the next.
                          SliverMainAxisGroup(
                            slivers: <Widget>[
                              SliverPersistentHeader(
                                pinned: true,
                                delegate: _DayHeading(group.heading),
                              ),
                              SliverList.builder(
                                itemCount: group.items.length,
                                itemBuilder: (context, i) => _NoteRow(
                                  item: group.items[i],
                                  last: i == group.items.length - 1,
                                  onTap: () => widget.onOpen(
                                    group.items[i].recording,
                                    order,
                                  ),
                                ),
                              ),
                              const SliverToBoxAdapter(
                                child: SizedBox(height: 22),
                              ),
                            ],
                          ),
                      ],
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

/// `TODAY · 12 NOTES`, pinned to the top of the list while that day runs.
class _DayHeading extends SliverPersistentHeaderDelegate {
  const _DayHeading(this.heading);

  final String heading;

  /// The caption plus the 8px the design leaves under it.
  static const double height = 28;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    return Container(
      // Opaque, so the rows scroll UNDER the heading rather than through it.
      color: AppColors.screen,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(bottom: 8),
      child: SectionCaption(heading),
    );
  }

  @override
  bool shouldRebuild(_DayHeading old) => old.heading != heading;
}

/// 42px well with a 44px hit area.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: AppShape.minTapTarget,
      child: Center(
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: AppColors.card,
            border: Border.all(color: AppColors.raised),
            borderRadius: AppShape.control,
          ),
          child: Row(
            children: <Widget>[
              const AppIcon(
                AppGlyph.search,
                size: 15,
                color: AppColors.textTertiary,
                strokeWidth: 1.7,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: controller,
                  onChanged: onChanged,
                  cursorColor: AppColors.purpleText,
                  textInputAction: TextInputAction.search,
                  style: AppText.meta14
                      .copyWith(color: AppColors.textPrimary, height: 1.2),
                  decoration: const InputDecoration.collapsed(
                    hintText: 'Search transcripts',
                    hintStyle: AppText.meta14,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The way into the calendar: a 42px square beside search, lit while days are
/// picked.
class _CalendarButton extends StatelessWidget {
  const _CalendarButton({required this.lit, required this.onTap});

  final bool lit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapTarget(
      onTap: onTap,
      semanticLabel: lit ? 'Change days' : 'Pick days',
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: lit ? AppColors.purpleChipFill : null,
          border: Border.all(
            color: lit ? AppColors.purpleChipBorder : AppColors.border,
          ),
          borderRadius: AppShape.control,
        ),
        child: Center(
          child: AppIcon(
            AppGlyph.calendar,
            size: 18,
            color: lit ? AppColors.purpleText : AppColors.textSecondary,
            strokeWidth: 1.7,
          ),
        ),
      ),
    );
  }
}

/// One chip per picked day, newest first, each with an x that drops it.
class _DayChips extends StatelessWidget {
  const _DayChips({
    required this.days,
    required this.now,
    required this.onDrop,
  });

  final Set<DateTime> days;
  final DateTime now;
  final ValueChanged<DateTime> onDrop;

  @override
  Widget build(BuildContext context) {
    final ordered = days.toList()..sort((a, b) => b.compareTo(a));
    return SizedBox(
      height: AppShape.minTapTarget,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: ordered.length,
        separatorBuilder: (context, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) => _DayChip(
          label: NoteLabels.group(ordered[i], now: now),
          onDrop: () => onDrop(ordered[i]),
        ),
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({required this.label, required this.onDrop});

  final String label;
  final VoidCallback onDrop;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Stop showing $label',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onDrop,
        child: Center(
          child: Container(
            height: 30,
            padding: const EdgeInsets.only(left: 12, right: 10),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.border),
              borderRadius: AppShape.pill,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(label, style: AppText.label13),
                const SizedBox(width: 7),
                const AppIcon(
                  AppGlyph.close,
                  size: 11,
                  color: AppColors.textTertiary,
                  strokeWidth: 2,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({required this.item, required this.last, required this.onTap});

  final NoteListItem item;
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final badge = item.badge;
    final accent = item.badgeKind == NoteBadgeKind.accent;
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: AppShape.minTapTarget),
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            border: Border(
              top: const BorderSide(color: AppColors.raised),
              bottom: last
                  ? const BorderSide(color: AppColors.raised)
                  : BorderSide.none,
            ),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      item.title,
                      style: AppText.rowTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            item.meta,
                            style: AppText.rowMeta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (badge != null) ...<Widget>[
                          const SizedBox(width: 8),
                          Container(
                            height: 22,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: accent ? AppColors.purpleChipFill : null,
                              border: Border.all(
                                color: accent
                                    ? AppColors.purpleChipBorder
                                    : AppColors.border,
                              ),
                              borderRadius: AppShape.pill,
                            ),
                            child: Text(
                              badge,
                              style: AppText.footnote11.copyWith(
                                height: 1.2,
                                fontWeight: FontWeight.w400,
                                color: accent
                                    ? AppColors.purpleText
                                    : AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              const AppIcon(
                AppGlyph.chevronRight,
                size: 17,
                color: AppColors.textTertiary,
                strokeWidth: 1.7,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
