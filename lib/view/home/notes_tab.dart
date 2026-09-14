import 'package:flutter/material.dart';

import '../../model/notes_overview.dart';
import '../../model/recording_info.dart';
import '../format.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import '../widgets/home_widgets.dart';
import 'home_format.dart';

/// The Notes tab: what needs you (only when something does), today in three
/// figures, and today's notes with where each one stands.
class NotesTab extends StatelessWidget {
  const NotesTab({
    required this.overview,
    required this.now,
    required this.onOpenRecording,
    required this.onOpenLibrary,
    super.key,
  });

  final NotesOverview overview;
  final DateTime now;
  final ValueChanged<RecordingInfo> onOpenRecording;
  final VoidCallback onOpenLibrary;

  @override
  Widget build(BuildContext context) {
    final failed = overview.failed;
    final soon = overview.audioDeletingSoon;
    return ListView(
      padding: const EdgeInsets.fromLTRB(AppShape.gutter, 0, AppShape.gutter, 24),
      children: <Widget>[
        if (overview.needsYou) ...<Widget>[
          const HomeSectionHeader('Needs you'),
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: <Widget>[
                if (soon.isNotEmpty)
                  _NeedsRow(
                    glyph: AppGlyph.trash,
                    color: AppColors.warning,
                    title: soon.length == 1 ? '1 note loses its audio soon' : '${soon.length} notes lose audio soon',
                    detail: 'At ${Fmt.timeOfDay(overview.firstAudioDeletion!)} · transcripts stay',
                    action: 'Review',
                    onTap: onOpenLibrary,
                    divider: false,
                  ),
                if (failed.isNotEmpty)
                  _NeedsRow(
                    glyph: AppGlyph.info,
                    color: AppColors.recording,
                    title: failed.length == 1
                        ? "1 note couldn't be transcribed"
                        : "${failed.length} notes couldn't be transcribed",
                    detail: failed.length == 1
                        ? _when(failed.first)
                        : 'Latest ${_when(failed.first)}',
                    action: failed.length == 1 ? 'Open' : 'Review',
                    onTap: failed.length == 1 ? () => onOpenRecording(failed.first) : onOpenLibrary,
                    divider: soon.isNotEmpty,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 18),
        ],
        const HomeSectionHeader('Today'),
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(flex: 13, child: _Figure(HomeFormat.speech(overview.speech), 'of speech')),
              if (overview.showConversations) ...<Widget>[
                const SizedBox(width: 12),
                Expanded(flex: 10, child: _Figure('${overview.conversationCount}', 'conversations')),
              ],
              const SizedBox(width: 12),
              Expanded(flex: 10, child: _Figure('${overview.noteCount}', overview.noteCount == 1 ? 'note' : 'notes')),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: <Widget>[
            const SectionCaption('Notes today'),
            const Spacer(),
            TapTarget(
              onTap: onOpenLibrary,
              semanticLabel: 'Search notes',
              child: const AppIcon(AppGlyph.search, size: 18, color: AppColors.textSecondary, strokeWidth: 1.7),
            ),
            LinkAction(label: 'All notes', onTap: onOpenLibrary),
          ],
        ),
        if (overview.today.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Text('No notes yet today. They show up here as you talk.', style: AppText.meta13),
          ),
        for (var i = 0; i < overview.today.length; i++)
          _NoteRowView(
            row: overview.today[i],
            divider: i > 0,
            onTap: () => onOpenRecording(overview.today[i].recording),
          ),
      ],
    );
  }

  String _when(RecordingInfo recording) {
    final day = Fmt.day(recording.recordedAt, now: now);
    final time = Fmt.timeOfDay(recording.recordedAt);
    final length = HomeFormat.noteLength(recording.duration ?? Duration.zero);
    return day == 'Today' ? '$time · $length' : '$day $time · $length';
  }
}

class _NeedsRow extends StatelessWidget {
  const _NeedsRow({
    required this.glyph,
    required this.color,
    required this.title,
    required this.detail,
    required this.action,
    required this.onTap,
    required this.divider,
  });

  final AppGlyph glyph;
  final Color color;
  final String title;
  final String detail;
  final String action;
  final VoidCallback onTap;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: AppShape.minTapTarget),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: divider ? const Border(top: BorderSide(color: AppColors.raised)) : null,
      ),
      child: Row(
        children: <Widget>[
          SizedBox(width: 20, child: Center(child: AppIcon(glyph, size: 18, color: color, strokeWidth: 1.7))),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: AppText.rowTitle.copyWith(fontSize: 14)),
                const SizedBox(height: 3),
                Text(detail, style: AppText.meta12, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: 8),
          LinkAction(label: action, onTap: onTap),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure(this.value, this.label);

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style: AppText.peakValue.copyWith(fontSize: 20, letterSpacing: -0.3, color: AppColors.textPrimary),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: AppText.meta12, maxLines: 1, overflow: TextOverflow.ellipsis),
      ],
    );
  }
}

class _NoteRowView extends StatelessWidget {
  const _NoteRowView({required this.row, required this.divider, required this.onTap});

  final NoteRow row;
  final bool divider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final recording = row.recording;
    final writing = row.state == NoteRowState.writing;
    final length = HomeFormat.noteLength(recording.duration ?? Duration.zero, writing: writing);
    return Semantics(
      button: true,
      label: 'Note at ${Fmt.timeOfDay(recording.recordedAt)}, $length',
      container: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          decoration: BoxDecoration(
            border: divider ? const Border(top: BorderSide(color: AppColors.raised)) : null,
          ),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 48,
                child: Text(
                  Fmt.timeOfDay(recording.recordedAt),
                  style: AppText.peakValue.copyWith(color: AppColors.textPrimary),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  length,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body13,
                ),
              ),
              const SizedBox(width: 10),
              ?_status(row),
              const SizedBox(width: 6),
              const AppIcon(AppGlyph.chevronRight, size: 17, color: AppColors.textTertiary, strokeWidth: 1.7),
            ],
          ),
        ),
      ),
    );
  }

  static Widget? _status(NoteRow row) {
    switch (row.state) {
      case NoteRowState.plain:
        return null;
      case NoteRowState.writing:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // Still, not breathing: the header dot is the one live loop on Home.
            const StatusDot(color: AppColors.recording),
            const SizedBox(width: 6),
            Text('Writing…', style: AppText.label13.copyWith(fontSize: 12, color: AppColors.recording)),
          ],
        );
      case NoteRowState.transcribing:
        final progress = row.progress;
        return StatusPill(progress == null ? 'Transcribing' : 'Transcribing ${(progress * 100).round()}%');
      case NoteRowState.waiting:
        return const StatusPill('Waiting');
      case NoteRowState.failed:
        return const StatusPill("Couldn't transcribe", tone: StatusPillTone.error);
    }
  }
}
