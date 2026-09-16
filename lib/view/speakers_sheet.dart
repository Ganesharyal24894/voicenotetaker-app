import 'dart:async';

import 'package:flutter/material.dart';

import '../controller/speakers_controller.dart';
import 'speaker_palette.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/home_widgets.dart';

/// Opens the Speakers sheet over the note at [recordingPath].
///
/// `SpeakersSheet.dc.html` and `MergeSpeakers.dc.html`. Both artboards are one
/// sheet: "Merge…" swaps what the sheet shows, so merging comes straight back
/// to the list with the merged speaker gone.
Future<void> showSpeakersSheet(
  BuildContext context, {
  required SpeakersController speakers,
  required String recordingPath,
}) =>
    showHomeSheet<void>(
      context,
      builder: (context) =>
          SpeakersSheet(speakers: speakers, recordingPath: recordingPath),
    );

/// Name the speakers of one note, merge two of them, and say how many people
/// spoke.
///
/// WHEN A NAME IS SAVED: when the field loses focus, and again on Done. Blur
/// covers every way out of a field - the next field, "Merge…", a count, the
/// keyboard's Done - so a name is never one un-tapped button away from being
/// lost, and a name typed and then swiped away is saved on the way out rather
/// than silently dropped. An empty field clears the name, and the speaker
/// goes back to being `Speaker N`.
class SpeakersSheet extends StatefulWidget {
  const SpeakersSheet({
    required this.speakers,
    required this.recordingPath,
    super.key,
  });

  final SpeakersController speakers;
  final String recordingPath;

  /// The footnote under the count row, and what replaces it while a re-run is
  /// working.
  static const String countFootnote =
      'Choosing a number re-checks who said what.';
  static const String working = 'Working out who spoke…';

  /// "4" means "4 or more" - past three voices the count stops being a count
  /// and starts being a hint.
  static const List<int?> counts = <int?>[null, 2, 3, 4];

  @override
  State<SpeakersSheet> createState() => _SpeakersSheetState();
}

class _SpeakersSheetState extends State<SpeakersSheet> {
  final Map<String, TextEditingController> _fields =
      <String, TextEditingController>{};
  final Map<String, FocusNode> _focus = <String, FocusNode>{};

  /// The speaker whose "Merge…" was tapped, or null while showing the list.
  String? _mergingFrom;

  List<String> _labels = const <String>[];

  /// Disposing a focused [FocusNode] fires its listener, and the fields it
  /// would save are being disposed in the same breath. This stops that
  /// last blur from reaching a controller that is already gone.
  bool _disposed = false;

  String get _path => widget.recordingPath;

  @override
  void initState() {
    super.initState();
    widget.speakers.addListener(_onChanged);
    _sync();
  }

  @override
  void dispose() {
    widget.speakers.removeListener(_onChanged);
    // A name typed and then swiped away is still a name the user gave. Read
    // it while the fields are still alive; the controller outlives this
    // widget, so the save completes.
    final pending = _pendingChanges();
    _disposed = true;
    if (pending.isNotEmpty) {
      unawaited(widget.speakers.renameSpeakers(_path, pending));
    }
    for (final node in _focus.values) {
      node.dispose();
    }
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(_sync);
  }

  /// Brings the fields in line with the note's speakers: one per label, kept
  /// across a rebuild so typing survives, dropped when a merge removes a
  /// speaker.
  void _sync() {
    _labels = widget.speakers.speakerLabelsFor(_path);
    final names = widget.speakers.speakerNamesFor(_path);
    for (final label in _labels) {
      if (_fields.containsKey(label)) continue;
      _fields[label] =
          TextEditingController(text: names.customName(label) ?? '');
      // The node is held locally rather than looked up again: a merge can
      // take this label out of the map before the last blur arrives.
      final node = FocusNode();
      node.addListener(() {
        if (!node.hasFocus) _saveField(label);
      });
      _focus[label] = node;
    }
    for (final gone in _fields.keys.toList()) {
      if (_labels.contains(gone)) continue;
      final field = _fields.remove(gone)!;
      _focus.remove(gone)!.dispose();
      field.dispose();
    }
    if (_mergingFrom != null && !_labels.contains(_mergingFrom)) {
      _mergingFrom = null;
    }
  }

