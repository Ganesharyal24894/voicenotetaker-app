import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/controller/models_controller.dart';
import 'package:voicenotetaker_app/drivers/download_client.dart';
import 'package:voicenotetaker_app/drivers/hashing_crypto.dart';
import 'package:voicenotetaker_app/drivers/network_status.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/transcription/model_download_service.dart';
import 'package:voicenotetaker_app/model/model_download.dart';
import 'package:voicenotetaker_app/view/models_view.dart';
import 'package:voicenotetaker_app/view/widgets/common.dart';
import 'package:voicenotetaker_app/view/widgets/home_widgets.dart';

import 'harness.dart';

/// The speech-model downloader's screens.
///
/// DRIVEN BY A FAKE CONTROLLER, deliberately: these tests are about what the
/// screen says and what it ASKS FOR, and a real downloader would put a network,
/// a disk and 197 MB between the tap and the assertion. What the downloader
/// itself does with those asks is `model_download_service_test.dart`; that the
/// controller relays them is `model_downloads_controller_test.dart`.
class FakeModels extends ChangeNotifier implements ModelsController {
  FakeModels() {
    for (final release in ModelCatalogue.all) {
      _statuses[release.feature] = ModelInstallStatus.unknown(release);
    }
  }

  final Map<ModelFeature, ModelInstallStatus> _statuses =
      <ModelFeature, ModelInstallStatus>{};

  /// Every call the screen made, newest last, as `name(feature)`.
  final List<String> calls = <String>[];

  bool _mobileData = false;

  /// Puts one set into a state, the way the downloader's own stream would.
  void set(
    ModelFeature feature, {
    ModelInstallState state = ModelInstallState.notInstalled,
    int bytesDone = 0,
    ModelDownloadFailure? failure,
    bool paused = false,
  }) {
    _statuses[feature] = ModelInstallStatus(
      release: ModelCatalogue.forFeature(feature),
      state: state,
      bytesDone: state == ModelInstallState.installed
          ? ModelCatalogue.forFeature(feature).totalBytes
          : bytesDone,
      failure: failure,
      paused: paused,
    );
    notifyListeners();
  }

  @override
  List<ModelInstallStatus> get modelStatuses => <ModelInstallStatus>[
        for (final release in ModelCatalogue.all) _statuses[release.feature]!,
      ];

  @override
  ModelInstallStatus modelStatusFor(ModelFeature feature) =>
      _statuses[feature]!;

  @override
  int get installedModelBytes {
    var total = 0;
    for (final status in modelStatuses) {
      if (status.isInstalled) total += status.bytesTotal;
    }
    return total;
  }

  @override
  bool get downloadOnMobileData => _mobileData;

  @override
  Future<void> setDownloadOnMobileData(bool allowed) async {
    calls.add('setDownloadOnMobileData($allowed)');
    _mobileData = allowed;
    notifyListeners();
  }

  @override
  Future<void> downloadModel(ModelFeature feature) async {
    calls.add('downloadModel(${feature.name})');
    set(feature, state: ModelInstallState.downloading);
  }

  @override
  Future<void> cancelModelDownload(ModelFeature feature) async {
    calls.add('cancelModelDownload(${feature.name})');
    set(
      feature,
      bytesDone: _statuses[feature]!.bytesDone,
    );
  }

  @override
  Future<void> deleteModel(ModelFeature feature) async {
    calls.add('deleteModel(${feature.name})');
    set(feature);
  }

  @override
  Future<void> refreshModels() async {
    calls.add('refreshModels()');
  }
}

const int _hindi = 197051093;
const int _english = 136490421;
const int _speakers = 34274077;

Future<FakeModels> _setup(
  WidgetTester tester, {
  FakeModels? models,
  VoidCallback? onBack,
}) async {
  final fake = models ?? FakeModels();
  addTearDown(fake.dispose);
  await pumpScreen(
    tester,
    ModelsSetupView(models: fake, onBack: onBack),
  );
  return fake;
}

