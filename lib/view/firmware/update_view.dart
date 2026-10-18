import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../model/firmware_update.dart';
import '../../model/firmware_update_state.dart';
import '../../services/firmware/firmware_update_service.dart';
import 'update_copy.dart';
import 'update_offer.dart';
import 'update_outcome.dart';
import 'update_progress.dart';
import 'update_running.dart';

/// The recorder-update screen: one route whose content follows the service.
///
/// Ready / blocked, updating, done and failed are states of ONE screen,
/// driven by [FirmwareUpdateService.state] and [FirmwareUpdateService.decision]
/// - nothing here holds the run, so leaving mid-transfer and coming back
/// (from Settings' Software row) finds it where it is.
///
/// "Later" on a failure leaves the failure in place on purpose: after `OTA!`
/// the recorder waits in update mode, and only the failed state can resume
/// it with Try again.
class UpdateView extends StatefulWidget {
  const UpdateView({
    required this.updates,
    this.progress,
    this.onClose,
    super.key,
  });

  final FirmwareUpdateService updates;

  /// The app's long-lived progress record (see [UpdateProgress]). Null makes
  /// one for this screen alone, which is what a test wants.
  final UpdateProgress? progress;

  /// Leaves the screen. Null pops the route it is on.
  final VoidCallback? onClose;

  @override
  State<UpdateView> createState() => _UpdateViewState();
}

class _UpdateViewState extends State<UpdateView> {
  late final UpdateProgress _progress =
      widget.progress ?? UpdateProgress(widget.updates.state);

  FirmwareUpdateService get _updates => widget.updates;

  @override
  void dispose() {
    if (widget.progress == null) _progress.dispose();
    super.dispose();
  }

  void _close() {
    final close = widget.onClose;
    if (close != null) {
      close();
    } else {
      unawaited(Navigator.of(context).maybePop());
    }
  }

  void _dismissAndClose() {
    _updates.dismiss();
    _close();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<UpdateState>(
        valueListenable: _updates.state,
        builder: (context, state, _) => _screen(state),
      );

  Widget _screen(UpdateState state) {
    switch (state) {
      case UpdateDownloading() ||
            UpdateWaitingForBootloader() ||
            UpdateTransferring() ||
            UpdateConfirming():
        return UpdateRunning(state: state, progress: _progress);
      case UpdateDone(:final version):
        return UpdateFinished(
          body: UpdateCopy.doneBody(version),
          onDone: _dismissAndClose,
        );
      case UpdateFailed():
        return UpdateFailedView(
          failure: state,
          droppedAt: state.reason == UpdateFailure.transferFailed
              ? _progress.lastPercent
              : null,
          onTryAgain: () => unawaited(_updates.retry()),
          onLater: state.canRetry ? _close : _dismissAndClose,
        );
      case UpdateIdle() ||
            UpdateChecking() ||
            UpdateAvailable() ||
            UpdateReadyToInstall():
        final decision = _updates.decision;
        final release = switch (decision) {
          UpdateOffered(:final release) || UpdateBlocked(:final release) =>
            release,
          UpdateNone() => null,
        };
        if (release == null) {
          return UpdateFinished(
            body: UpdateCopy.nothingToDoBody(_updates.installedVersion),
            onDone: _close,
          );
        }
        return UpdateOffer(
          release: release,
          decision: decision,
          onUpdate: () => unawaited(_updates.install()),
          onNotNow: _close,
        );
    }
  }
}
