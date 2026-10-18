// The build switch for the assistant. Run it both ways:
//
//   tool/flutter_test.sh test/config/
//   tool/flutter_test.sh --dart-define=ASSISTANT=true test/config/
//
// Every other assistant test builds the controller itself, so it passes either
// way. This one goes through `buildAssistant` in `main.dart`, which is what
// the app actually runs, and is the only test that can tell whether a build
// has the feature in it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/config/features.dart';
import 'package:voicenotetaker_app/controller/assistant_controller.dart';
import 'package:voicenotetaker_app/main.dart' show buildAssistant;
import 'package:voicenotetaker_app/view/assistant/assistant_settings_row.dart';
import 'package:voicenotetaker_app/view/settings_view.dart';

import '../assistant/assistant_fakes.dart' as fakes;
import '../view/harness.dart';

void main() {
  setUpAll(registerViewFallbacks);

  AssistantController? built() {
    final assistant = buildAssistant(
      fileStore: fakes.MemoryFileStore(),
      directory: '/support',
      android: false,
    );
    addTearDown(() => assistant?.dispose());
    return assistant;
  }

  test('main builds the assistant exactly when the build asks for it', () {
    expect(built(), kAssistant ? isNotNull : isNull);
  });

  testWidgets('Recorder settings has its row exactly when the build has it',
      (tester) async {
    final harness = ViewHarness();
    addTearDown(harness.dispose);
    await pumpScreen(
      tester,
      SettingsView(
        controller: harness.controller,
        assistant: built(),
        onBack: () {},
        onOpenDiagnostics: () {},
      ),
    );
    // The end rows are below the fold; the list only builds what it shows.
    await tester.drag(
      find
          .descendant(
            of: find.byType(SettingsView),
            matching: find.byType(Scrollable),
          )
          .first,
      const Offset(0, -2000),
    );
    await tester.pumpAndSettle();

    expect(find.text('Diagnostics'), findsOneWidget);
    expect(
      find.byType(AssistantSettingsRow),
      kAssistant ? findsOneWidget : findsNothing,
    );
  });
}
