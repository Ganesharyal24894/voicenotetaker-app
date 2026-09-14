import 'dart:async';

import 'package:flutter/material.dart';

import '../../controller/summary_controller.dart';
import '../../model/recording_info.dart';
import '../../model/summary/day_summary.dart';
import '../../model/summary/note_time.dart';
import '../../model/summary/note_time_matcher.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import '../widgets/home_icons.dart';
import '../widgets/home_widgets.dart';
import 'home_format.dart';

/// The Today tab: what your AI made of your day, to-dos first.
///
/// Calm by construction, in the manner of Things and Todoist: open to-dos lead;
/// a ticked one settles for a moment - so the tick is seen - and then folds
/// into "Done (n)" at the bottom; everything the AI said beyond to-dos, waiting
/// and decisions sits behind one "More from your AI". With no summary yet the
/// tab is the three steps that make one.
class TodayTab extends StatefulWidget {
  const TodayTab({
    required this.summaries,
    required this.recordings,
    required this.onOpenRecording,
    required this.onSummarize,
    required this.onPaste,
    super.key,
  });

  final SummaryController summaries;

  /// Every saved recording; note-time chips are matched against these.
  final List<RecordingInfo> recordings;
  final ValueChanged<RecordingInfo> onOpenRecording;
  final VoidCallback onSummarize;
  final VoidCallback onPaste;

  /// How long a just-ticked to-do stays in place before it folds into Done.
  static const Duration settle = Duration(milliseconds: 700);

  /// Decisions shown before "Show all".
  static const int decisionsShown = 2;

  static const String noteNotFound = "Couldn't find that note. It may have been deleted.";

  @override
  State<TodayTab> createState() => _TodayTabState();
}

/// Half the screen gutter - see the list in [_TodayTabState._content].
const double _half = AppShape.gutter / 2;

/// Puts [child] back on the gutter inside the half-inset list. Rows with a
/// note-time chip keep 6px less on the right, where the chip's target sits.
Widget _inset(Widget child, {double right = _half}) =>
    Padding(padding: EdgeInsets.only(left: _half, right: right), child: child);

class _TodayTabState extends State<TodayTab> {
  final Map<String, Timer> _settling = <String, Timer>{};
  bool _showDone = false;
  bool _allDecisions = false;
  bool _more = false;
  bool _summaryOpen = false;

  @override
  void dispose() {
    for (final timer in _settling.values) {
      timer.cancel();
    }
    super.dispose();
  }

  void _toggle(SummaryItem todo, bool done) {
    unawaited(widget.summaries.setDone(todo, done));
    _settling.remove(todo.key)?.cancel();
    if (done && !AppMotion.isReduced(context)) {
      _settling[todo.key] = Timer(TodayTab.settle, () {
        if (mounted) setState(() => _settling.remove(todo.key));
      });
    }
    setState(() {});
  }

