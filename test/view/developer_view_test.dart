import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/audio_codec.dart';
import 'package:voicenotetaker_app/model/device_state.dart';
import 'package:voicenotetaker_app/view/developer_view.dart';

import 'harness.dart';

void main() {
  setUpAll(registerViewFallbacks);

  // -------------------------------------------------------------------------
  // THE DEBUG-ONLY GUARANTEE
  //
  // `flutter test` always runs a DEBUG build - kDebugMode is true and there is
  // no way to flip it from inside a test - so the release half of the gate
  // cannot be exercised at runtime here. It is covered two ways instead:
  //
  //   * the debug half is asserted below (the gate returns the screen), and
  //   * the source is asserted to contain exactly one construction of
  //     DeveloperView, inside an `if (kDebugMode)`. Because kDebugMode is a
  //     compile-time constant, that branch is dead code in a release build and
  //     the screen is tree-shaken out of the binary.
  //
  // A true end-to-end check would mean building a release binary and grepping
  // its symbols, which is a job for CI, not for `flutter test`.
  // -------------------------------------------------------------------------
  group('release gating', () {
    test('tests themselves run in debug mode', () {
      expect(kDebugMode, isTrue,
          reason: 'the assertions below describe the debug half of the gate');
    });

    test('the gate hands back the screen in a debug build', () {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      final screen = debugOnlyDeveloperView(controller: harness.controller);
      expect(screen, isA<DeveloperView>());
    });

    test('DeveloperView is constructed nowhere but inside the kDebugMode gate',
        () {
      // `debugOnlyDeveloperView(` contains the class name as a substring, so
      // match only a real constructor call.
      final construction = RegExp(r'(?<![A-Za-z_])DeveloperView\(');
      final sources = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));

      for (final source in sources) {
        final text = source.readAsStringSync();
        if (source.path.endsWith('developer_view.dart')) continue;
        expect(
          construction.hasMatch(text),
          isFalse,
          reason: '${source.path} constructs DeveloperView outside the gate',
        );
      }

      final gate = File('lib/view/developer_view.dart').readAsStringSync();
      // Two mentions with a paren after them: the class's own constructor
      // declaration, and the single construction inside the gate.
      expect(construction.allMatches(gate), hasLength(2));
      expect(
        RegExp(r'return DeveloperView\(').allMatches(gate),
        hasLength(1),
      );
      expect(
        gate.contains('if (kDebugMode) {\n    return DeveloperView('),
        isTrue,
        reason: 'the single construction must sit inside `if (kDebugMode)`',
      );
    });
  });

  group('the screen', () {
    testWidgets('builds disconnected', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await pumpScreen(
        tester,
        DeveloperView(controller: harness.controller),
      );

      expect(find.text('Developer'), findsOneWidget);
      expect(find.text('DEBUG ONLY'), findsOneWidget);
      expect(find.text('LINK'), findsOneWidget);
      expect(find.text('STREAM'), findsOneWidget);
      expect(find.text('CODEC'), findsOneWidget);
      expect(find.text('Export diagnostics'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows the link and stream readings it really has',
        (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);

      await harness.discover(tester);
      await harness.connect(tester);
      await pumpScreen(
        tester,
        DeveloperView(controller: harness.controller),
      );

      expect(find.text('EB:6B:5E:4C:33:A3'), findsOneWidget);
      expect(find.text('−54 dBm'), findsOneWidget);
      expect(find.text('0 (0.00%)'), findsOneWidget);

      // ATT MTU, interval, PHY, throughput and the jitter buffer are not
      // exposed by BleTransport, so they read as unknown rather than invented.
      expect(find.text('—'), findsNWidgets(5));
    });

    testWidgets('the codec selector drives the controller', (tester) async {
      final harness = ViewHarness();
      addTearDown(harness.dispose);

      await pumpScreen(
        tester,
        DeveloperView(controller: harness.controller),
      );

      expect(harness.controller.preferredCodec, AudioCodec.imaAdpcm);

      await tester.tap(find.text('Raw PCM'));
      await tester.pump();

      expect(harness.controller.preferredCodec, AudioCodec.pcmS16le);
    });

    testWidgets('Export diagnostics produces a report', (tester) async {
      final harness =
          ViewHarness(devices: const <DiscoveredDevice>[knownDevice]);
      addTearDown(harness.dispose);

      await harness.discover(tester);
      await harness.connect(tester);
      await pumpScreen(
        tester,
        DeveloperView(controller: harness.controller),
      );

      await tester.tap(find.text('Export diagnostics'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Diagnostics'), findsOneWidget);
      expect(
        find.textContaining('address: EB:6B:5E:4C:33:A3'),
        findsOneWidget,
      );
    });
  });
}
