import 'dart:async';

import 'package:flutter/material.dart';

import '../controller/app_controller.dart';
import '../model/recording_info.dart';
import 'note_list.dart';
import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';
import 'widgets/edge_state.dart';

/// Every note, newest first, transcript first - `AllNotes.dc.html`.
///
/// Rows quote what was said, or say where the transcript stands. Search looks
/// through every transcript and the times. Deleting lives on the note itself,
/// so a mis-tap here can only ever open something.
class AllNotesView extends StatefulWidget {
  const AllNotesView({
    required this.controller,
    required this.onOpen,
    this.onBack,
    this.now,
    super.key,
  });

  final AppController controller;
  final ValueChanged<RecordingInfo> onOpen;
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

  AppController get _controller => widget.controller;

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
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final all = _items;
    final matches = NoteList.filter(all, _query);
    final groups = NoteList.group(matches, now: widget.now ?? DateTime.now());

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
                '${all.length} ${all.length == 1 ? 'note' : 'notes'}',
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
            _SearchField(controller: _search, onChanged: _onQueryChanged),
            const SizedBox(height: 22),
            Expanded(
              child: matches.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('No notes match', style: AppText.meta13),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: groups.length,
                      itemBuilder: (context, index) => _GroupSection(
                        group: groups[index],
                        onOpen: widget.onOpen,
                      ),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

class _GroupSection extends StatelessWidget {
  const _GroupSection({required this.group, required this.onOpen});

  final NoteGroup group;
  final ValueChanged<RecordingInfo> onOpen;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SectionCaption(group.label),
          const SizedBox(height: 8),
          for (var i = 0; i < group.items.length; i++)
            _NoteRow(
              item: group.items[i],
              last: i == group.items.length - 1,
              onTap: () => onOpen(group.items[i].recording),
            ),
        ],
      ),
    );
  }
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