  void _openNote(DaySummary summary, NoteTime time) {
    final recording = NoteTimeMatcher.match(
      time: time,
      window: summary.window,
      recordings: widget.recordings,
    );
    if (recording == null) {
      showHomeMessage(context, TodayTab.noteNotFound);
      return;
    }
    widget.onOpenRecording(recording);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.summaries,
      builder: (context, _) {
        final summary = widget.summaries.latest;
        if (summary == null) {
          return TodayEmpty(onSummarize: widget.onSummarize, onPaste: widget.onPaste);
        }
        return _content(context, summary);
      },
    );
  }

  Widget _content(BuildContext context, DaySummary summary) {
    final now = widget.summaries.now;
    final todos = summary.todos;
    final open = todos.where((t) => !t.done || _settling.containsKey(t.key)).toList();
    final done = todos.where((t) => t.done && !_settling.containsKey(t.key)).toList();
    final openCount = todos.where((t) => !t.done).length;
    final waiting = summary.itemsOf(SummarySection.waiting);
    final decisions = summary.itemsOf(SummarySection.decisions);
    final shownDecisions = _allDecisions ? decisions : decisions.take(TodayTab.decisionsShown).toList();
    const moreSections = <SummarySection>[
      SummarySection.workDone,
      SummarySection.people,
      SummarySection.ideas,
      SummarySection.openQuestions,
      SummarySection.patterns,
    ];
    final more = moreSections.where((s) => summary.itemsOf(s).isNotEmpty).toList();

    Widget chipFor(SummaryItem item) => item.noteTime == null
        ? const SizedBox(width: 50)
        : NoteTimeChip(label: item.noteTime!.clock, onTap: () => _openNote(summary, item.noteTime!));

    // The list is inset by HALF the gutter, not the whole of it: a to-do's
    // checkbox has a 44px target whose box sits on the gutter, and the 12px
    // left of the box must still be inside the list to take a tap. Everything
    // else is padded back onto the gutter with [_inset].
    return ListView(
      padding: const EdgeInsets.fromLTRB(_half, 0, _half, 24),
      children: <Widget>[
        _inset(_SummaryCard(
          summary: summary,
          now: now,
          open: _summaryOpen,
          onToggleOpen: () => setState(() => _summaryOpen = !_summaryOpen),
          onSummarize: widget.onSummarize,
          onPaste: widget.onPaste,
        )),
        if (todos.isNotEmpty) ...<Widget>[
          const SizedBox(height: 18),
          _inset(HomeSectionHeader('To-do', count: openCount == 0 ? 'all done' : '$openCount open')),
          for (var i = 0; i < open.length; i++)
            _TodoRow(
              key: ValueKey<String>('todo-${open[i].key}'),
              item: open[i],
              divider: i > 0,
              onChanged: (value) => _toggle(open[i], value),
              chip: chipFor(open[i]),
            ),
          if (done.isNotEmpty) ...<Widget>[
            _inset(_DisclosureRow(
              label: 'Done (${done.length})',
              open: _showDone,
              onTap: () => setState(() => _showDone = !_showDone),
            )),
            if (_showDone)
              for (var i = 0; i < done.length; i++)
                _TodoRow(
                  key: ValueKey<String>('done-${done[i].key}'),
                  item: done[i],
                  divider: i > 0,
                  onChanged: (value) => _toggle(done[i], value),
                  chip: chipFor(done[i]),
                ),
          ],
        ],
        if (waiting.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          _inset(HomeSectionHeader('Waiting on others', count: '${waiting.length}')),
          for (var i = 0; i < waiting.length; i++)
            _inset(_ItemRow(item: waiting[i], meta: HomeFormat.whoAndDue(waiting[i]), divider: i > 0, chip: chipFor(waiting[i])), right: 6),
        ],
        if (decisions.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          _inset(HomeSectionHeader(
            'Decisions',
            trailing: decisions.length > TodayTab.decisionsShown
                ? LinkAction(
                    label: _allDecisions ? 'Show fewer' : 'Show all ${decisions.length}',
                    onTap: () => setState(() => _allDecisions = !_allDecisions),
                  )
                : null,
          )),
          for (var i = 0; i < shownDecisions.length; i++)
            _inset(_ItemRow(item: shownDecisions[i], divider: i > 0, chip: chipFor(shownDecisions[i])), right: 6),
        ],
        if (more.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          _inset(HomeSectionHeader(
            'More from your AI',
            trailing: LinkAction(label: _more ? 'Hide' : 'Show', onTap: () => setState(() => _more = !_more)),
          )),
          if (_more)
            for (final section in more) ...<Widget>[
              _inset(Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 2),
                child: Text(section.heading, style: AppText.label13),
              )),
              for (var i = 0; i < summary.itemsOf(section).length; i++)
                _inset(_ItemRow(
                  item: summary.itemsOf(section)[i],
                  divider: i > 0,
                  wrap: true,
                  chip: chipFor(summary.itemsOf(section)[i]),
                ), right: 6),
            ],
        ],
      ],
    );
  }
}