Future<FakeModels> _settings(
  WidgetTester tester, {
  FakeModels? models,
}) async {
  final fake = models ?? FakeModels();
  addTearDown(fake.dispose);
  await pumpScreen(tester, ModelsSettingsView(models: fake));
  return fake;
}

void main() {
  group('the catalogue the design was drawn against', () {
    test('is still the same three sizes', () {
      // The artboards print 197 MB, 136 MB, 34 MB and a 231 MB total. If a new
      // release tag changes a file, this is where it is noticed rather than in
      // a screenshot nobody re-took.
      expect(ModelCatalogue.hindiSpeech.totalBytes, _hindi);
      expect(ModelCatalogue.englishSpeech.totalBytes, _english);
      expect(ModelCatalogue.speakerDetection.totalBytes, _speakers);
      expect(formatBytes(_hindi), '197 MB');
      expect(formatBytes(_english), '136 MB');
      expect(formatBytes(_speakers), '34 MB');
      expect(formatBytes(_hindi + _speakers), '231 MB');
    });
  });

  group('the progress label', () {
    test('says the unit once when both numbers share it', () {
      expect(ModelsCopy.progressLabel(70000000, _hindi), '70 of 197 MB');
      expect(
        ModelsCopy.progressLabel(104000000, _hindi + _speakers),
        '104 of 231 MB',
      );
    });

    test('says both units when they differ', () {
      expect(ModelsCopy.progressLabel(9700, _hindi), '9.7 kB of 197 MB');
    });

    test('nothing downloaded is nothing, not a blank', () {
      expect(ModelsCopy.progressLabel(0, _hindi), '0 B of 197 MB');
    });
  });

  group('setup: nothing installed', () {
    testWidgets('lists the three sets, their sizes and what each one does',
        (tester) async {
      await _setup(tester);

      expect(find.text(ModelsCopy.setupTitle), findsOneWidget);
      expect(find.text(ModelsCopy.setupBody), findsOneWidget);
      expect(find.text(ModelsCopy.pick.toUpperCase()), findsOneWidget);
      for (final feature in ModelFeature.values) {
        expect(find.text(ModelsCopy.nameOf(feature)), findsOneWidget);
        expect(find.text(ModelsCopy.enablesOf(feature)), findsOneWidget);
      }
      expect(find.text('197 MB'), findsOneWidget);
      expect(find.text('136 MB'), findsOneWidget);
      expect(find.text('34 MB'), findsOneWidget);
    });

    testWidgets('Hindi and speaker detection are ticked, English is not',
        (tester) async {
      await _setup(tester);

      expect(_checked(tester, ModelFeature.hindiSpeech), isTrue);
      expect(_checked(tester, ModelFeature.speakerDetection), isTrue);
      expect(_checked(tester, ModelFeature.englishSpeech), isFalse);
    });

    testWidgets('the one-time total is what is ticked', (tester) async {
      await _setup(tester);

      expect(find.text(ModelsCopy.oneTimeDownload), findsOneWidget);
      expect(find.text('231 MB'), findsOneWidget);
    });

    testWidgets('ticking English adds its size; unticking takes it off',
        (tester) async {
      await _setup(tester);

      await _tick(tester, ModelFeature.englishSpeech);
      expect(find.text('368 MB'), findsOneWidget);

      await _tick(tester, ModelFeature.englishSpeech);
      expect(find.text('231 MB'), findsOneWidget);
    });

    testWidgets('with nothing ticked there is nothing to download',
        (tester) async {
      await _setup(tester);

      await _tick(tester, ModelFeature.hindiSpeech);
      await _tick(tester, ModelFeature.speakerDetection);

      expect(find.text('0 B'), findsOneWidget);
      final button = tester.widget<PrimaryButton>(
        find.widgetWithText(PrimaryButton, ModelsCopy.download),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('says downloads wait for Wi-Fi', (tester) async {
      await _setup(tester);

      expect(find.text(ModelsCopy.wifiOnly), findsOneWidget);
    });

    testWidgets('with mobile data allowed it says that instead',
        (tester) async {
      final models = FakeModels();
      await models.setDownloadOnMobileData(true);
      await _setup(tester, models: models);

      expect(find.text(ModelsCopy.mobileAllowed), findsOneWidget);
      expect(find.text(ModelsCopy.wifiOnly), findsNothing);
    });

    testWidgets('Download asks for exactly what is ticked', (tester) async {
      final models = await _setup(tester);
      models.calls.clear();

      await tester.tap(find.text(ModelsCopy.download));
      await tester.pump();

      expect(models.calls, <String>[
        'downloadModel(hindiSpeech)',
        'downloadModel(speakerDetection)',
      ]);
    });
  });

  group('setup: part of it is already here', () {
    testWidgets('an installed set says so and is not charged for again',
        (tester) async {
      final models = FakeModels()
        ..set(ModelFeature.speakerDetection,
            state: ModelInstallState.installed);
      await _setup(tester, models: models);

      expect(find.text(ModelsCopy.installedNote), findsOneWidget);
      // 231 MB less the 34 MB already here.
      expect(find.text('197 MB'), findsNWidgets(2));
      expect(find.text('231 MB'), findsNothing);
    });

    testWidgets('a part-downloaded set is charged for what is left',
        (tester) async {
      final models = FakeModels()
        ..set(ModelFeature.hindiSpeech, bytesDone: 97051093);
      await _setup(tester, models: models);

      // 100 MB of Hindi left, plus all 34 MB of speaker detection.
      expect(find.text('134 MB'), findsOneWidget);
    });

    testWidgets('Download skips what is already installed', (tester) async {
      final models = FakeModels()
        ..set(ModelFeature.hindiSpeech, state: ModelInstallState.installed);
      await _setup(tester, models: models);
      models.calls.clear();

      await tester.tap(find.text(ModelsCopy.download));
      await tester.pump();

      expect(models.calls, <String>['downloadModel(speakerDetection)']);
    });
  });

  group('downloading', () {
    testWidgets('shows a row per set, an overall line and the platform note',
        (tester) async {
      final models = await _setup(tester);
      models.set(ModelFeature.hindiSpeech,
          state: ModelInstallState.downloading, bytesDone: 70000000);
      models.set(ModelFeature.speakerDetection,
          state: ModelInstallState.installed);
      await tester.tap(find.text(ModelsCopy.download));
      await tester.pump();
      models.set(ModelFeature.hindiSpeech,
          state: ModelInstallState.downloading, bytesDone: 70000000);
      await tester.pump();

      expect(find.text(ModelsCopy.downloadingTitle), findsOneWidget);
      expect(find.text(ModelsCopy.languagePacks.toUpperCase()), findsOneWidget);
      expect(find.text('70 of 197 MB'), findsOneWidget);
      expect(find.text(ModelsCopy.doneLabel), findsOneWidget);
      expect(find.text('104 of 231 MB'), findsOneWidget);
      expect(find.text('45%'), findsOneWidget);
      expect(find.text(ModelsCopy.platformNote), findsOneWidget);
      expect(find.text(ModelsCopy.pause), findsOneWidget);
      expect(find.text(ModelsCopy.cancel), findsOneWidget);
    });

    testWidgets('progress follows the controller without a rebuild from here',
        (tester) async {
      final models = await _setup(tester);
      await tester.tap(find.text(ModelsCopy.download));
      await tester.pump();

      models.set(ModelFeature.hindiSpeech,
          state: ModelInstallState.downloading, bytesDone: 20000000);
      await tester.pump();
      expect(find.text('20 of 197 MB'), findsOneWidget);

      models.set(ModelFeature.hindiSpeech,
          state: ModelInstallState.downloading, bytesDone: 150000000);
      await tester.pump();
      expect(find.text('150 of 197 MB'), findsOneWidget);
    });

    testWidgets('verifying says it is being checked', (tester) async {
      final models = await _setup(tester);
      await tester.tap(find.text(ModelsCopy.download));
      await tester.pump();

      models.set(ModelFeature.hindiSpeech,
          state: ModelInstallState.verifying, bytesDone: _hindi);
      await tester.pump();

      expect(find.text(ModelsCopy.checking), findsOneWidget);
    });

    testWidgets('a failure prints the downloader\'s own words, and offers to '
        'try again', (tester) async {
      final models = await _setup(tester);
      await tester.tap(find.text(ModelsCopy.download));
      await tester.pump();

      models.set(
        ModelFeature.hindiSpeech,
        state: ModelInstallState.failed,
        bytesDone: 12000000,
        failure: ModelDownloadFailure.network('socket'),
      );
      models.set(ModelFeature.speakerDetection,
          state: ModelInstallState.installed);
      await tester.pump();

      expect(
        find.text(ModelDownloadFailure.network().message),
        findsOneWidget,
      );
      expect(find.textContaining('socket'), findsNothing);
      expect(find.text(ModelsCopy.tryAgain), findsOneWidget);

      models.calls.clear();
      await tester.tap(find.text(ModelsCopy.tryAgain));
      await tester.pump();
      expect(models.calls, contains('downloadModel(hindiSpeech)'));
    });

    testWidgets('no room: says how much to free', (tester) async {
      final models = await _setup(tester);
      await tester.tap(find.text(ModelsCopy.download));
      await tester.pump();

      models.set(
        ModelFeature.hindiSpeech,
        state: ModelInstallState.failed,
        failure: ModelDownloadFailure.notEnoughSpace(
          neededBytes: _hindi,
          freeBytes: 100000000,
        ),
      );
      await tester.pump();

      expect(find.textContaining('not enough room'), findsOneWidget);
      expect(find.textContaining('97 MB'), findsOneWidget);
    });

    testWidgets('waiting for Wi-Fi: says so, and does not pretend to run',
        (tester) async {
      final models = await _setup(tester);
      await tester.tap(find.text(ModelsCopy.download));
      await tester.pump();

      models.set(
        ModelFeature.hindiSpeech,
        state: ModelInstallState.failed,
        failure: ModelDownloadFailure.needsWifi,
      );
      models.set(ModelFeature.speakerDetection,
          state: ModelInstallState.installed);
      await tester.pump();

      expect(find.text(ModelDownloadFailure.needsWifi.message), findsOneWidget);
      // Nothing is running, so the screen does not offer to pause it.
      expect(find.text(ModelsCopy.pause), findsNothing);
      expect(find.text(ModelsCopy.tryAgain), findsOneWidget);
    });

    testWidgets('Pause stops what is running and offers Resume',
        (tester) async {
      final models = await _setup(tester);
      await tester.tap(find.text(ModelsCopy.download));
      await tester.pump();
      models.calls.clear();

      await tester.tap(find.text(ModelsCopy.pause));
      await tester.pump();

      expect(models.calls, <String>[
        'cancelModelDownload(hindiSpeech)',
        'cancelModelDownload(speakerDetection)',
      ]);
      expect(find.text(ModelsCopy.resume), findsOneWidget);

      models.calls.clear();
      await tester.tap(find.text(ModelsCopy.resume));
      await tester.pump();
      expect(models.calls, contains('downloadModel(hindiSpeech)'));
    });

    testWidgets('the app going off screen is shown as paused, not as stalled',
        (tester) async {
      final models = await _setup(tester);
      await tester.tap(find.text(ModelsCopy.download));
      await tester.pump();

      models.set(
        ModelFeature.hindiSpeech,
        state: ModelInstallState.downloading,
        bytesDone: 5000000,
        paused: true,
      );
      await tester.pump();

      expect(find.textContaining('Paused'), findsOneWidget);
    });

    testWidgets('Cancel stops everything and goes back to the picker',
        (tester) async {
      final models = await _setup(tester);
      await tester.tap(find.text(ModelsCopy.download));
      await tester.pump();
      models.calls.clear();

      await tester.tap(find.text(ModelsCopy.cancel));
      await tester.pump();

      expect(models.calls, contains('cancelModelDownload(hindiSpeech)'));
      expect(find.text(ModelsCopy.setupTitle), findsOneWidget);
      expect(find.text(ModelsCopy.pick.toUpperCase()), findsOneWidget);
    });

    testWidgets('finished: says so and offers the way out', (tester) async {
      var left = false;
      final models = await _setup(tester, onBack: () => left = true);
      await tester.tap(find.text(ModelsCopy.download));
      await tester.pump();

      models.set(ModelFeature.hindiSpeech, state: ModelInstallState.installed);
      models.set(ModelFeature.speakerDetection,
          state: ModelInstallState.installed);
      await tester.pump();

      expect(find.text(ModelsCopy.ready), findsOneWidget);
      await tester
          .tap(find.widgetWithText(PrimaryButton, ModelsCopy.done));
      await tester.pump();
      expect(left, isTrue);
    });

    testWidgets('a download already running is shown when the screen opens',
        (tester) async {
      final models = FakeModels()
        ..set(ModelFeature.hindiSpeech,
            state: ModelInstallState.downloading, bytesDone: 1000000);
      await _setup(tester, models: models);

      expect(find.text(ModelsCopy.downloadingTitle), findsOneWidget);
    });
  });

  group('settings', () {
    testWidgets('installed sets carry their size and a way to remove them',
        (tester) async {
      final models = FakeModels()
        ..set(ModelFeature.hindiSpeech, state: ModelInstallState.installed)
        ..set(ModelFeature.speakerDetection,
            state: ModelInstallState.installed);
      await _settings(tester, models: models);

      expect(find.text(ModelsCopy.onThisPhone.toUpperCase()), findsOneWidget);
      expect(find.text('197 MB'), findsOneWidget);
      expect(find.text('34 MB'), findsOneWidget);
      expect(find.text(ModelsCopy.remove), findsNWidgets(2));
      expect(find.text(ModelsCopy.notDownloaded.toUpperCase()), findsOneWidget);
      expect(find.text(ModelsCopy.download), findsOneWidget);
      expect(find.text('136 MB'), findsOneWidget);
    });

    testWidgets('the space used is what is installed', (tester) async {
      final models = FakeModels()
        ..set(ModelFeature.hindiSpeech, state: ModelInstallState.installed)
        ..set(ModelFeature.speakerDetection,
            state: ModelInstallState.installed);
      await _settings(tester, models: models);

      expect(find.text(ModelsCopy.spaceUsed), findsOneWidget);
      expect(find.text('231 MB'), findsOneWidget);
    });

    testWidgets('with nothing installed there is no "on this phone" list',
        (tester) async {
      await _settings(tester);

      expect(find.text(ModelsCopy.onThisPhone.toUpperCase()), findsNothing);
      expect(find.text(ModelsCopy.download), findsNWidgets(3));
      expect(find.text('0 B'), findsOneWidget);
    });

    testWidgets('Remove asks first, and Cancel removes nothing',
        (tester) async {
      final models = FakeModels()
        ..set(ModelFeature.hindiSpeech, state: ModelInstallState.installed);
      await _settings(tester, models: models);
      models.calls.clear();

      await tester
          .tap(find.bySemanticsLabel('Remove Hindi transcription'));
      await tester.pumpAndSettle();

      expect(find.text('Remove Hindi transcription?'), findsOneWidget);
      expect(find.textContaining('197 MB'), findsWidgets);

      await tester.tap(find.widgetWithText(TextButton, ModelsCopy.cancel));
      await tester.pumpAndSettle();

      expect(models.calls, isEmpty);
      expect(models.modelStatusFor(ModelFeature.hindiSpeech).isInstalled,
          isTrue);
    });

    testWidgets('Remove, confirmed, removes it and frees the space',
        (tester) async {
      final models = FakeModels()
        ..set(ModelFeature.hindiSpeech, state: ModelInstallState.installed);
      await _settings(tester, models: models);

      await tester
          .tap(find.bySemanticsLabel('Remove Hindi transcription'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, ModelsCopy.remove));
      await tester.pumpAndSettle();

      expect(models.calls, contains('deleteModel(hindiSpeech)'));
      expect(find.text(ModelsCopy.onThisPhone.toUpperCase()), findsNothing);
      expect(find.text('0 B'), findsOneWidget);
    });

    testWidgets('Download starts one set and shows it running', (tester) async {
      final models = await _settings(tester);

      await tester
          .tap(find.bySemanticsLabel('Download English transcription'));
      await tester.pump();

      expect(models.calls, contains('downloadModel(englishSpeech)'));
      expect(find.text(ModelsCopy.downloadingTitle.toUpperCase()),
          findsOneWidget);
      expect(find.bySemanticsLabel('Cancel English transcription'),
          findsOneWidget);
    });

    testWidgets('the mobile-data switch is off, and the screen says what that '
        'means', (tester) async {
      final models = await _settings(tester);

      expect(find.text(ModelsCopy.mobileDataSwitch), findsOneWidget);
      expect(find.text(ModelsCopy.mobileDataNote), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(models.calls, contains('setDownloadOnMobileData(true)'));
      expect(models.downloadOnMobileData, isTrue);
    });

    testWidgets('a set installed elsewhere moves list without a reopen',
        (tester) async {
      final models = await _settings(tester);
      expect(find.text(ModelsCopy.onThisPhone.toUpperCase()), findsNothing);

      models.set(ModelFeature.hindiSpeech, state: ModelInstallState.installed);
      await tester.pump();

      expect(find.text(ModelsCopy.onThisPhone.toUpperCase()), findsOneWidget);
      // Once on its row, once in the space used.
      expect(find.text('197 MB'), findsNWidgets(2));
    });

    testWidgets('the screen re-reads the disk when it opens', (tester) async {
      final models = await _settings(tester);

      expect(models.calls, contains('refreshModels()'));
    });
  });

  // -------------------------------------------------------------------------
  // The same screen over the REAL downloader, on a catalogue of one tiny set.
  // The fake above proves the screen asks for the right things; this proves the
  // asks land, and that what the downloader does comes back to the screen
  // without anybody reopening it.
  // -------------------------------------------------------------------------
  group('over the real downloader', () {
    setUpAll(registerViewFallbacks);

    ViewHarness realHarness() {
      final harness = ViewHarness(
        speechModelInstalled: false,
        settingsDirectory: '/tmp/voicenotetaker-support',
        modelDownloads: (fileStore, models) => ModelDownloadService(
          fileStore: fileStore,
          models: models,
          client: _FakeClient(),
          hashing: const CryptoHashing(),
          network: FixedNetworkStatus(NetworkKind.unmetered),
          catalogue: <ModelRelease>[_tinyHindi],
          delay: (_) async {},
          headroomBytes: 0,
          progressStepBytes: 0,
        ),
      );
      addTearDown(harness.dispose);
      return harness;
    }

    testWidgets('Download installs the set, and the screen moves it across',
        (tester) async {
      final harness = realHarness();
      await harness.controller.initialise();
      await pumpScreen(
        tester,
        ModelsSettingsView(models: AppControllerModels(harness.controller)),
      );

      expect(find.text(ModelsCopy.notDownloaded.toUpperCase()), findsOneWidget);
      expect(find.text('0 B'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Download Hindi transcription'));
      await flush(tester);

      expect(find.text(ModelsCopy.onThisPhone.toUpperCase()), findsOneWidget);
      expect(find.text(ModelsCopy.notDownloaded.toUpperCase()), findsNothing);
      expect(
        harness.controller.installedModelBytes,
        _tinyHindi.totalBytes,
      );
      // Its size, on the row and in the space used.
      expect(
        find.text(formatBytes(_tinyHindi.totalBytes)),
        findsNWidgets(2),
      );
    });

    testWidgets('Remove, confirmed, frees it again', (tester) async {
      final harness = realHarness();
      await harness.controller.initialise();
      await harness.controller.downloadModel(ModelFeature.hindiSpeech);
      await pumpScreen(
        tester,
        ModelsSettingsView(models: AppControllerModels(harness.controller)),
      );
      await flush(tester);

      expect(find.text(ModelsCopy.onThisPhone.toUpperCase()), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Remove Hindi transcription'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, ModelsCopy.remove));
      await flush(tester);

      expect(find.text(ModelsCopy.onThisPhone.toUpperCase()), findsNothing);
      expect(harness.controller.installedModelBytes, 0);
      expect(find.text('0 B'), findsOneWidget);
    });
  });
}

// ---------------------------------------------------------------------------
// A tiny stand-in for the Hindi set: the same feature and id, a directory of
// its own and a few bytes per file, so the whole download is real and the
// 197 MB is not.
// ---------------------------------------------------------------------------

final Uint8List _modelBytes =
    Uint8List.fromList(List<int>.generate(64, (i) => i));
final Uint8List _tokenBytes =
    Uint8List.fromList(List<int>.generate(9, (i) => i));

String _sha256Of(List<int> bytes) {
  final sink = const CryptoHashing().startSha256();
  sink.add(bytes);
  return sink.finish();
}

final ModelRelease _tinyHindi = ModelRelease(
  id: SpeechModels.indicConformerHindiInt8.id,
  displayName: 'Hindi speech',
  enables: 'Hindi and Hinglish notes become text.',
  directoryName: 'test-hindi-set',
  feature: ModelFeature.hindiSpeech,
  files: <DownloadableFile>[
    DownloadableFile(
      file: SpeechModelFile(name: 'model.bin', sizeBytes: 64),
      sha256: _sha256Of(_modelBytes),
      url: 'url://model',
    ),
    DownloadableFile(
      file: SpeechModelFile(name: 'tokens.bin', sizeBytes: 9),
      sha256: _sha256Of(_tokenBytes),
      url: 'url://tokens',
    ),
  ],
);

class _FakeClient implements DownloadClient {
  final Map<String, Uint8List> files = <String, Uint8List>{
    'url://model': _modelBytes,
    'url://tokens': _tokenBytes,
  };

  @override
  Future<DownloadResponse> get(String url, {int from = 0}) async {
    final payload = Uint8List.sublistView(files[url]!, from);
    return DownloadResponse(
      statusCode: from > 0 ? 206 : 200,
      contentLength: payload.length,
      body: Stream<List<int>>.value(payload),
      abort: () async {},
    );
  }

  @override
  void close() {}
}

bool _checked(WidgetTester tester, ModelFeature feature) {
  final checkbox = tester.widget<TodoCheckbox>(
    find.byWidgetPredicate(
      (widget) =>
          widget is TodoCheckbox &&
          widget.semanticLabel == 'Include ${ModelsCopy.nameOf(feature)}',
    ),
  );
  return checkbox.checked;
}

Future<void> _tick(WidgetTester tester, ModelFeature feature) async {
  await tester
      .tap(find.bySemanticsLabel('Include ${ModelsCopy.nameOf(feature)}'));
  await tester.pump();
}