  /// Every field whose text differs from the saved name, as label -> name.
  Map<String, String> _pendingChanges() {
    final names = widget.speakers.speakerNamesFor(_path);
    final changes = <String, String>{};
    for (final entry in _fields.entries) {
      final typed = entry.value.text.trim();
      if (typed == (names.customName(entry.key) ?? '')) continue;
      changes[entry.key] = typed;
    }
    return changes;
  }

  void _saveField(String label) {
    if (_disposed) return;
    final field = _fields[label];
    if (field == null) return;
    final typed = field.text.trim();
    final saved = widget.speakers.speakerNamesFor(_path).customName(label);
    // Whitespace alone is no name: show the default label again.
    if (field.text != typed) field.text = typed;
    if (typed == (saved ?? '')) return;
    unawaited(
      widget.speakers.renameSpeakers(_path, <String, String>{label: typed}),
    );
  }

  void _done() {
    final pending = _pendingChanges();
    if (pending.isNotEmpty) {
      unawaited(widget.speakers.renameSpeakers(_path, pending));
    }
    Navigator.of(context).pop();
  }

  Future<void> _setCount(int? count) async {
    // Leaving the field first, so a half-typed name is saved before the
    // re-run this may start.
    FocusScope.of(context).unfocus();
    if (count == widget.speakers.speakerCountFor(_path)) return;
    await widget.speakers.setSpeakerCount(_path, count);
    if (mounted) setState(() {});
  }

  void _startMerge(String from) {
    FocusScope.of(context).unfocus();
    setState(() => _mergingFrom = from);
  }

  Future<void> _merge(String from, String into) async {
    await widget.speakers.mergeSpeakers(_path, from, into);
    if (mounted) setState(() => _mergingFrom = null);
  }

  @override
  Widget build(BuildContext context) {
    final merging = _mergingFrom;
    return Padding(
      // The sheet holds text fields: lift it above the keyboard rather than
      // letting the keyboard sit on top of the field being typed into.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: merging == null ? _list() : _mergePage(merging),
    );
  }

  // -------------------------------------------------------------- the list

