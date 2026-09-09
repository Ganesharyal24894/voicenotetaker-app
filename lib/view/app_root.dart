import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../controller/app_controller.dart';
import 'developer_view.dart';
import 'home_view.dart';
import 'library_view.dart';
import 'placeholder_data.dart';
import 'playback_view.dart';
import 'recording_entry.dart';
import 'recording_view.dart';
import 'scan_view.dart';

/// Chooses which of the six screens is on top, and owns navigation between
/// them.
///
/// The three primary screens are driven by [AppController.phase], not by the
/// navigator: pairing, home and recording are states of the device, so pushing
/// routes for them would let the stack disagree with the radio. Library,
/// playback and the developer screen are pushed, because they are places the
/// user chose to go.
class AppRoot extends StatefulWidget {
  const AppRoot({required this.controller, super.key});

  final AppController controller;

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  /// Any real finished recording first, then the placeholder library.
  List<RecordingEntry> get _entries {
    final last = widget.controller.lastRecording;
    return <RecordingEntry>[
      if (last != null) RecordingEntry.fromMetadata(last),
      ...PlaceholderData.library(),
    ];
  }

  void _openLibrary(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => LibraryView(
          entries: _entries,
          onBack: () => Navigator.of(context).pop(),
          onOpen: (entry) => _openPlayback(context, entry),
          onNewRecording: () {
            Navigator.of(context).pop();
            widget.controller.startRecording();
          },
        ),
      ),
    );
  }

  void _openPlayback(BuildContext context, RecordingEntry entry) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => PlaybackView(
          entry: entry,
          onBack: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  void _openDeveloper(BuildContext context) {
    final navigator = Navigator.of(context);
    final screen = debugOnlyDeveloperView(
      controller: widget.controller,
      onBack: () => navigator.pop(),
    );
    // Null in a release build, where the screen does not exist at all.
    if (screen == null) return;
    navigator.push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;

    if (controller.isRecording || controller.phase == AppPhase.stopping) {
      return RecordingView(controller: controller);
    }
    if (controller.connectedDevice == null) {
      return ScanView(controller: controller);
    }
    return HomeView(
      controller: controller,
      recents: _entries,
      onOpenLibrary: () => _openLibrary(context),
      onOpenRecording: (entry) => _openPlayback(context, entry),
      // The entry point is compiled out with the screen itself.
      onOpenDeveloper: kDebugMode ? () => _openDeveloper(context) : null,
    );
  }
}
