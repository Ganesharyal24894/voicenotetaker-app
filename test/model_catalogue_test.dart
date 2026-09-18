import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/diarization.dart';
import 'package:voicenotetaker_app/model/model_download.dart';
import 'package:voicenotetaker_app/model/transcription.dart';

/// The catalogue is data, and data that is wrong is a download that fails on
/// the phone. Every one of these would have caught a real mistake: a hash
/// pasted short, an id that collides, a URL that points at the wrong asset, or
/// a size that drifted away from the one the engine checks before a load.
void main() {
  group('the downloadable catalogue', () {
    test('has three sets, one per feature, and no id twice', () {
      expect(ModelCatalogue.all, hasLength(3));
      final ids = ModelCatalogue.all.map((r) => r.id).toSet();
      expect(ids, hasLength(3));
      final features = ModelCatalogue.all.map((r) => r.feature).toSet();
      expect(features, hasLength(3));
      for (final feature in ModelFeature.values) {
        expect(ModelCatalogue.forFeature(feature).feature, feature);
      }
    });

    test('every file has a plausible sha256, an https URL and a real size', () {
      for (final release in ModelCatalogue.all) {
        expect(release.files, isNotEmpty, reason: release.id);
        for (final file in release.files) {
          expect(
            file.sha256,
            matches(RegExp(r'^[0-9a-f]{64}$')),
            reason: '${release.id}/${file.name}',
          );
          expect(file.sizeBytes, greaterThan(0),
              reason: '${release.id}/${file.name}');
          expect(file.url, startsWith('https://'),
              reason: '${release.id}/${file.name}');
          expect(file.name, isNotEmpty);
        }
      }
    });

    test('no two files of a set share a name, and no two share a hash', () {
      for (final release in ModelCatalogue.all) {
        final names = release.files.map((f) => f.name).toSet();
        expect(names, hasLength(release.files.length), reason: release.id);
      }
      final hashes = <String>[
        for (final release in ModelCatalogue.all)
          for (final file in release.files) file.sha256,
      ];
      expect(hashes.toSet(), hasLength(hashes.length));
    });

    test('asset names carry the set, because two sets have a tokens.txt', () {
      final assets = <String>[
        for (final release in ModelCatalogue.all)
          for (final file in release.files)
            ModelCatalogue.assetName(release.id, file.name),
      ];
      expect(assets.toSet(), hasLength(assets.length));
      expect(
        ModelCatalogue.assetName('parakeet-tdt-110m-en-int8', 'tokens.txt'),
        'parakeet-tdt-110m-en-int8--tokens.txt',
      );
    });

    // The uploader is a shell script and cannot import this catalogue, so it
    // repeats the set ids - and it got them wrong once, naming the speaker
    // assets after the DIRECTORY (`diarization`) instead of the id
    // (`pyannote-segmentation-3-campplus`). Every URL in the app 404s when
    // that happens, and nothing in Dart notices. So read the script.
    test('tool/publish_models.sh uploads the names the catalogue asks for', () {
      final script = File('tool/publish_models.sh').readAsStringSync();
      final declared = RegExp(r'^\s*"([^":]+):([^":]+):([^"]+)"\s*$',
              multiLine: true)
          .allMatches(script)
          .map((m) => (
                directory: m.group(1)!,
                setId: m.group(2)!,
                files: m.group(3)!.split(RegExp(r'\s+')),
              ))
          .toList();

      expect(declared, hasLength(ModelCatalogue.all.length),
          reason: 'the script must declare every set, and only those');

      for (final release in ModelCatalogue.all) {
        final entry = declared.singleWhere(
          (d) => d.setId == release.id,
          orElse: () => fail('publish_models.sh has no set "${release.id}"'),
        );
        expect(entry.directory, release.directoryName,
            reason: '${release.id} is uploaded from the wrong directory');
        expect(entry.files, release.files.map((f) => f.name).toList(),
            reason: '${release.id} uploads a different set of files');
      }
    });

    // `gh release upload path#label` sets a display LABEL; the asset keeps the
    // file's basename. Using it here would upload two `tokens.txt` and let the
    // second win, so the Hindi set would carry Parakeet's tokens.
    test('the uploader names assets itself, not with gh\'s `#` label', () {
      final script = File('tool/publish_models.sh').readAsStringSync();
      final commands = script
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('#'))
          .join('\n');
      expect(commands, isNot(contains('gh release upload')),
          reason: 'gh cannot name an asset; use the REST upload endpoint');
      expect(commands, contains('uploads.github.com'));
      expect(commands, contains(r'assets?name=$asset'));
    });

    test('every URL is this release, spelt the one way', () {
      for (final release in ModelCatalogue.all) {
        for (final file in release.files) {
          expect(
            file.url,
            '${ModelCatalogue.baseUrl}/'
            '${ModelCatalogue.assetName(release.id, file.name)}',
          );
          expect(file.url, contains(ModelCatalogue.releaseTag));
        }
      }
    });

    test('totals are the sum of the files, and add up to the published '
        'figures', () {
      for (final release in ModelCatalogue.all) {
        expect(
          release.totalBytes,
          release.files.fold<int>(0, (sum, f) => sum + f.sizeBytes),
        );
      }
      // The numbers the docs and the UI quote.
      expect(ModelCatalogue.hindiSpeech.totalBytes, 197051093);
      expect(ModelCatalogue.englishSpeech.totalBytes, 136490421);
      expect(ModelCatalogue.speakerDetection.totalBytes, 34274077);
      expect(ModelCatalogue.everythingBytes, 367815591);
    });

    test('byId finds every set and nothing else', () {
      for (final release in ModelCatalogue.all) {
        expect(ModelCatalogue.byId(release.id), same(release));
      }
      expect(ModelCatalogue.byId('no-such-model'), isNull);
    });
  });

  group('the catalogue and the engine agree', () {
    test('the Hindi set is exactly the files IndicConformer loads', () {
      _sameFiles(
        ModelCatalogue.hindiSpeech,
        SpeechModels.indicConformerHindiInt8.files,
        SpeechModels.indicConformerHindiInt8.directoryName,
        SpeechModels.indicConformerHindiInt8.id,
      );
    });

    test('the English set is exactly the files Parakeet loads', () {
      _sameFiles(
        ModelCatalogue.englishSpeech,
        SpeechModels.parakeetTdtEnglishInt8.files,
        SpeechModels.parakeetTdtEnglishInt8.directoryName,
        SpeechModels.parakeetTdtEnglishInt8.id,
      );
    });

    test('the speaker set is exactly the files the diarizer loads', () {
      _sameFiles(
        ModelCatalogue.speakerDetection,
        DiarizationModels.pyannoteCamPlus.files,
        DiarizationModels.pyannoteCamPlus.directoryName,
        DiarizationModels.pyannoteCamPlus.id,
      );
    });

    test('the sizes are the SAME objects, so they cannot drift apart', () {
      expect(
        ModelCatalogue.hindiSpeech.files.first.file,
        same(SpeechModels.indicConformerHindiInt8.modelFile),
      );
      expect(
        ModelCatalogue.speakerDetection.files.last.file,
        same(DiarizationModels.pyannoteCamPlus.embeddingFile),
      );
    });
  });

  group('resuming a part-downloaded file', () {
    test('nothing on disk starts from the beginning', () {
      expect(
        ResumePlan.decide(bytesOnDisk: 0, expectedBytes: 100),
        const ResumePlan(action: ResumeAction.fromStart, startAt: 0),
      );
    });

    test('some of it on disk asks for the rest', () {
      expect(
        ResumePlan.decide(bytesOnDisk: 40, expectedBytes: 100),
        const ResumePlan(action: ResumeAction.resume, startAt: 40),
      );
    });

    test('all of it on disk fetches nothing', () {
      expect(
        ResumePlan.decide(bytesOnDisk: 100, expectedBytes: 100),
        const ResumePlan(action: ResumeAction.complete, startAt: 100),
      );
    });

    test('MORE than the file is not the file, and is thrown away', () {
      expect(
        ResumePlan.decide(bytesOnDisk: 101, expectedBytes: 100),
        const ResumePlan(action: ResumeAction.discard, startAt: 0),
      );
    });

    test('a negative count cannot happen and is treated as nothing', () {
      expect(
        ResumePlan.decide(bytesOnDisk: -5, expectedBytes: 100).action,
        ResumeAction.fromStart,
      );
    });
  });

  group('what the screen is told', () {
    final release = ModelCatalogue.speakerDetection;

    test('progress is bytes over the set, clamped', () {
      expect(
        ModelInstallStatus(
          release: release,
          state: ModelInstallState.downloading,
          bytesDone: release.totalBytes ~/ 2,
        ).progress,
        closeTo(0.5, 0.01),
      );
      expect(
        ModelInstallStatus(
          release: release,
          state: ModelInstallState.downloading,
          bytesDone: release.totalBytes * 2,
        ).progress,
        1,
      );
      expect(
        ModelInstallStatus(release: release, state: ModelInstallState.installed)
            .progress,
        1,
      );
    });

    test('bytesRemaining never goes below zero', () {
      expect(
        ModelInstallStatus(
          release: release,
          state: ModelInstallState.downloading,
          bytesDone: release.totalBytes + 10,
        ).bytesRemaining,
        0,
      );
    });

    test('a failure says what happened and what to do, with no error code', () {
      final failure = ModelDownloadFailure.notEnoughSpace(
        neededBytes: 200000000,
        freeBytes: 50000000,
      );
      expect(failure.problem, ModelDownloadProblem.notEnoughSpace);
      expect(failure.message, contains('150 MB'));
      expect(failure.message, isNot(contains('Exception')));
      expect(ModelDownloadFailure.needsWifi.message, contains('mobile data'));
      expect(ModelDownloadFailure.corrupt.message, contains('try again'));
    });

    test('bytes read as a phone would write them', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(999), '999 B');
      expect(formatBytes(9953), '10 kB');
      expect(formatBytes(1500), '1.5 kB');
      expect(formatBytes(34274077), '34 MB');
      expect(formatBytes(196977855), '197 MB');
      expect(formatBytes(2500000000), '2.5 GB');
    });
  });
}

void _sameFiles(
  ModelRelease release,
  List<SpeechModelFile> engineFiles,
  String directoryName,
  String id,
) {
  expect(release.id, id);
  expect(release.directoryName, directoryName);
  expect(
    release.files.map((f) => f.name).toList(),
    engineFiles.map((f) => f.name).toList(),
  );
  expect(
    release.files.map((f) => f.sizeBytes).toList(),
    engineFiles.map((f) => f.sizeBytes).toList(),
  );
}
