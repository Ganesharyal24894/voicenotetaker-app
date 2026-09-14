import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/view/scan_view.dart';
import 'package:voicenotetaker_app/view/widgets/device_mark.dart';

import 'harness.dart';

// The Home header no longer carries the mark: the approved home redesign
// (`doc/today-and-summaries.md`) gives the header to the saving status, the
// battery, record and the menu. The mark stays on the scan screen's card.
void main() {
  setUpAll(registerViewFallbacks);

  testWidgets('the scan screen shows the same mark on the recorder card',
      (tester) async {
    final harness = ViewHarness(
      devices: const <DiscoveredDevice>[knownDevice, unknownDevice],
    );
    addTearDown(harness.dispose);

    await harness.discover(tester);
    await pumpScreen(tester, ScanView(controller: harness.controller));
    await tester.pump(const Duration(seconds: 3));

    // One mark, on the recorder - not on the anonymous radio beside it.
    expect(find.byType(DeviceMark), findsOneWidget);
    final hero = tester.widget<Hero>(
      find.ancestor(of: find.byType(DeviceMark), matching: find.byType(Hero)),
    );
    expect(hero.tag, ScanView.deviceMarkHeroTag);
  });

  test('the mark keeps the symbol aspect ratio at any width', () {
    expect(const DeviceMark().height, DeviceMark.slotHeight);
    expect(
      const DeviceMark(width: 76).height,
      moreOrLessEquals(DeviceMark.slotHeight * 2, epsilon: 0.001),
    );
  });
}
