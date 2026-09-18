import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/controller/models_controller.dart';
import 'package:voicenotetaker_app/drivers/download_client.dart';
import 'package:voicenotetaker_app/drivers/hashing_crypto.dart';
import 'package:voicenotetaker_app/drivers/network_status.dart';
import 'package:voicenotetaker_app/model/model_download.dart';
import 'package:voicenotetaker_app/model/transcript.dart';
import 'package:voicenotetaker_app/model/transcription.dart';
import 'package:voicenotetaker_app/services/transcription/model_download_service.dart';
import 'package:voicenotetaker_app/services/transcription/model_download_settings_store.dart';

import 'view/harness.dart';

/// Installing a model, at the controller: what a screen is told, what the
/// choice about mobile data does, and - the point of the whole thing - that
/// notes waiting for a model start transcribing the moment it lands.
void main() {
  setUpAll(registerViewFallbacks);

  late _FakeClient client;

  /// A harness whose downloader serves a catalogue of one tiny set standing
  /// in for the Hindi model: same feature, same id, two files of a few bytes
  /// in a directory of its own. Everything above the service - the controller
  /// and the screen - is exercised for real; only the 197 MB is not.
  ViewHarness harnessWith({
    NetworkKind network = NetworkKind.unmetered,
    ScriptedRecognizer? recognizer,
    bool backgroundTranscription = false,
  }) {
    client = _FakeClient();
    final harness = ViewHarness(
      recognizer: recognizer,
      speechModelInstalled: false,
      backgroundTranscription: backgroundTranscription,
      settingsDirectory: '/tmp/voicenotetaker-support',
      modelDownloads: (fileStore, models) => ModelDownloadService(
        fileStore: fileStore,
        models: models,
        client: client,
        hashing: const CryptoHashing(),
        network: FixedNetworkStatus(network),
        catalogue: <ModelRelease>[_hindi],
        delay: (_) async {},
        headroomBytes: 0,
        progressStepBytes: 0,
      ),
    );
    addTearDown(harness.dispose);
    return harness;
  }

  group('what the screen is told', () {
    test('a model nobody has installed reads as not installed, at its full '
        'size', () async {
      final harness = harnessWith();
      await harness.controller.initialise();

      final status =
          harness.controller.modelStatusFor(ModelFeature.hindiSpeech);
      expect(status.state, ModelInstallState.notInstalled);
      expect(status.progress, 0);
      expect(status.bytesTotal, _hindi.totalBytes);
      expect(harness.controller.installedModelBytes, 0);
    });

    test('downloading it reports installed, and the bytes it takes', () async {
      final harness = harnessWith();
      await harness.controller.initialise();

      await harness.controller.downloadModel(ModelFeature.hindiSpeech);

      final status =
          harness.controller.modelStatusFor(ModelFeature.hindiSpeech);
      expect(status.failure?.detail ?? status.failure?.message, isNull);
      expect(status.state, ModelInstallState.installed);
      expect(status.progress, 1);
      expect(harness.controller.installedModelBytes, _hindi.totalBytes);
    });

    test('every change redraws the screen once', () async {
      final harness = harnessWith();
      await harness.controller.initialise();
      var notifications = 0;
      harness.controller.addListener(() => notifications++);

      await harness.controller.downloadModel(ModelFeature.hindiSpeech);
      await pumpEventQueue();

      expect(notifications, greaterThan(1));
    });

    test('a failure carries a line for the screen and no error code', () async {
      final harness = harnessWith(network: NetworkKind.metered);
      await harness.controller.initialise();

      await harness.controller.downloadModel(ModelFeature.hindiSpeech);

      final status =
          harness.controller.modelStatusFor(ModelFeature.hindiSpeech);
      expect(status.state, ModelInstallState.failed);
      expect(status.failure!.problem, ModelDownloadProblem.needsWifi);
      expect(status.failure!.message, isNot(contains('Exception')));
    });

    test('a build with no downloader still answers, honestly', () async {
      final harness = ViewHarness(speechModelInstalled: false);
      addTearDown(harness.dispose);
      await harness.controller.initialise();

      expect(harness.controller.modelStatuses, isEmpty);
      expect(
        harness.controller.modelStatusFor(ModelFeature.hindiSpeech).state,
        ModelInstallState.notInstalled,
      );
      expect(harness.controller.installedModelBytes, 0);
    });

    test('the adapter the screen is built against is plain delegation',
        () async {
      final harness = harnessWith();
      await harness.controller.initialise();
      final ModelsController models = AppControllerModels(harness.controller);

      expect(models.modelStatuses, harness.controller.modelStatuses);
      expect(
        models.modelStatusFor(ModelFeature.hindiSpeech),
        harness.controller.modelStatusFor(ModelFeature.hindiSpeech),
      );
      expect(models.downloadOnMobileData, isFalse);

      await models.downloadModel(ModelFeature.hindiSpeech);

      expect(models.modelStatusFor(ModelFeature.hindiSpeech).isInstalled,
          isTrue);
      expect(models.installedModelBytes, _hindi.totalBytes);

      await models.deleteModel(ModelFeature.hindiSpeech);

      expect(models.modelStatusFor(ModelFeature.hindiSpeech).isInstalled,
          isFalse);
      expect(models.installedModelBytes, 0);
    });
  });

  group('mobile data is the user\'s choice', () {
    test('off by default, and a download on mobile data then fails', () async {
      final harness = harnessWith(network: NetworkKind.metered);
      await harness.controller.initialise();

      expect(harness.controller.downloadOnMobileData, isFalse);
      await harness.controller.downloadModel(ModelFeature.hindiSpeech);

      expect(
        harness.controller.modelStatusFor(ModelFeature.hindiSpeech).failure!
            .problem,
        ModelDownloadProblem.needsWifi,
      );
    });

    test('turning it on lets the same download through', () async {
      final harness = harnessWith(network: NetworkKind.metered);
      await harness.controller.initialise();

      await harness.controller.setDownloadOnMobileData(true);
      await harness.controller.downloadModel(ModelFeature.hindiSpeech);

      expect(
        harness.controller.modelStatusFor(ModelFeature.hindiSpeech).isInstalled,
        isTrue,
      );
    });

    test('the choice survives a restart', () async {
      final harness = harnessWith();
      await harness.controller.initialise();
      await harness.controller.setDownloadOnMobileData(true);

      final store = ModelDownloadSettingsStore(
        fileStore: harness.fileStore,
        directory: '/tmp/voicenotetaker-support',
      );
      expect(await store.loadAllowMobileData(), isTrue);

      final again = harnessWith();
      again.fileStore.files.addAll(harness.fileStore.files);
      await again.controller.initialise();

      expect(again.controller.downloadOnMobileData, isTrue);
    });

    test('nothing is written and nothing changes when the value is the same',
        () async {
      final harness = harnessWith();
      await harness.controller.initialise();

      await harness.controller.setDownloadOnMobileData(false);

      expect(
        harness.fileStore.files
            .containsKey('/tmp/voicenotetaker-support/'
                '${ModelDownloadSettingsStore.fileName}'),
        isFalse,
      );
    });
  });

  group('work that was waiting for the model', () {
    test('a note that could not be transcribed is transcribed when the model '
        'arrives', () async {
      final recognizer = ScriptedRecognizer()
        ..texts = <int, String>{0: 'अब हुआ'};
      final harness = harnessWith(recognizer: recognizer);
      await harness.controller.initialise();
      await harness.seedRecording(length: const Duration(seconds: 8));
      await harness.controller.appForegrounded();

      // Nothing runs: there is no model to run.
      expect(recognizer.calls, 0);
      final note = harness.controller.recordings.single;
      expect(harness.controller.transcriptFor(note), isNull);

      // The download is held open half way, and the model's files appear -
      // which is what a finished download really does. Letting it finish then
      // fires the "installed" event the controller is watching.
      final gate = client.holdAfterFirstChunk();
      final running =
          harness.controller.downloadModel(ModelFeature.hindiSpeech);
      await client.firstChunkSent.future;
      harness.installSpeechModel();
      gate.complete();
      await running;
      await pumpEventQueue();
      await pumpEventQueue();

      expect(recognizer.calls, greaterThan(0),
          reason: 'the note that was waiting went ahead by itself');
      expect(
        harness.controller.transcriptStatusFor(note),
        TranscriptStatus.done,
      );
      expect(harness.controller.transcriptFor(note)!.text, 'अब हुआ');
    });

    test('a set deleted to free space can be installed again', () async {
      final harness = harnessWith();
      await harness.controller.initialise();

      await harness.controller.downloadModel(ModelFeature.hindiSpeech);
      await harness.controller.deleteModel(ModelFeature.hindiSpeech);

      expect(
        harness.controller.modelStatusFor(ModelFeature.hindiSpeech).state,
        ModelInstallState.notInstalled,
      );
      expect(harness.controller.installedModelBytes, 0);

      await harness.controller.downloadModel(ModelFeature.hindiSpeech);

      expect(
        harness.controller.modelStatusFor(ModelFeature.hindiSpeech).isInstalled,
        isTrue,
      );
    });
  });

  group('off screen', () {
    test('a download stops when the app leaves and carries on when it '
        'returns', () async {
      final harness = harnessWith();
      await harness.controller.initialise();
      await harness.controller.appForegrounded();
      final gate = client.holdAfterFirstChunk();

      final running = harness.controller.downloadModel(ModelFeature.hindiSpeech);
      await client.firstChunkSent.future;
      await harness.controller.appBackgrounded();
      gate.complete();
      await running;

      final paused =
          harness.controller.modelStatusFor(ModelFeature.hindiSpeech);
      expect(paused.paused, isTrue);
      expect(paused.isInstalled, isFalse);

      await harness.controller.appForegrounded();
      await pumpEventQueue();
      await pumpEventQueue();

      expect(
        harness.controller.modelStatusFor(ModelFeature.hindiSpeech).isInstalled,
        isTrue,
      );
    });
  });
}

