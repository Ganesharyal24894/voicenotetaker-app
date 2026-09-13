import 'dart:async';

import 'package:flutter/material.dart';

import 'recording_entry.dart';
import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';
import 'widgets/edge_state.dart';

/// Screen 4 - the recordings library.
///
/// [entries] are supplied by the caller: the app passes the saved recordings
/// the library service found.
class LibraryView extends StatefulWidget {
  const LibraryView({
    required this.entries,
    required this.onOpen,
    required this.onNewRecording,
    this.onDelete,
    this.onBack,
    this.now,
    super.key,
  });

  final List<RecordingEntry> entries;
  final ValueChanged<RecordingEntry> onOpen;
  final VoidCallback onNewRecording;

  /// Deletes one recording. The view CONFIRMS first and only calls this on a
  /// yes; the deletion itself is the service layer's, reached through the
  /// controller - nothing here touches a file.
  ///
  /// Null leaves the rows with no delete control at all, which is what a
  /// caller that has no controller to delete through should pass.
  final ValueChanged<RecordingEntry>? onDelete;

  final VoidCallback? onBack;

  /// "Today"/"Yesterday" are relative to this, defaulting to the wall clock.
  /// Injectable so a test can pin the day: without it these headers change
  /// meaning at midnight, and a test asserting "TODAY" passes only on the
  /// day it was written.
  final DateTime? now;

  @override
  State<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<LibraryView> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<RecordingEntry> get _matches {
    final query = _search.text.trim().toLowerCase();
    final sorted = <RecordingEntry>[...widget.entries]
      ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
    if (query.isEmpty) return sorted;
    return sorted
        .where((e) => e.title.toLowerCase().contains(query))
        .toList();
  }

  /// Day label -> rows, in the order the rows appear.
  Map<String, List<RecordingEntry>> _grouped(List<RecordingEntry> entries) {
    final groups = <String, List<RecordingEntry>>{};
    for (final entry in entries) {
      groups.putIfAbsent(entry.dayLabel(now: widget.now), () => <RecordingEntry>[]).add(entry);
    }
    return groups;
  }

  /// Asks before deleting, and NAMES the recording while asking.
  ///
  /// Deletion is permanent - the file goes, and there is no copy on the
  /// recorder - so a mis-tap on a 44px row must not be able to destroy a
  /// recording on its own. The dialog itself is
  /// [confirmDeleteRecording], shared with the playback screen.
  Future<void> _confirmDelete(
    BuildContext context,
    RecordingEntry entry,
  ) async {
    final onDelete = widget.onDelete;
    if (onDelete == null) return;

    final confirmed = await confirmDeleteRecording(
      context,
      what: entry.title,
      // The day and the length: enough to be sure it is the right one
      // without leaving the dialog.
      detail: '${entry.dayLabel(now: widget.now)}, ${entry.durationLabel}',
    );
    if (confirmed) onDelete(entry);
  }

  @override
  Widget build(BuildContext context) {
    final matches = _matches;
    final groups = _grouped(matches);
    // No recordings AT ALL is a different thing from a search that matched
    // nothing, and only the first one gets the invitation below.
    final empty = widget.entries.isEmpty;

    return ScreenScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              if (widget.onBack != null) ...<Widget>[
                TapTarget(
                  onTap: widget.onBack,
                  semanticLabel: 'Back',
                  child: const AppIcon(
                    AppGlyph.chevronLeft,
                    size: 20,
                    color: AppColors.textSecondary,
                    strokeWidth: 1.7,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              const Expanded(
                child: Text(
                  'Recordings',
                  style: AppText.h1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${widget.entries.length} '
                '${widget.entries.length == 1 ? 'item' : 'items'}',
                style: AppText.meta13,
              ),
            ],
          ),
          if (empty)
            // AN INVITATION, NOT AN APOLOGY. Purple, because nothing has gone
            // wrong: a library with no recordings in it is what a new app
            // looks like. There is no search field either - there is nothing
            // to search - and the call to action is the only one on screen
            // rather than being repeated at the bottom.
            Expanded(
              child: EdgeState(
                glyph: AppGlyph.levels,
                tint: AppColors.purpleText,
                headline: 'No recordings yet',
                body: 'Notes you capture on the recorder show up here once '
                    'they sync.',
                primaryLabel: 'New recording',
                onPrimary: widget.onNewRecording,
              ),
            )
          else ...<Widget>[
            const SizedBox(height: 18),
            _SearchField(
              controller: _search,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 22),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: <Widget>[
                  for (final MapEntry<String, List<RecordingEntry>> group
                      in groups.entries) ...<Widget>[
                    SectionCaption(group.key),
                    const SizedBox(height: 8),
                    for (var i = 0; i < group.value.length; i++)
                      _LibraryRow(
                        entry: group.value[i],
                        lastInGroup: i == group.value.length - 1 &&
                            group.key == groups.keys.last,
                        onTap: () => widget.onOpen(group.value[i]),
                        // A row with no file behind it has nothing to delete,
                        // so it gets no delete control rather than a dead one.
                        onDelete: widget.onDelete == null ||
                                group.value[i].path == null
                            ? null
                            : () => unawaited(
                                  _confirmDelete(context, group.value[i]),
                                ),
                      ),
                    const SizedBox(height: 18),
                  ],
                  // Reachable only with a query in the field: an empty library
                  // took the branch above.
                  if (matches.isEmpty)
                    Text(
                      'Nothing matches “${_search.text}”.',
                      style: AppText.meta13,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            PrimaryButton(
              label: 'New recording',
              glyph: AppGlyph.mic,
              height: 50,
              borderRadius: AppShape.cta,
              onPressed: widget.onNewRecording,
            ),
          ],
        ],
      ),
    );
  }
}

/// 42px well with a 44px hit area, per the minimum-target rule.
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
                strokeWidth: 1.6,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: controller,
                  onChanged: onChanged,
                  cursorColor: AppColors.purpleText,
                  style: AppText.meta14
                      .copyWith(color: AppColors.textPrimary, height: 1.2),
                  decoration: InputDecoration.collapsed(
                    hintText: 'Search',
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

class _LibraryRow extends StatelessWidget {
  const _LibraryRow({
    required this.entry,
    required this.lastInGroup,
    required this.onTap,
    this.onDelete,
  });

  final RecordingEntry entry;
  final bool lastInGroup;
  final VoidCallback onTap;

  /// Null when this row cannot be deleted; the control is then absent.
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: AppShape.minTapTarget),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: Border(
            top: const BorderSide(color: AppColors.raised),
            bottom: lastInGroup
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
                  Text(entry.title, style: AppText.rowTitle),
                  const SizedBox(height: 4),
                  Text(entry.libraryLabel(), style: AppText.rowMeta),
                ],
              ),
            ),
            const SizedBox(width: 14),
            if (onDelete != null)
              // Inside the row's own gesture detector, but opaque, so a tap
              // on the bin deletes rather than opening the recording.
              TapTarget(
                onTap: onDelete,
                semanticLabel: 'Delete ${entry.title}',
                child: const AppIcon(
                  AppGlyph.trash,
                  size: 18,
                  color: AppColors.textTertiary,
                  strokeWidth: 1.6,
                ),
              ),
            const AppIcon(
              AppGlyph.chevronRight,
              size: 17,
              color: AppColors.textTertiary,
              strokeWidth: 1.6,
            ),
          ],
        ),
      ),
    );
  }
}