  Widget _list() {
    final names = widget.speakers.speakerNamesFor(_path);
    final count = widget.speakers.speakerCountFor(_path);
    final progress = widget.speakers.detectionProgressFor(_path);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Text('Speakers', style: AppText.title21),
                const SizedBox(height: 10),
                for (var i = 0; i < _labels.length; i++)
                  _row(i, names.labelFor(_labels[i], _labels)),
                const SizedBox(height: 20),
                const Text(
                  'How many people spoke?',
                  style: AppText.label13,
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    for (var i = 0; i < SpeakersSheet.counts.length; i++) ...[
                      if (i > 0) const SizedBox(width: 6),
                      Expanded(
                        child: _countSegment(SpeakersSheet.counts[i], count),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                if (progress == null)
                  const Text(
                    SpeakersSheet.countFootnote,
                    style: AppText.footnote12,
                  )
                else
                  _progress(progress),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        // Never disabled, not even mid-re-run: the sheet can always be left.
        PrimaryButton(label: 'Done', onPressed: _done),
      ],
    );
  }

  Widget _row(int index, String display) {
    final label = _labels[index];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          StatusDot(color: SpeakerPalette.at(index), size: 10),
          const SizedBox(width: 12),
          Expanded(child: _nameField(label, index)),
          // Nobody to merge into when there is only one speaker left.
          if (_labels.length > 1) ...<Widget>[
            const SizedBox(width: 12),
            TapTarget(
              onTap: () => _startMerge(label),
              semanticLabel: 'Merge $display into another speaker',
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  'Merge…',
                  style:
                      AppText.label13.copyWith(color: AppColors.purpleText),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The name field. Its placeholder is the speaker's default label, so an
  /// empty field reads as "Speaker 3" rather than as nothing.
  Widget _nameField(String label, int index) {
    final defaultLabel = 'Speaker ${index + 1}';
    return Container(
      height: AppShape.minTapTarget,
      decoration: BoxDecoration(
        color: AppColors.raised,
        border: Border.all(color: AppColors.border),
        borderRadius: AppShape.segment,
      ),
      alignment: Alignment.centerLeft,
      child: TextField(
        controller: _fields[label],
        focusNode: _focus[label],
        style: AppText.rowTitle,
        cursorColor: AppColors.purpleText,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _focus[label]?.unfocus(),
        decoration: InputDecoration(
          isCollapsed: true,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          hintText: defaultLabel,
          hintStyle: AppText.rowTitle.copyWith(
            fontWeight: FontWeight.w300,
            color: AppColors.textTertiary,
          ),
        ),
      ),
    );
  }

  Widget _countSegment(int? value, int? selected) {
    final label = switch (value) {
      null => 'Auto',
      4 => '4+',
      final n => '$n',
    };
    final spoken = switch (value) {
      null => 'How many people spoke: work it out for me',
      4 => 'How many people spoke: 4 or more',
      final n => 'How many people spoke: $n',
    };
    return SegmentButton(
      label: label,
      semanticLabel: spoken,
      selected: value == selected,
      onTap: () => unawaited(_setCount(value)),
    );
  }

  /// The transcription screen's progress presentation, sized for a sheet: the
  /// same line-over-hairline, so a slow re-run looks like the slow job it is
  /// rather than like nothing happening.
  Widget _progress(double progress) {
    final percent = (progress.clamp(0.0, 1.0) * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Semantics(
          liveRegion: true,
          child: Text(
            '${SpeakersSheet.working} $percent%',
            style: AppText.body13,
          ),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: AppShape.pill,
          child: LinearProgressIndicator(
            value: progress.clamp(0.0, 1.0),
            minHeight: 3,
            color: AppColors.purpleText,
            backgroundColor: AppColors.raised,
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------- the merge

  Widget _mergePage(String from) {
    final names = widget.speakers.speakerNamesFor(_path);
    final others = <String>[
      for (final label in _labels)
        if (label != from) label,
    ];
    return _MergeSpeakerPage(
      key: ValueKey<String>('merge-$from'),
      from: from,
      fromName: names.labelFor(from, _labels),
      others: others,
      colorOf: (label) => SpeakerPalette.of(label, _labels),
      nameOf: (label) => names.labelFor(label, _labels),
      onMerge: (into) => _merge(from, into),
      onCancel: () => setState(() => _mergingFrom = null),
    );
  }
}

/// "Merge Speaker 3 into…": pick one of the others, or back out.
class _MergeSpeakerPage extends StatefulWidget {
  const _MergeSpeakerPage({
    required this.from,
    required this.fromName,
    required this.others,
    required this.colorOf,
    required this.nameOf,
    required this.onMerge,
    required this.onCancel,
    super.key,
  });

  final String from;
  final String fromName;
  final List<String> others;
  final Color Function(String label) colorOf;
  final String Function(String label) nameOf;
  final Future<void> Function(String into) onMerge;
  final VoidCallback onCancel;

  static const String footnote = 'Their lines will show under one name.';

  @override
  State<_MergeSpeakerPage> createState() => _MergeSpeakerPageState();
}

class _MergeSpeakerPageState extends State<_MergeSpeakerPage> {
  late String? _into = widget.others.isEmpty ? null : widget.others.first;

  @override
  Widget build(BuildContext context) {
    final into = _into;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'Merge ${widget.fromName} into…',
                  style: AppText.title21,
                ),
                const SizedBox(height: 12),
                for (var i = 0; i < widget.others.length; i++)
                  _option(i, widget.others[i], widget.others[i] == into),
                const SizedBox(height: 12),
                const Text(
                  _MergeSpeakerPage.footnote,
                  style: AppText.footnote12,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        PrimaryButton(
          label: 'Merge',
          onPressed:
              into == null ? null : () => unawaited(widget.onMerge(into)),
        ),
        const SizedBox(height: 10),
        QuietButton(label: 'Cancel', onPressed: widget.onCancel),
      ],
    );
  }

  Widget _option(int index, String label, bool selected) {
    final name = widget.nameOf(label);
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      label: name,
      container: true,
      excludeSemantics: true,
      onTap: () => setState(() => _into = label),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _into = label),
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          decoration: index == 0
              ? null
              : const BoxDecoration(
                  border: Border(
                    top: BorderSide(color: AppColors.raised),
                  ),
                ),
          child: Row(
            children: <Widget>[
              StatusDot(color: widget.colorOf(label), size: 10),
              const SizedBox(width: 12),
              Expanded(child: Text(name, style: AppText.rowTitle)),
              const SizedBox(width: 12),
              _radio(selected),
            ],
          ),
        ),
      ),
    );
  }

  Widget _radio(bool selected) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? AppColors.purpleText : AppColors.border,
          width: 2,
        ),
      ),
      alignment: Alignment.center,
      child: selected
          ? const StatusDot(color: AppColors.purpleText, size: 10)
          : null,
    );
  }
}
