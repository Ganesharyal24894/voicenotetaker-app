import 'package:flutter/material.dart';

import 'recording_entry.dart';
import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';

/// Screen 4 - the recordings library.
///
/// [entries] are supplied by the caller: the app passes any real finished
/// recording plus `PlaceholderData.library`, because nothing enumerates saved
/// files yet.
class LibraryView extends StatefulWidget {
  const LibraryView({
    required this.entries,
    required this.onOpen,
    required this.onNewRecording,
    this.onBack,
    super.key,
  });

  final List<RecordingEntry> entries;
  final ValueChanged<RecordingEntry> onOpen;
  final VoidCallback onNewRecording;
  final VoidCallback? onBack;

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
      groups.putIfAbsent(entry.dayLabel(), () => <RecordingEntry>[]).add(entry);
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final matches = _matches;
    final groups = _grouped(matches);

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
                    ),
                  const SizedBox(height: 18),
                ],
                if (matches.isEmpty)
                  Text(
                    _search.text.isEmpty
                        ? 'No recordings yet.'
                        : 'Nothing matches “${_search.text}”.',
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
  });

  final RecordingEntry entry;
  final bool lastInGroup;
  final VoidCallback onTap;

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
