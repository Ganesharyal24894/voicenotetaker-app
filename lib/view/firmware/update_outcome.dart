import 'package:flutter/widgets.dart';

import '../../model/firmware_update_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'update_copy.dart';
import 'update_widgets.dart';

/// "Your recorder is up to date" - `UpdateDone.dc.html`. Also what the screen
/// says when it is opened with nothing to offer, with [body] saying so.
class UpdateFinished extends StatelessWidget {
  const UpdateFinished({required this.body, required this.onDone, super.key});

  final String body;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SizedBox(height: AppShape.minTapTarget),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 80),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Container(
                    width: 72,
                    height: 72,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.purpleChipBorder),
                    ),
                    child: const Tick(size: 30),
                  ),
                  const SizedBox(height: 18),
                  const Text(UpdateCopy.doneTitle,
                      style: AppText.title22, textAlign: TextAlign.center),
                  const SizedBox(height: 18),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 280),
                    child: Text(
                      body,
                      textAlign: TextAlign.center,
                      style: UpdateText.paragraph.copyWith(fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          ),
          UpdateButton(label: UpdateCopy.done, onPressed: onDone),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

/// Where the recorder is after a run stopped, which decides the card.
enum _Left { updateMode, unchanged, notBack, unknown }

/// "The update didn't finish" - `UpdateFailed.dc.html`: what went wrong, where
/// that leaves the recorder, and the cable as the way out if it keeps
/// happening.
class UpdateFailedView extends StatelessWidget {
  const UpdateFailedView({
    required this.failure,
    required this.onTryAgain,
    required this.onLater,
    this.droppedAt,
    super.key,
  });

  final UpdateFailed failure;
  final VoidCallback onTryAgain;
  final VoidCallback onLater;

  /// The last percent seen while sending, for "dropped at 61%".
  final int? droppedAt;

  static _Left _left(UpdateFailure reason) => switch (reason) {
        UpdateFailure.transferFailed ||
        UpdateFailure.bootloaderNotFound =>
          _Left.updateMode,
        UpdateFailure.download ||
        UpdateFailure.checksumMismatch ||
        UpdateFailure.storage ||
        UpdateFailure.notConnected ||
        UpdateFailure.triggerRefused =>
          _Left.unchanged,
        UpdateFailure.recorderDidNotReturn => _Left.notBack,
        UpdateFailure.recorderDidNotRestart ||
        UpdateFailure.versionMismatch =>
          _Left.unknown,
      };

  @override
  Widget build(BuildContext context) {
    final card = switch (_left(failure.reason)) {
      _Left.updateMode => (UpdateCopy.waitingTitle, UpdateCopy.waitingBody, AppColors.warning),
      _Left.unchanged => (UpdateCopy.unchangedTitle, UpdateCopy.unchangedBody, AppColors.connected),
      _Left.notBack => (UpdateCopy.notBackTitle, UpdateCopy.notBackBody, AppColors.warning),
      _Left.unknown => null,
    };
    return ScreenScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          UpdateHeader(
            title: UpdateCopy.failedTitle,
            subtitle: UpdateCopy.failedReason(failure.reason, droppedAt: droppedAt),
            gapBelow: 28,
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: <Widget>[
                if (card != null) ...<Widget>[
                  _StateCard(title: card.$1, body: card.$2, dot: card.$3),
                  const SizedBox(height: 28),
                ],
                const SectionCaption(UpdateCopy.keepsFailing),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(UpdateCopy.usbFallback, style: UpdateText.paragraph),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (failure.canRetry) ...<Widget>[
            UpdateButton(label: UpdateCopy.tryAgain, onPressed: onTryAgain),
            UpdateTextButton(label: UpdateCopy.later, onPressed: onLater),
          ] else
            UpdateButton(label: UpdateCopy.close, onPressed: onLater),
        ],
      ),
    );
  }
}

class _StateCard extends StatelessWidget {
  const _StateCard({required this.title, required this.body, required this.dot});

  final String title;
  final String body;
  final Color dot;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              StatusDot(color: dot),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: UpdateText.item)),
            ],
          ),
          const SizedBox(height: 10),
          Text(body, style: UpdateText.paragraph),
        ],
      ),
    );
  }
}
