import 'package:flutter/widgets.dart';

import '../../controller/summary_controller.dart';

/// Makes the [SummaryController] reachable from any screen under `AppRoot`,
/// so a screen that did not create it - the note screen's "Summarize with your
/// AI" button - can open the Summarize sheet with only a [BuildContext].
class SummaryScope extends InheritedWidget {
  const SummaryScope({required this.summaries, required super.child, super.key});

  final SummaryController summaries;

  static SummaryController? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SummaryScope>()?.summaries;

  @override
  bool updateShouldNotify(SummaryScope oldWidget) => oldWidget.summaries != summaries;
}