/// "Your day" - the AI's paragraph, where it came from, and the two actions.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.summary,
    required this.now,
    required this.open,
    required this.onToggleOpen,
    required this.onSummarize,
    required this.onPaste,
  });

  final DaySummary summary;
  final DateTime now;
  final bool open;
  final VoidCallback onToggleOpen;
  final VoidCallback onSummarize;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    final stale = summary.isStaleAt(now);
    final paragraph = HomeFormat.summaryParagraph(summary.itemsOf(SummarySection.summary));
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 24),
            child: Row(
              children: <Widget>[
                SectionCaption(HomeFormat.summaryCaption(summary.range), small: true),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      const HomeIcon(HomeGlyph.checkCircle, size: 13, color: AppColors.textTertiary, strokeWidth: 1.8),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          HomeFormat.provenance(summary, now),
                          style: AppText.meta12,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (paragraph.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onToggleOpen,
              child: Text(
                paragraph,
                maxLines: open ? null : 4,
                overflow: open ? TextOverflow.visible : TextOverflow.ellipsis,
                style: AppText.body13.copyWith(fontSize: 14, height: 1.55, color: AppColors.textPrimary),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Container(
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.raised))),
            child: Row(
              children: <Widget>[
                Flexible(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: LinkAction(
                      // A summary from an earlier day stays useful - its to-dos
                      // are still yours - but it is not today's, so the card
                      // nudges rather than hiding it.
                      label: stale ? 'Summarize today' : 'Summarize with your AI',
                      glyph: HomeGlyph.lines,
                      color: stale ? AppColors.purpleText : AppColors.textSecondary,
                      onTap: onSummarize,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                // Rigid: short, and the one action a returning user taps.
                LinkAction(
                  label: 'Paste AI reply',
                  glyph: HomeGlyph.copy,
                  glyphSize: 14,
                  glyphGap: 6,
                  color: stale ? AppColors.textSecondary : AppColors.purpleText,
                  onTap: onPaste,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TodoRow extends StatelessWidget {
  const _TodoRow({
    required this.item,
    required this.divider,
    required this.onChanged,
    required this.chip,
    super.key,
  });

  final SummaryItem item;
  final bool divider;
  final ValueChanged<bool> onChanged;
  final Widget chip;

  @override
  Widget build(BuildContext context) {
    final meta = HomeFormat.whoAndDue(item);
    // The divider runs from the gutter, not from the checkbox's target.
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Stack(
        children: <Widget>[
          if (divider)
            const Positioned(
              left: _half,
              right: 0,
              top: 0,
              child: Divider(height: 1, thickness: 1, color: AppColors.raised),
            ),
          Container(
            constraints: const BoxConstraints(minHeight: AppShape.minTapTarget),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: <Widget>[
                TodoCheckbox(checked: item.done, onChanged: onChanged, semanticLabel: item.text),
                const SizedBox(width: 2),
                Expanded(child: _TwoLines(title: item.text, meta: meta, struck: item.done)),
                chip,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.item,
    required this.divider,
    required this.chip,
    this.meta,
    this.wrap = false,
  });

  final SummaryItem item;
  final String? meta;
  final bool divider;
  final Widget chip;
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: AppShape.minTapTarget),
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        border: divider ? const Border(top: BorderSide(color: AppColors.raised)) : null,
      ),
      child: Row(
        children: <Widget>[
          Expanded(child: _TwoLines(title: item.text, meta: meta, wrap: wrap)),
          const SizedBox(width: 10),
          chip,
        ],
      ),
    );
  }
}

class _TwoLines extends StatelessWidget {
  const _TwoLines({required this.title, this.meta, this.struck = false, this.wrap = false});

  final String title;
  final String? meta;
  final bool struck;
  final bool wrap;

  static const TextStyle _title = TextStyle(
    fontFamily: AppText.family,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: AppColors.textPrimary,
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          title,
          maxLines: wrap ? null : 2,
          overflow: wrap ? null : TextOverflow.ellipsis,
          style: struck
              ? _title.copyWith(
                  color: AppColors.textTertiary,
                  decoration: TextDecoration.lineThrough,
                  decorationColor: AppColors.textTertiary,
                )
              : _title,
        ),
        if (meta != null) ...<Widget>[
          const SizedBox(height: 3),
          Text(meta!, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.meta12),
        ],
      ],
    );
  }
}

class _DisclosureRow extends StatelessWidget {
  const _DisclosureRow({required this.label, required this.open, required this.onTap});

  final String label;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      expanded: open,
      label: label,
      container: true,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: AppShape.minTapTarget,
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.raised))),
          child: Row(
            children: <Widget>[
              Text(label, style: AppText.label13),
              const SizedBox(width: 6),
              Transform.rotate(
                angle: open ? -1.5708 : 1.5708,
                child: const AppIcon(AppGlyph.chevronRight, size: 14, color: AppColors.textSecondary, strokeWidth: 1.7),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Today before the first summary: the three steps, and the two buttons that
/// take them.
class TodayEmpty extends StatelessWidget {
  const TodayEmpty({required this.onSummarize, required this.onPaste, super.key});

  final VoidCallback onSummarize;
  final VoidCallback onPaste;

  static const String title = "Turn today's talk into to-dos";

  static const List<(String, String)> steps = <(String, String)>[
    ('Tap Summarize with your AI', "Copies one prompt with today's notes."),
    ('Paste it into your AI app', 'ChatGPT, Claude or Gemini — any chat works.'),
    ('Copy its reply, then tap Paste AI reply', 'Your to-dos and decisions show up here.'),
  ];

  @override
  Widget build(BuildContext context) {
    // The two buttons stay pinned under the steps rather than scrolling with
    // them, so on a short screen the next step is always in reach.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppShape.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const SizedBox(height: 8),
                  Text(title, style: AppText.title24.copyWith(height: 1.3)),
                  const SizedBox(height: 10),
                  Text(
                    'This app writes down what you say, offline. Your own AI app turns it into to-dos. Takes about a minute.',
                    style: AppText.body13.copyWith(fontSize: 14, height: 1.55),
                  ),
                  const SizedBox(height: 16),
                  AppCard(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                    child: Column(
                      children: <Widget>[
                        for (var i = 0; i < steps.length; i++) _step(i),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Row(
                    children: <Widget>[
                      AppIcon(AppGlyph.lock, size: 14, color: AppColors.textTertiary, strokeWidth: 1.7),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text('Notes leave this phone only when you paste them.', style: AppText.meta12),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
          SheetButton(label: 'Summarize with your AI', glyph: HomeGlyph.lines, onPressed: onSummarize),
          const SizedBox(height: 10),
          SheetButton(label: 'Paste AI reply', glyph: HomeGlyph.copy, filled: false, onPressed: onPaste),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _step(int i) => Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: i == 0 ? null : const Border(top: BorderSide(color: AppColors.raised)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0x246D28D9),
                border: Border.all(color: AppColors.purpleChipBorder),
              ),
              alignment: Alignment.center,
              child: Text(
                '${i + 1}',
                style: AppText.label13.copyWith(fontWeight: FontWeight.w500, color: AppColors.purpleText),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(steps[i].$1, style: AppText.rowTitle),
                    const SizedBox(height: 4),
                    Text(steps[i].$2, style: AppText.meta13.copyWith(height: 1.5)),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
}
