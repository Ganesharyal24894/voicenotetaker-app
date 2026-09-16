import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/view/theme.dart';
import 'package:voicenotetaker_app/view/widgets/common.dart';

import 'harness.dart';

/// THE ACCESSIBILITY REQUIREMENT FOR EVERY BUTTON IN THE APP.
///
/// [PrimaryButton], [QuietButton] and [SegmentButton] each wrap a
/// [GestureDetector] in a [Semantics] that EXCLUDES its descendants - which
/// drops the detector's own tap action with them. Without `onTap` declared on
/// the wrapper, a screen reader reads out a button and then cannot activate
/// it: the control is unreachable to anybody who is not touching the pixels.
/// These tests assert the action is there, and that it really runs.
void main() {
  /// Runs a control's tap the way a screen reader does - through the
  /// semantics tree, not by tapping the screen. Throws if the node has no tap
  /// action to run, which is the bug these tests exist for.
  void activate(WidgetTester tester, String label) => tester.semantics
      .performAction(find.semantics.byLabel(label), SemanticsAction.tap);

  testWidgets('PrimaryButton is a button a screen reader can activate',
      (tester) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await pumpScreen(
      tester,
      Scaffold(
        backgroundColor: AppColors.screen,
        body: Center(
          child: PrimaryButton(label: 'Summarize', onPressed: () => taps++),
        ),
      ),
    );

    expect(
      tester.getSemantics(find.bySemanticsLabel('Summarize')),
      matchesSemantics(
        label: 'Summarize',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );

    activate(tester, 'Summarize');
    expect(taps, 1);
    handle.dispose();
  });

  testWidgets('a disabled PrimaryButton says so, and does nothing',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pumpScreen(
      tester,
      const Scaffold(
        backgroundColor: AppColors.screen,
        body: Center(child: PrimaryButton(label: 'Merge', onPressed: null)),
      ),
    );

    expect(
      tester.getSemantics(find.bySemanticsLabel('Merge')),
      matchesSemantics(
        label: 'Merge',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    handle.dispose();
  });

  testWidgets('QuietButton is a button a screen reader can activate',
      (tester) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await pumpScreen(
      tester,
      Scaffold(
        backgroundColor: AppColors.screen,
        body: Center(
          child: QuietButton(label: 'Cancel', onPressed: () => taps++),
        ),
      ),
    );

    expect(
      tester.getSemantics(find.bySemanticsLabel('Cancel')),
      matchesSemantics(
        label: 'Cancel',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );

    activate(tester, 'Cancel');
    expect(taps, 1);
    handle.dispose();
  });

  testWidgets('SegmentButton is a selectable button, and activates',
      (tester) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await pumpScreen(
      tester,
      Scaffold(
        backgroundColor: AppColors.screen,
        body: Center(
          child: Row(
            children: <Widget>[
              Expanded(
                child: SegmentButton(
                  label: 'Auto',
                  semanticLabel: 'How many people spoke: work it out for me',
                  selected: true,
                  onTap: () => taps++,
                ),
              ),
              Expanded(
                child: SegmentButton(
                  label: '3',
                  semanticLabel: 'How many people spoke: 3',
                  selected: false,
                  onTap: () => taps++,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final three = find.bySemanticsLabel('How many people spoke: 3');
    expect(
      tester.getSemantics(three),
      matchesSemantics(
        label: 'How many people spoke: 3',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasSelectedState: true,
        isSelected: false,
        hasTapAction: true,
      ),
    );
    // The chosen one reads as chosen, which is the whole point of a segment.
    expect(
      tester.getSemantics(
        find.bySemanticsLabel('How many people spoke: work it out for me'),
      ),
      matchesSemantics(
        label: 'How many people spoke: work it out for me',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasSelectedState: true,
        isSelected: true,
        hasTapAction: true,
      ),
    );

    activate(tester, 'How many people spoke: 3');
    expect(taps, 1);
    handle.dispose();
  });

  testWidgets('a disabled SegmentButton has no tap action to offer',
      (tester) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await pumpScreen(
      tester,
      Scaffold(
        backgroundColor: AppColors.screen,
        body: Center(
          child: SegmentButton(
            label: 'On',
            semanticLabel: 'Auto-sleep: on',
            selected: false,
            enabled: false,
            onTap: () => taps++,
          ),
        ),
      ),
    );

    expect(
      tester.getSemantics(find.bySemanticsLabel('Auto-sleep: on')),
      matchesSemantics(
        label: 'Auto-sleep: on',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
        hasSelectedState: true,
        isSelected: false,
      ),
    );
    expect(taps, 0);
    handle.dispose();
  });
}
