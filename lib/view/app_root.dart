import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../controller/app_controller.dart';
import '../model/device_state.dart';
import '../model/recording_info.dart';
import 'connection_lost_view.dart';
import 'developer_view.dart';
import 'diagnostics_view.dart';
import 'home_view.dart';
import 'library_view.dart';
import 'playback_view.dart';
import 'recording_entry.dart';
import 'recording_view.dart';
import 'scan_view.dart';
import 'theme.dart';

/// Chooses which of the six screens is on top, and owns navigation between
/// them.
///
/// The three primary screens are still driven by [AppController.phase] rather
/// than by imperative pushes - pairing, home and recording are states of the
/// device, and a stack that could disagree with the radio would be a bug. They
/// are expressed as a DECLARATIVE page list rather than a plain `if`, for one
/// reason: the board that docks into the Home header when you connect is a
/// [Hero], and hero flights are computed by the framework during a route
/// transition. A rebuild that swapped one screen widget for another gives it
/// nothing to fly between.
///
/// Library, playback, diagnostics and the developer screen are pushed on top,
/// because they are places the user chose to go.
class AppRoot extends StatefulWidget {
  const AppRoot({required this.controller, super.key});

  final AppController controller;

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> with WidgetsBindingObserver {
  /// This navigator is nested inside the app's own, so it needs a hero
  /// controller of its own: one controller cannot serve two navigators.
  final HeroController _heroController = HeroController(
    createRectTween: (begin, end) =>
        MaterialRectArcTween(begin: begin, end: end),
  );

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onControllerChanged);
    _heroController.dispose();
    super.dispose();
  }

  /// Re-reads the adapter state when the app comes back to the foreground.
  ///
  /// A BACKSTOP, NOT THE FIX. `AppController` follows the availability stream and
  /// that is what tears the link down when Bluetooth goes off; see
  /// `AppController.refreshAvailability`. This covers the one gap where a missed
  /// event is plausible - the user leaves for the system Bluetooth panel, turns
  /// the radio off there, and comes back - and it costs one platform read on
  /// resume.
  ///
  /// IT LIVES HERE RATHER THAN ON EACH SCREEN because every screen that can
  /// render a connection sits under this widget, and the bug being guarded
  /// against is "any screen showing a link that is gone" rather than "Home
  /// showing it". One observer at the root beats four that can each be forgotten.
  ///
  /// `inactive` is deliberately not acted on - see the note in
  /// `diagnostics_view.dart`; it fires for a notification shade and an app
  /// switcher preview, and neither means the user left.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.controller.refreshAvailability());
    }
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  /// The saved recordings, newest first, as the library service found them.
  List<RecordingEntry> get _entries =>
      widget.controller.recordings.map(RecordingEntry.fromInfo).toList();

  /// Pushes one of the screens the user chose to go to.
  ///
  /// REDUCE MOTION: the push itself is one of the app's one-shot animations,
  /// so under `disableAnimations` it takes no time at all - the next screen is
  /// simply there.
  void _push(BuildContext context, WidgetBuilder builder) {
    Navigator.of(context).push(
      _ScreenRoute<void>(
        builder: builder,
        instant: AppMotion.isReduced(context),
      ),
    );
  }

  void _openLibrary(BuildContext context) {
    _push(
      context,
      // A PUSHED route is not rebuilt by this state's `setState`, so the
      // library listens to the controller itself. Without this, deleting a
      // recording would leave the row it deleted on screen until the user
      // navigated away and back.
      (context) => ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) => LibraryView(
          entries: _entries,
          onBack: () => Navigator.of(context).pop(),
          onOpen: (entry) => _openPlayback(context, entry),
          onDelete: (entry) => _delete(entry),
          onNewRecording: () {
            Navigator.of(context).pop();
            widget.controller.startRecording();
          },
        ),
      ),
    );
  }

  /// Deletes the file behind [entry] through the controller.
  ///
  /// The view asked for confirmation before calling this; the deletion itself
  /// belongs to `LibraryService`, which the controller owns. Nothing in
  /// `view/` goes near the filesystem.
  void _delete(RecordingEntry entry) {
    final recording = _recordingFor(entry);
    if (recording == null) return;
    unawaited(widget.controller.deleteRecording(recording));
  }

  /// The saved file behind [entry], or null if the library does not list it.
  ///
  /// The path is what identifies a recording everywhere below `view/` - it is
  /// the key [AppController] itself compares - and it is the one thing a
  /// [RecordingEntry] carries over from the [RecordingInfo] it was projected
  /// from, so it is what the two are matched on here.
  RecordingInfo? _recordingFor(RecordingEntry entry) {
    final path = entry.path;
    if (path == null) return null;
    for (final info in widget.controller.recordings) {
      if (info.path == path) return info;
    }
    return null;
  }

  void _openPlayback(BuildContext context, RecordingEntry entry) {
    // Resolved as the screen is pushed, so playback is loaded from the file
    // the user actually tapped rather than from whatever the list holds later.
    final recording = _recordingFor(entry);
    _push(
      context,
      (context) => PlaybackView(
        controller: widget.controller,
        entry: entry,
        recording: recording,
        // The screen is showing a file that no longer exists, so it leaves.
        onDeleted: () => Navigator.of(context).pop(),
        onBack: () => Navigator.of(context).pop(),
      ),
    );
  }

  /// Pushes Device Diagnostics, and hands it the door to Developer options.
  ///
  /// Diagnostics is in every build; the developer callback it is given is null
  /// outside debug, which is what removes the button rather than leaving one that
  /// does nothing.
  void _openDiagnostics(BuildContext context) {
    _push(
      context,
      (context) => DiagnosticsView(
        controller: widget.controller,
        onBack: () => Navigator.of(context).pop(),
        onOpenDeveloper:
            kDebugMode ? () => _openDeveloper(context) : null,
      ),
    );
  }

  void _openDeveloper(BuildContext context) {
    // The gate is called first, because in a release build there is no screen to
    // push and the route must not be created at all.
    if (debugOnlyDeveloperView(controller: widget.controller) == null) return;
    _push(
      context,
      // Built inside the route's own builder, and the back callback resolves its
      // navigator from the ROUTE's context rather than from a NavigatorState
      // captured out here. A captured state is the wrong one as soon as this
      // screen is pushed from somewhere new, and "Back does nothing" is a
      // maddening way to find that out.
      (context) =>
          debugOnlyDeveloperView(
            controller: widget.controller,
            onBack: () => Navigator.of(context).pop(),
          ) ??
          const SizedBox.shrink(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final recording =
        controller.isRecording || controller.phase == AppPhase.stopping;
    final connected = controller.connectedDevice != null;
    // A link that dropped by itself gets Home's slot, not the scan screen's:
    // see `ConnectionLostView`. A disconnect the user asked for leaves
    // `linkOutcome` at `none` and so lands back on the scan screen as before.
    final lost = !connected &&
        !recording &&
        controller.linkOutcome == LinkOutcome.connectionLost;
    final instant = AppMotion.isReduced(context);

    return HeroControllerScope(
      controller: _heroController,
      child: Navigator(
        // The page list is a pure function of controller state, so there is
        // nothing for the navigator to remove on its own account.
        onDidRemovePage: (_) {},
        pages: <Page<void>>[
          if (!connected && !recording && !lost)
            _DockPage(
              key: const ValueKey<String>('scan'),
              instant: instant,
              child: Builder(
                builder: (context) => ScanView(
                  controller: controller,
                  // The unsupported-phone screen's only action.
                  onOpenLibrary: () => _openLibrary(context),
                ),
              ),
            ),
          if (lost)
            _DockPage(
              key: const ValueKey<String>('connection-lost'),
              instant: instant,
              child: ConnectionLostView(controller: controller),
            ),
          if (connected)
            _DockPage(
              key: const ValueKey<String>('home'),
              instant: instant,
              child: Builder(
                builder: (context) => HomeView(
                  controller: controller,
                  recents: _entries,
                  onOpenLibrary: () => _openLibrary(context),
                  onOpenRecording: (entry) => _openPlayback(context, entry),
                  // Always offered: Diagnostics is an observer's screen and
                  // ships in release builds. The debug gate is one tap further
                  // in, on Developer options.
                  onOpenDiagnostics: () => _openDiagnostics(context),
                ),
              ),
            ),
          if (recording)
            _DockPage(
              key: const ValueKey<String>('recording'),
              instant: instant,
              child: RecordingView(controller: controller),
            ),
        ],
      ),
    );
  }
}

/// A page that cross-fades rather than sliding, so the docking [Hero] is the
/// only thing moving during the transition.
///
/// REDUCE MOTION: with [instant] set the transition takes no time at all,
/// which also means the framework never runs a hero flight - the board is
/// simply in the header on the next frame.
class _DockPage extends Page<void> {
  const _DockPage({
    required this.child,
    required this.instant,
    required LocalKey super.key,
  });

  final Widget child;
  final bool instant;

  @override
  Route<void> createRoute(BuildContext context) => _DockRoute(this);
}

/// The route behind a [_DockPage].
///
/// It reads its content back out of `settings` on every build rather than
/// capturing it once. A route is created only for a NEW page key, so a
/// `PageRouteBuilder` closing over the widget it was handed would pin the
/// screen to whatever the controller's state was at the moment the page first
/// appeared - the scan screen would never show a device it discovered.
class _DockRoute extends PageRoute<void> {
  _DockRoute(_DockPage page) : super(settings: page);

  _DockPage get _page => settings as _DockPage;

  @override
  Duration get transitionDuration =>
      _page.instant ? Duration.zero : AppMotion.dock;

  @override
  Duration get reverseTransitionDuration => transitionDuration;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      _page.child;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      FadeTransition(opacity: animation, child: child);
}

/// A pushed screen - the library, playback, the developer view.
///
/// A plain [MaterialPageRoute], except that reduce motion collapses the
/// transition to nothing rather than sliding a screen in.
class _ScreenRoute<T> extends MaterialPageRoute<T> {
  _ScreenRoute({required super.builder, required this.instant});

  final bool instant;

  @override
  Duration get transitionDuration =>
      instant ? Duration.zero : super.transitionDuration;

  @override
  Duration get reverseTransitionDuration =>
      instant ? Duration.zero : super.reverseTransitionDuration;
}