// ---------------------------------------------------------------------------
// A tiny stand-in for the Hindi set: the same id, the same directory and the
// same file names the engine loads, so "installed" means one thing.
// ---------------------------------------------------------------------------

final Uint8List _model = Uint8List.fromList(List<int>.generate(64, (i) => i));
final Uint8List _tokens = Uint8List.fromList(List<int>.generate(9, (i) => i));

String _sha256Of(List<int> bytes) {
  final sink = const CryptoHashing().startSha256();
  sink.add(bytes);
  return sink.finish();
}

final ModelRelease _hindi = ModelRelease(
  id: SpeechModels.indicConformerHindiInt8.id,
  displayName: 'Hindi speech',
  enables: 'Hindi and Hinglish notes become text.',
  // A directory of its own, so the few bytes below never land on top of the
  // real model's file names in a test that also installs those.
  directoryName: 'test-hindi-set',
  feature: ModelFeature.hindiSpeech,
  files: <DownloadableFile>[
    DownloadableFile(
      file: SpeechModelFile(name: 'model.bin', sizeBytes: _model.length),
      sha256: _sha256Of(_model),
      url: 'url://model',
    ),
    DownloadableFile(
      file: SpeechModelFile(name: 'tokens.bin', sizeBytes: _tokens.length),
      sha256: _sha256Of(_tokens),
      url: 'url://tokens',
    ),
  ],
);

class _FakeClient implements DownloadClient {
  final Map<String, Uint8List> files = <String, Uint8List>{
    'url://model': _model,
    'url://tokens': _tokens,
  };

  Completer<void>? _gate;
  Completer<void> firstChunkSent = Completer<void>();

  Completer<void> holdAfterFirstChunk() {
    _gate = Completer<void>();
    firstChunkSent = Completer<void>();
    return _gate!;
  }

  @override
  Future<DownloadResponse> get(String url, {int from = 0}) async {
    final bytes = files[url]!;
    final payload = Uint8List.sublistView(bytes, from);
    return DownloadResponse(
      statusCode: from > 0 ? 206 : 200,
      contentLength: payload.length,
      body: _emit(payload),
      abort: () async {},
    );
  }

  Stream<List<int>> _emit(Uint8List payload) async* {
    const chunk = 8;
    for (var i = 0; i < payload.length; i += chunk) {
      final end = (i + chunk) > payload.length ? payload.length : i + chunk;
      yield Uint8List.sublistView(payload, i, end);
      final gate = _gate;
      if (gate != null) {
        _gate = null;
        if (!firstChunkSent.isCompleted) firstChunkSent.complete();
        await gate.future;
      }
    }
  }

  @override
  void close() {}
}
