import 'package:flutter/widgets.dart';

import '../../model/firmware_update.dart';
import '../../model/firmware_update_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'update_copy.dart';
import 'update_progress.dart';
import 'update_widgets.dart';

/// "Updating your recorder" - `Updating.dc.html`: a percent, a bar, a rough
/// time left, and three steps.
///
/// NO BACK BUTTON, as drawn. The system gesture still leaves; the run lives
/// in the service, so coming back finds it where it is.
class UpdateRunning extends StatelessWidget {
  const UpdateRunning({required this.state, required this.progress, super.key});

  /// One of downloading, waiting for the bootloader, transferring or
  /// confirming.
  final UpdateState state;
  final UpdateProgress progress;

  @override
  Widget build(BuildContext context) {
    final view = RunningView.of(state, progress);
    return ScreenScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          UpdateHeader(
            title: UpdateCopy.updatingTitle,
            subtitle: view.version == null ? null : UpdateCopy.versionLine(view.version!),
            gapBelow: 40,
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: <Widget>[
                _Bar(label: view.label, percent: view.percent, left: view.left),
                const Padding(
                  padding: EdgeInsets.only(top: 40, bottom: 12),
                  child: SectionCaption(UpdateCopy.whatsHappening),
                ),
                StepRow(label: UpdateCopy.stepUpdateMode, mark: view.steps.$1),
                StepRow(label: UpdateCopy.stepSending, mark: view.steps.$2),
                StepRow(label: UpdateCopy.stepRestart, mark: view.steps.$3),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 28, 4, 0),
                  child: Text(UpdateCopy.keepOpen, style: UpdateText.paragraph),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What the running screen shows for one state: pure, so it is tested
/// without pumping anything.
class RunningView {
  const RunningView({
    required this.label,
    required this.percent,
    required this.steps,
    this.version,
    this.left,
  });

  final String label;
  final int percent;
  final (StepMark, StepMark, StepMark) steps;
  final FirmwareVersion? version;

  /// "About 3 minutes left", or null while there is no fair estimate.
  final String? left;

  static RunningView of(UpdateState state, UpdateProgress progress) {
    const pending = (StepMark.pending, StepMark.pending, StepMark.pending);
    const sending = (StepMark.done, StepMark.active, StepMark.pending);
    switch (state) {
      case UpdateDownloading(:final release):
        return RunningView(
          label: UpdateCopy.preparing,
          percent: (state.fraction * 100).floor(),
          steps: pending,
          version: release.version,
        );
      case UpdateWaitingForBootloader(:final release):
        return RunningView(
          label: UpdateCopy.sending,
          percent: 0,
          steps: sending,
          version: release.version,
        );
      case UpdateTransferring(:final release, :final percent):
        final left = progress.remaining;
        return RunningView(
          label: UpdateCopy.sending,
          percent: percent.clamp(0, 100),
          steps: sending,
          version: release.version,
          left: left == null ? null : UpdateCopy.timeLeft(left),
        );
      case UpdateConfirming(:final release):
        return RunningView(
          label: UpdateCopy.sending,
          percent: 100,
          steps: (StepMark.done, StepMark.done, StepMark.active),
          version: release.version,
        );
      default:
        return const RunningView(label: UpdateCopy.preparing, percent: 0, steps: pending);
    }
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.label, required this.percent, this.left});

  final String label;
  final int percent;
  final String? left;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      value: '$percent%',
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Expanded(child: Text(label, style: AppText.rowTitle)),
              Text(
                '$percent%',
                style: AppText.peakValue.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(3)),
            child: Container(
              height: 6,
              color: AppColors.raised,
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: percent / 100,
                heightFactor: 1,
                child: const ColoredBox(color: AppColors.primaryFill),
              ),
            ),
          ),
          if (left != null) ...<Widget>[
            const SizedBox(height: 14),
            Text(left!, style: AppText.meta12),
          ],
        ],
      ),
    );
  }
}
