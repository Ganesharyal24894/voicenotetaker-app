import 'dart:async';

import 'package:flutter/material.dart';

import '../../controller/summary_controller.dart';
import '../../model/recording_info.dart';
import '../../model/summary/prompt_builder.dart';
import '../../model/summary/summary_range.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/home_icons.dart';
import '../widgets/home_widgets.dart';
import 'home_format.dart';
import 'summary_scope.dart';

/// Opens "Summarize with your AI" for a range of notes.
Future<void> showSummarizeSheet(
  BuildContext context, {
  required SummaryController summaries,
  required List<RecordingInfo> recordings,
}) =>
    showHomeSheet<void>(
      context,
      builder: (context) => SummarizeRangeSheet(summaries: summaries, recordings: recordings),
    );

/// Opens "Summarize this note" for [note].
///
/// THE HOOK FOR THE NOTE SCREEN: it needs only a context under `AppRoot` and
/// the note, and finds the [SummaryController] through [SummaryScope]. Does
/// nothing when there is no scope - a screen pumped on its own in a test.
Future<void> showNoteSummarizeSheet(BuildContext context, RecordingInfo note) {
  final summaries = SummaryScope.maybeOf(context);
  if (summaries == null) return Future<void>.value();
  return showHomeSheet<void>(
    context,
    builder: (context) => NoteSummarizeSheet(summaries: summaries, note: note),
  );
}

/// The range sheet: pick a range, see what goes in, copy or share.
class SummarizeRangeSheet extends StatefulWidget {
  const SummarizeRangeSheet({required this.summaries, required this.recordings, super.key});

  final SummaryController summaries;
  final List<RecordingInfo> recordings;

  static const String title = 'Summarize with your AI';
  static const String subtitle = 'Makes one prompt from your transcripts. Paste it into any AI chat app.';
  static const String longWarning = 'Long — some AI apps may cut it off.';

  @override
  State<SummarizeRangeSheet> createState() => _SummarizeRangeSheetState();
}

class _SummarizeRangeSheetState extends State<SummarizeRangeSheet> {
  SummaryRange _range = SummaryRange.today;
  late Future<RangePromptInfo> _info;
  bool _split = false;

