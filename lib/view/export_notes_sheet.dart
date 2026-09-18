import 'dart:async';

import 'package:flutter/material.dart';

import '../controller/export_controller.dart';
import '../services/export/note_export_plan.dart';
import '../services/export/note_export_service.dart';
import 'format.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/home_icons.dart';
import 'widgets/home_widgets.dart';

/// Opens "Export notes" and cleans up after itself.
///
/// The controller belongs to the sheet: it is made when the sheet opens and
/// closed when the sheet closes, which stops a write that is still running,
/// removes the zip and disposes it. A copy of every note you own is not
/// something to leave sitting in app storage because a sheet was swiped away.
Future<void> showExportNotesSheet(
  BuildContext context, {
  required ExportController exports,
}) async {
  // Anything left from last time goes NOW rather than on the way out: a zip
  // that has been handed to AirDrop is still being read after the sheet is
  // dismissed, so `close` leaves that one alone and this is what collects it.
  await exports.discard();
  if (!context.mounted) {
    exports.dispose();
    return;
  }
  try {
    await showHomeSheet<void>(
      context,
      builder: (context) => ExportNotesSheet(exports: exports),
    );
  } finally {
    await exports.close();
  }
}

/// Pick a range, make one zip, send it anywhere.
class ExportNotesSheet extends StatefulWidget {
  const ExportNotesSheet({required this.exports, super.key});

  final ExportController exports;

  static const String title = 'Export notes';
  static const String subtitle =
      'Puts your recordings and transcripts into one zip. Send it with AirDrop, '
      'save it to Files, or attach it to a message.';

  @override
  State<ExportNotesSheet> createState() => _ExportNotesSheetState();
}

class _ExportNotesSheetState extends State<ExportNotesSheet> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.exports.choose(widget.exports.range));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.exports,
      builder: (context, _) => SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(ExportNotesSheet.title, style: AppText.title21),
            const SizedBox(height: 8),
            const Text(ExportNotesSheet.subtitle, style: AppText.footnote12),
            const SizedBox(height: 16),
            switch (widget.exports.phase) {
              ExportPhase.choosing => _choosing(context),
              ExportPhase.writing => _writing(context),
              ExportPhase.ready => _ready(context),
            },
          ],
        ),
      ),
    );
  }

  Widget _choosing(BuildContext context) {
    final exports = widget.exports;
    final plan = exports.plan;
    final ready = plan != null && !plan.isEmpty && !plan.tooLarge;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            for (var i = 0; i < ExportRange.values.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: SegmentButton(
                  label: ExportRange.values[i].label,
                  selected: ExportRange.values[i] == exports.range,
                  onTap: () =>
                      unawaited(exports.choose(ExportRange.values[i])),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Text(_summaryLine(plan), style: AppText.body13),
        if (exports.failure != null) ...<Widget>[
          const SizedBox(height: 4),
          Text(_failureLine(exports), style: AppText.meta12),
        ],
        const SizedBox(height: 20),
        SheetButton(
          label: 'Make the zip',
          onPressed: ready ? () => unawaited(exports.run()) : null,
        ),
      ],
    );
  }

  Widget _writing(BuildContext context) {
    final exports = widget.exports;
    final total = exports.plan?.zipBytes ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          '${Fmt.bytes(exports.bytesWritten)} of ${Fmt.bytes(total)}',
          style: AppText.body13,
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: AppShape.pill,
          child: LinearProgressIndicator(
            value: exports.progress,
            minHeight: 6,
            color: AppColors.purpleText,
            backgroundColor: AppColors.raised,
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Keep this open until it finishes.',
          style: AppText.meta12,
        ),
        const SizedBox(height: 20),
        SheetButton(
          label: exports.stopping ? 'Stopping…' : 'Stop',
          filled: false,
          onPressed: exports.stopping ? null : exports.cancel,
        ),
      ],
    );
  }

  Widget _ready(BuildContext context) {
    final exports = widget.exports;
    final result = exports.result!;
    final name = exports.plan?.zipName ?? 'notes.zip';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(name, style: AppText.rowTitle),
        const SizedBox(height: 4),
        Text(
          '${_notes(result.noteCount)} · ${Fmt.bytes(result.sizeBytes)}',
          style: AppText.rowMeta,
        ),
        if (result.unreadableFiles > 0) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            result.unreadableFiles == 1
                ? 'One file could not be read, so its place in the zip is '
                    'silence. The note on the phone is untouched.'
                : '${result.unreadableFiles} files could not be read, so their '
                    'place in the zip is silence. The notes on the phone are '
                    'untouched.',
            style: AppText.meta12,
          ),
        ],
        const SizedBox(height: 20),
        if (exports.canShare)
          Builder(
            builder: (context) => SheetButton(
              label: 'Send it',
              glyph: HomeGlyph.share,
              onPressed: () => unawaited(_share(context)),
            ),
          )
        else
          const Text(
            'This build has nowhere to send it. Pull the notes over a cable '
            'instead.',
            style: AppText.meta12,
          ),
        const SizedBox(height: 10),
        SheetButton(
          label: 'Done',
          filled: false,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  Future<void> _share(BuildContext context) async {
    // The button's own rectangle, so an iPad's popover points at the thing
    // that was tapped - the same idiom the Summarize sheet uses.
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    await widget.exports.share(origin: origin);
  }

  /// One line saying what the chosen range holds.
  static String _summaryLine(ExportPlan? plan) {
    if (plan == null) return 'Counting your notes…';
    if (plan.isEmpty) return 'No notes in this range yet.';
    if (plan.tooLarge) {
      return 'That is more than one zip can hold. Pick a shorter range, or '
          'use a cable.';
    }
    return '${_notes(plan.noteCount)} · ${Fmt.bytes(plan.zipBytes)}';
  }

  static String _failureLine(ExportController exports) {
    final result = exports.result;
    return switch (exports.failure) {
      ExportFailure.noRoom => result?.freeBytes == null
          ? 'Not enough room on the phone.'
          : 'Not enough room on the phone: it has '
              '${Fmt.bytes(result!.freeBytes!)} free.',
      ExportFailure.tooLarge =>
        'That is more than one zip can hold. Pick a shorter range.',
      ExportFailure.nothingToExport => 'No notes in this range yet.',
      ExportFailure.failed =>
        'The zip could not be written. Your notes are untouched.',
      ExportFailure.cancelled || null => '',
    };
  }

  static String _notes(int count) => count == 1 ? '1 note' : '$count notes';
}
