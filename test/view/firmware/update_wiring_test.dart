import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/view/app_root.dart';
import 'package:voicenotetaker_app/view/firmware/update_view.dart';
import 'package:voicenotetaker_app/view/settings_view.dart';

import '../harness.dart';
import 'update_fakes.dart';

/// `AppRoot` hands the service to Today and Settings, and both doors open the
/// same update screen.
void main() {
  setUpAll(registerViewFallbacks);

  /// Past a pushed route's transition; Home's breathing dot never settles.
  Future<void> settleRoute(WidgetTester tester) async {
    await flush(tester);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await flush(tester);
  }

  testWidgets('Today\'s row and Settings\' Software row open the update screen',
      (tester) async {
    final harness = ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
    addTearDown(harness.dispose);
    final updates = offered();

    await pumpScreen(
        tester, AppRoot(controller: harness.controller, firmware: updates));
    await harness.discover(tester);
    await harness.connect(tester);
    await settleDock(tester);

    await tester.tap(find.text('A recorder update is ready'));
    await settleRoute(tester);
    expect(find.byType(UpdateView), findsOneWidget);
    expect(find.text('Version 0.2.0, published 14 Oct'), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await settleRoute(tester);
    expect(find.byType(UpdateView), findsNothing);

    await tester.tap(find.bySemanticsLabel('Settings'));
    await settleRoute(tester);
    await tester.scrollUntilVisible(find.text('Software'), 200,
        scrollable: find
            .descendant(of: find.byType(SettingsView), matching: find.byType(Scrollable))
            .first);
    await tester.tap(find.text('Software'));
    await settleRoute(tester);
    expect(find.byType(UpdateView), findsOneWidget);
  });
}
