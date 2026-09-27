import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/model_download.dart';
import 'package:voicenotetaker_app/model/transcription.dart';

/// The status object the models screen is handed, and the failure it shows.
///
/// `model_download_service_test.dart` drives these through a whole download; it
/// never asks what they promise ON THEIR OWN, and two of those promises are
/// load-bearing in ways a passing download cannot show:
///
///   a status only stops carrying a failure when someone says to clear it, so a
///   screen that has stopped failing stops saying so
///   two statuses that look the same ARE the same, because that is what stops
///   the screen rebuilding on every progress tick - and what makes it rebuild
///   when something actually changed
void main() {
  final release = ModelCatalogue.speakerDetection;

  group('the status the screen is handed', () {
    test('a fresh status knows nothing and is not busy', () {
      final status = ModelInstallStatus.unknown(release);

      expect(status.state, ModelInstallState.notInstalled);
      expect(status.bytesDone, 0);
      expect(status.bytesTotal, release.totalBytes);
      expect(status.bytesRemaining, release.totalBytes);
      expect(status.progress, 0);
      expect(status.currentFileName, isNull);
      expect(status.failure, isNull);
      expect(status.paused, isFalse);
      expect(status.retrying, isFalse);
      expect(status.isInstalled, isFalse);
      expect(status.isBusy, isFalse);
      expect(status.id, release.id);
      expect(status.feature, release.feature);
    });

    test('busy is downloading or verifying, and no other state', () {
      // The one-at-a-time rule and the button's label both read this, so a
      // state wrongly counted as busy would lock the screen out of starting
      // anything.
      const busy = <ModelInstallState>{
        ModelInstallState.downloading,
        ModelInstallState.verifying,
      };

      for (final state in ModelInstallState.values) {
        final status = ModelInstallStatus(release: release, state: state);
        expect(status.isBusy, busy.contains(state), reason: state.name);
        expect(
          status.isInstalled,
          state == ModelInstallState.installed,
          reason: state.name,
        );
      }
    });

    test('an installed model shows a full bar however few bytes were counted',
        () {
      // Bytes already on disk from a previous run are not re-counted, so an
      // install that resumed finishes with bytesDone well short of the total.
      final status = ModelInstallStatus(
        release: release,
        state: ModelInstallState.installed,
        bytesDone: 12,
      );

      expect(status.progress, 1);
    });
  });

  group('copying a status', () {
    final failing = ModelInstallStatus(
      release: release,
      state: ModelInstallState.failed,
      bytesDone: 500,
      currentFileName: 'campplus.onnx',
      failure: ModelDownloadFailure.offline,
      paused: true,
      retrying: true,
    );

    test('what is not named is carried over', () {
      final copy = failing.copyWith(bytesDone: 600);

      expect(copy.state, ModelInstallState.failed);
      expect(copy.bytesDone, 600);
      expect(copy.currentFileName, 'campplus.onnx');
      expect(copy.failure, ModelDownloadFailure.offline);
      expect(copy.paused, isTrue);
      expect(copy.retrying, isTrue);
      expect(copy.release, same(release));
    });

    test('a failure is only dropped when it is asked to be dropped', () {
      // THE TRAP, and the reason the service spells out `clearFailure: true`
      // rather than passing null: there is no way to pass null. A caller that
      // merely moves the state on leaves the old error message on screen
      // underneath a download that is running perfectly well.
      final retried = failing.copyWith(state: ModelInstallState.downloading);
      expect(retried.failure, ModelDownloadFailure.offline);

      final cleared = failing.copyWith(
        state: ModelInstallState.downloading,
        clearFailure: true,
      );
      expect(cleared.failure, isNull);
    });

    test('clearing the file name wins over naming one', () {
      // Both arguments in one call is a caller that has changed its mind; the
      // clear is the later, more explicit instruction.
      expect(failing.copyWith(clearFile: true).currentFileName, isNull);
      expect(
        failing
            .copyWith(currentFileName: 'segmentation.onnx', clearFile: true)
            .currentFileName,
        isNull,
      );
      expect(
        failing.copyWith(currentFileName: 'segmentation.onnx').currentFileName,
        'segmentation.onnx',
      );
    });

    test('paused and retrying can be turned back off', () {
      // Unlike the two above, these are plain booleans, so false is a value
      // and not "say nothing".
      final resumed = failing.copyWith(paused: false, retrying: false);

      expect(resumed.paused, isFalse);
      expect(resumed.retrying, isFalse);
    });
  });

  group('when two statuses count as the same', () {
    ModelInstallStatus downloading({int bytesDone = 100}) => ModelInstallStatus(
          release: release,
          state: ModelInstallState.downloading,
          bytesDone: bytesDone,
        );

    test('the release is compared by id, not by object', () {
      // The service rebuilds a status from the catalogue entry it is holding.
      // Comparing the objects would make every emission look new and the
      // screen would rebuild on each one.
      final twin = ModelRelease(
        id: release.id,
        displayName: 'a different description entirely',
        enables: 'and a different one of these',
        directoryName: release.directoryName,
        feature: release.feature,
        files: release.files,
      );

      expect(twin, isNot(same(release)));
      expect(
        ModelInstallStatus(release: twin, state: ModelInstallState.downloading,
            bytesDone: 100),
        downloading(),
      );
      expect(
        ModelInstallStatus(release: twin, state: ModelInstallState.downloading,
                bytesDone: 100)
            .hashCode,
        downloading().hashCode,
      );
    });

    test('a failure appearing makes a status different', () {
      // The other way round from above: if a failure were left out of the
      // comparison, the screen would never learn that the download had
      // stopped.
      expect(
        downloading().copyWith(
          state: ModelInstallState.failed,
          failure: ModelDownloadFailure.offline,
        ),
        isNot(downloading().copyWith(state: ModelInstallState.failed)),
      );
    });

    test('progress, the file in hand, pausing and retrying all count', () {
      expect(downloading(bytesDone: 101), isNot(downloading()));
      expect(
        downloading().copyWith(currentFileName: 'campplus.onnx'),
        isNot(downloading()),
      );
      expect(downloading().copyWith(paused: true), isNot(downloading()));
      expect(downloading().copyWith(retrying: true), isNot(downloading()));
    });
  });

  group('the failure a user reads', () {
    test('each problem has its own plain sentence and no error code', () {
      for (final failure in <ModelDownloadFailure>[
        ModelDownloadFailure.offline,
        ModelDownloadFailure.needsWifi,
        ModelDownloadFailure.corrupt,
        ModelDownloadFailure.network(),
        ModelDownloadFailure.storage(),
      ]) {
        expect(failure.message, isNotEmpty, reason: '${failure.problem}');
        expect(failure.message, endsWith('.'), reason: '${failure.problem}');
        expect(failure.message, isNot(contains('Exception')),
            reason: '${failure.problem}');
        expect(failure.message, isNot(contains('null')),
            reason: '${failure.problem}');
      }

      expect(ModelDownloadFailure.offline.message, contains('connection'));
      expect(ModelDownloadFailure.network().message, contains('Try again'));
      expect(ModelDownloadFailure.storage().message, contains('save'));
    });

    test('the detail is engineering, so it is part of what makes them differ',
        () {
      // The detail is not shown, but it is logged, and the screen is refreshed
      // on a status change - so two network failures with different causes have
      // to be two different failures.
      expect(ModelDownloadFailure.network('timed out'),
          isNot(ModelDownloadFailure.network('reset by peer')));
      expect(ModelDownloadFailure.network('timed out'),
          ModelDownloadFailure.network('timed out'));
      expect(ModelDownloadFailure.network('timed out').hashCode,
          ModelDownloadFailure.network('timed out').hashCode);
      expect(ModelDownloadFailure.network(), isNot(ModelDownloadFailure.offline));
    });

    test('a shortfall the user cannot act on reads as nothing to free', () {
      // More free space than needed is not a real call, but the arithmetic must
      // not put a minus sign in front of the user.
      final failure = ModelDownloadFailure.notEnoughSpace(
        neededBytes: 100,
        freeBytes: 500,
      );

      expect(failure.message, contains('0 B'));
      expect(failure.message, isNot(contains('-')));
    });
  });

  group('bytes read as a phone would write them', () {
    test('the kB and MB ceilings roll over to the next unit', () {
      // FAILS TODAY, and it is the code that is wrong, not the test. See the
      // report: formatBytes picks the unit from the UNROUNDED value and then
      // rounds, so anything from 999,500 B up reads as "1000 kB" - a unit that
      // does not exist - instead of "1.0 MB". Reachable from
      // ModelDownloadFailure.notEnoughSpace for any shortfall in that window.
      expect(formatBytes(999499), '999 kB');
      expect(formatBytes(999500), '1.0 MB');
      expect(formatBytes(999999), '1.0 MB');
      expect(formatBytes(999999999), '1.0 GB');
    });

    test('a size just under a unit does not gain a decimal it cannot have', () {
      // The part that IS right, and the reason the bug above is easy to miss:
      // the 9.95 threshold is checked after rounding, so nothing reads as
      // "10.0 kB".
      expect(formatBytes(9949), '9.9 kB');
      expect(formatBytes(9950), '10 kB');
      expect(formatBytes(1000), '1.0 kB');
      expect(formatBytes(1000000), '1.0 MB');
      expect(formatBytes(1000000000), '1.0 GB');
    });
  });

  test('a release and its files describe themselves for a log', () {
    expect(release.toString(), 'ModelRelease(${release.id})');
    expect(
      release.files.first.toString(),
      'DownloadableFile(${release.files.first.name}, '
      '${release.files.first.sizeBytes} B)',
    );
    expect(
      ModelInstallStatus(
        release: release,
        state: ModelInstallState.downloading,
        bytesDone: 7,
        paused: true,
      ).toString(),
      'ModelInstallStatus(${release.id}, downloading, 7/${release.totalBytes}'
      ', paused)',
    );
  });

  test('every url in the catalogue is the asset the uploader named', () {
    // The id is part of the asset name because a GitHub release is one flat
    // namespace: two sets both publishing `tokens.txt` would overwrite each
    // other. This is the arithmetic behind that, on its own.
    expect(
      ModelCatalogue.assetName('a-set', 'tokens.txt'),
      'a-set--tokens.txt',
    );
    expect(
      ModelCatalogue.urlFor('a-set', 'tokens.txt'),
      '${ModelCatalogue.baseUrl}/a-set--tokens.txt',
    );
    expect(
      ModelCatalogue.baseUrl,
      'https://github.com/${ModelCatalogue.repository}/releases/download/'
      '${ModelCatalogue.releaseTag}',
    );
  });

  test('a speech model file is named for a log', () {
    const file = SpeechModelFile(name: 'tokens.txt', sizeBytes: 9953);

    expect(file.toString(), 'SpeechModelFile(tokens.txt, 9953 B)');
  });
}