  /// Null while picking; the index of the part just copied once copied.
  int? _copied;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _info = widget.summaries.rangePrompt(_range, widget.recordings);
  }

  List<String> _texts(RangePrompt prompt) =>
      _split && prompt.isLong ? prompt.parts : <String>[prompt.whole];

  Future<void> _copy(RangePrompt prompt, int index) async {
    await widget.summaries.copy(_texts(prompt)[index], from: prompt);
    if (mounted) setState(() => _copied = index);
  }

  Future<void> _share(BuildContext context, RangePrompt prompt, int index) async {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    await widget.summaries.share(_texts(prompt)[index], from: prompt, origin: origin);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<RangePromptInfo>(
      future: _info,
      builder: (context, snapshot) {
        final info = snapshot.data;
        final copied = _copied;
        if (info != null && copied != null) return _copiedView(context, info, copied);
        return _pickView(context, info);
      },
    );
  }

  Widget _pickView(BuildContext context, RangePromptInfo? info) {
    final prompt = info?.prompt;
    final ready = prompt != null && prompt.noteCount > 0;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text(SummarizeRangeSheet.title, style: AppText.title21),
          const SizedBox(height: 8),
          const Text(SummarizeRangeSheet.subtitle, style: AppText.footnote12),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              for (var i = 0; i < SummaryRange.values.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: 6),
                Expanded(
                  child: SegmentButton(
                    label: SummaryRange.values[i].label,
                    selected: SummaryRange.values[i] == _range,
                    onTap: () => setState(() {
                      _range = SummaryRange.values[i];
                      _split = false;
                      _load();
                    }),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Text(
            prompt == null
                ? 'Getting your notes…'
                : prompt.noteCount == 0
                    ? 'No transcribed notes in this range yet.'
                    : HomeFormat.promptCount(prompt.noteCount, prompt.speech, prompt.wordCount),
            style: AppText.body13,
          ),
          if (info != null && info.untranscribed > 0) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              info.untranscribed == 1
                  ? "1 note isn't transcribed yet, so it's left out."
                  : "${info.untranscribed} notes aren't transcribed yet, so they're left out.",
              style: AppText.meta12,
            ),
          ],
          if (prompt != null && prompt.isLong) ...<Widget>[
            const SizedBox(height: 16),
            AppCard(
              padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('Split into ${prompt.parts.length} parts', style: AppText.rowTitle),
                        const SizedBox(height: 4),
                        const Text(SummarizeRangeSheet.longWarning, style: AppText.footnote12),
                      ],
                    ),
                  ),
                  HomeSwitch(
                    label: 'Split into parts',
                    value: _split,
                    onChanged: (value) => setState(() => _split = value),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          SheetButton(
            label: 'Copy prompt',
            glyph: HomeGlyph.copy,
            onPressed: ready ? () => unawaited(_copy(prompt, 0)) : null,
          ),
          if (widget.summaries.canShare) ...<Widget>[
            const SizedBox(height: 10),
            Builder(
              builder: (context) => SheetButton(
                label: 'Share',
                glyph: HomeGlyph.share,
                filled: false,
                onPressed: ready ? () => unawaited(_share(context, prompt, 0)) : null,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _copiedView(BuildContext context, RangePromptInfo info, int index) {
    final prompt = info.prompt;
    final texts = _texts(prompt);
    final last = index >= texts.length - 1;
    return CopiedView(
      title: texts.length == 1 ? 'Copied' : 'Part ${index + 1} of ${texts.length} copied',
      meta: '${prompt.range.label} · ${prompt.noteCount == 1 ? '1 note' : '${prompt.noteCount} notes'} · '
          '${PromptBuilder.aboutWords(prompt.wordCount)}',
      preview: texts[index],
      primaryLabel: last ? 'Done' : 'Copy part ${index + 2}',
      onPrimary: last ? () => Navigator.of(context).pop() : () => unawaited(_copy(prompt, index + 1)),
      onShare: widget.summaries.canShare ? (context) => unawaited(_share(context, prompt, index)) : null,
    );
  }
}

/// The single-note sheet.
class NoteSummarizeSheet extends StatefulWidget {
  const NoteSummarizeSheet({required this.summaries, required this.note, super.key});

  final SummaryController summaries;
  final RecordingInfo note;

  static const String title = 'Summarize this note';

  @override
  State<NoteSummarizeSheet> createState() => _NoteSummarizeSheetState();
}

class _NoteSummarizeSheetState extends State<NoteSummarizeSheet> {
  late final Future<NotePromptInfo> _info = widget.summaries.notePrompt(widget.note);
  bool _copied = false;

  Future<void> _share(BuildContext context, String text) async {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    await widget.summaries.share(text, origin: origin);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<NotePromptInfo>(
      future: _info,
      builder: (context, snapshot) {
        final info = snapshot.data;
        final text = info?.text;
        final length = HomeFormat.noteLength(widget.note.duration ?? Duration.zero);
        final meta = info == null
            ? 'This note · $length'
            : 'This note · $length · ${PromptBuilder.aboutWords(info.wordCount)}';
        if (_copied && text != null) {
          return CopiedView(
            title: 'Copied',
            meta: meta,
            preview: text,
            primaryLabel: 'Done',
            onPrimary: () => Navigator.of(context).pop(),
            onShare: widget.summaries.canShare ? (context) => unawaited(_share(context, text)) : null,
          );
        }
        return SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Text(NoteSummarizeSheet.title, style: AppText.title21),
              const SizedBox(height: 8),
              Text(meta, style: AppText.body13),
              const SizedBox(height: 16),
              Expanded(
                child: PromptPreview(
                  text: info == null
                      ? ''
                      : text ?? "This note isn't transcribed yet. Once it is, you can summarize it here.",
                ),
              ),
              const SizedBox(height: 20),
              SheetButton(
                label: 'Copy prompt',
                glyph: HomeGlyph.copy,
                onPressed: text == null
                    ? null
                    : () async {
                        await widget.summaries.copy(text);
                        if (mounted) setState(() => _copied = true);
                      },
              ),
              if (widget.summaries.canShare) ...<Widget>[
                const SizedBox(height: 10),
                Builder(
                  builder: (context) => SheetButton(
                    label: 'Share',
                    glyph: HomeGlyph.share,
                    filled: false,
                    onPressed: text == null ? null : () => unawaited(_share(context, text)),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// "Copied": what to do next, and the prompt itself to glance over.
class CopiedView extends StatelessWidget {
  const CopiedView({
    required this.title,
    required this.meta,
    required this.preview,
    required this.primaryLabel,
    required this.onPrimary,
    this.onShare,
    super.key,
  });

  static const String nextStep = 'Paste it into ChatGPT, Claude or Gemini.';

  final String title;
  final String meta;
  final String preview;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final void Function(BuildContext context)? onShare;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.85,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const HomeIcon(HomeGlyph.checkCircle, size: 24, color: AppColors.connected, strokeWidth: 1.8),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: AppText.title21)),
            ],
          ),
          const SizedBox(height: 6),
          Text(nextStep, style: AppText.body13.copyWith(fontSize: 14)),
          const SizedBox(height: 4),
          Text(meta, style: AppText.meta13),
          const SizedBox(height: 14),
          Expanded(child: PromptPreview(text: preview)),
          const SizedBox(height: 20),
          Row(
            children: <Widget>[
              if (onShare != null) ...<Widget>[
                Expanded(
                  child: Builder(
                    builder: (context) => SheetButton(
                      label: 'Share',
                      glyph: HomeGlyph.share,
                      filled: false,
                      onPressed: () => onShare!(context),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(child: SheetButton(label: primaryLabel, onPressed: onPrimary)),
            ],
          ),
        ],
      ),
    );
  }
}

/// The dark, scrollable box a prompt is previewed in.
class PromptPreview extends StatelessWidget {
  const PromptPreview({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.screen,
        border: Border.all(color: AppColors.raised),
        borderRadius: AppShape.card,
      ),
      child: ClipRRect(
        borderRadius: AppShape.card,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Text(text, style: AppText.footnote12.copyWith(color: AppColors.textSecondary)),
        ),
      ),
    );
  }
}
