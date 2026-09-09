import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../controller/app_controller.dart';
import 'developer_view.dart';
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
/// Library, playback and the developer screen are pushed on top, because they
/// are places the user chose to go.
class AppRoot extends StatefulWidget {
  const AppRoot({required this.controller, super.key});

  final AppController controller;

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
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
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _heroController.dispose();
    super.dispose();
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
      (context) => LibraryView(
        entries: _entries,
        onBack: () => Navigator.of(context).pop(),
        onOpen: (entry) => _openPlayback(context, entry),
        onNewRecording: () {
          Navigator.of(context).pop();
          widget.controller.startRecording();
        },
      ),
    );
  }

  void _openPlayback(BuildContext context, RecordingEntry entry) {
    _push(
      context,
      (context) => PlaybackView(
        entry: entry,
        onBack: () => Navigator.of(context).pop(),
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
    _push(context, (_) => screen);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final recording =
        controller.isRecording || controller.phase == AppPhase.stopping;
    final connected = controller.connectedDevice != null;
    final instant = AppMotion.isReduced(context);

    return HeroControllerScope(
      controller: _heroController,
      child: Navigator(
        // The page list is a pure function of controller state, so there is
        // nothing for the navigator to remove on its own account.
        onDidRemovePage: (_) {},
        pages: <Page<void>>[
          if (!connected && !recording)
            _DockPage(
              key: const ValueKey<String>('scan'),
              instant: instant,
              child: ScanView(controller: controller),
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
                  // The entry point is compiled out with the screen itself.
                  onOpenDeveloper:
                      kDebugMode ? () => _openDeveloper(context) : null,
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
