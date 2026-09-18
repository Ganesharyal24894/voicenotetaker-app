/// The downloadable model catalogue, and the pure state a download moves
/// through.
///
/// PURE DATA AND ARITHMETIC. No I/O, no Flutter, no package types - the
/// downloader service and the controller are written against these, and every
/// rule here is a unit test.
///
/// THIS FILE DOES NOT REPEAT A SINGLE BYTE SIZE. File names and exact sizes
/// come from [SpeechModels] and [DiarizationModels], which are what the engine
/// and `SpeechModelStore` already check against; this catalogue adds only the
/// two things a download needs and a load does not - a sha256 and a URL.
/// `model_catalogue_test.dart` asserts the two stay in step.
library;

import 'diarization.dart';
import 'transcription.dart';

/// Which feature of the app a model set switches on.
///
/// The UI asks per feature, not per file: "can this phone understand Hindi",
/// not "is encoder.int8.onnx there".
enum ModelFeature {
  /// Hindi and Hinglish speech-to-text.
  hindiSpeech,

  /// English speech-to-text, run for the windows the language router calls
  /// English.
  englishSpeech,

  /// Who said what.
  speakerDetection,
}

/// One file of a model set, as a download sees it.
///
/// [file] is the SAME [SpeechModelFile] the engine catalogue holds, so the
/// name and the size cannot drift; [sha256] and [url] are what the download
/// adds.
class DownloadableFile {
  const DownloadableFile({
    required this.file,
    required this.sha256,
    required this.url,
  });

  /// Name and exact size, from the engine's own catalogue.
  final SpeechModelFile file;

  /// Lowercase hex sha256 of a good copy, checked ONCE when the download
  /// finishes. The runtime check stays the cheap size check.
  final String sha256;

  /// Where to fetch it, unauthenticated.
  final String url;

  String get name => file.name;

  int get sizeBytes => file.sizeBytes;

  @override
  String toString() => 'DownloadableFile($name, $sizeBytes B)';
}

/// A set of files that is installed, and deleted, as one thing.
///
/// A half-installed set is useless - a transducer without its joiner decodes
/// nothing - so the unit the user sees, downloads and removes is the set.
class ModelRelease {
  const ModelRelease({
    required this.id,
    required this.displayName,
    required this.enables,
    required this.directoryName,
    required this.feature,
    required this.files,
  });

  /// The engine catalogue's id for the same model, so a status can be matched
  /// to a [SpeechModel] or [DiarizationModel] without a second name for it.
  final String id;

  /// What to call it on screen.
  final String displayName;

  /// One plain line: what the user gets by installing it.
  final String enables;

  /// Sub-directory of the app's models directory the files belong in - the
  /// same one `SpeechModelStore` looks in.
  final String directoryName;

  final ModelFeature feature;

  final List<DownloadableFile> files;

  /// Every byte that has to arrive, so the screen can say "197 MB" before
  /// anything starts.
  int get totalBytes =>
      files.fold<int>(0, (sum, file) => sum + file.sizeBytes);

  @override
  String toString() => 'ModelRelease($id)';
}

/// The model sets this build knows how to fetch.
///
/// HOSTING: our own GitHub release, one uncompressed asset per file. See
/// `doc/models.md` for why, and for how to publish a new one.
abstract final class ModelCatalogue {
  /// The public repository the release assets hang off.
  static const String repository = 'Ganesharyal24894/voicenotetaker-app';

  /// The release the URLs below point at. A new set of files means a NEW tag
  /// and a new constant here - assets are never replaced in place, so a phone
  /// mid-download can never be handed different bytes.
  static const String releaseTag = 'models-v1';

  static const String baseUrl =
      'https://github.com/$repository/releases/download/$releaseTag';

  /// Asset name for [fileName] of the set [setId].
  ///
  /// A release is one flat list of assets and two sets both carry a
  /// `tokens.txt`, so the set id is part of the name.
  static String assetName(String setId, String fileName) =>
      '$setId--$fileName';

  static String urlFor(String setId, String fileName) =>
      '$baseUrl/${assetName(setId, fileName)}';

  static DownloadableFile _entry(
    String setId,
    SpeechModelFile file,
    String sha256,
  ) =>
      DownloadableFile(
        file: file,
        sha256: sha256,
        url: urlFor(setId, file.name),
      );

  /// AI4Bharat IndicConformer, int8. The Hindi and Hinglish model.
  static final ModelRelease hindiSpeech = ModelRelease(
    id: SpeechModels.indicConformerHindiInt8.id,
    displayName: 'Hindi speech',
    enables: 'Turns Hindi and Hinglish notes into text, on the phone.',
    directoryName: SpeechModels.indicConformerHindiInt8.directoryName,
    feature: ModelFeature.hindiSpeech,
    files: <DownloadableFile>[
      _entry(
        SpeechModels.indicConformerHindiInt8.id,
        SpeechModels.indicConformerHindiInt8.modelFile,
        'b99a01834cd1a72cd9be682a0b9543df6b152ef7dfceba88d3dbf59fbb77075d',
      ),
      _entry(
        SpeechModels.indicConformerHindiInt8.id,
        SpeechModels.indicConformerHindiInt8.tokensFile,
        '743aeb755c4489bc734a6705578552b072ffb45055aeeb5db19ae7761a424882',
      ),
    ],
  );

  /// NVIDIA NeMo Parakeet TDT 110M, int8. The English model.
  static final ModelRelease englishSpeech = ModelRelease(
    id: SpeechModels.parakeetTdtEnglishInt8.id,
    displayName: 'English speech',
    enables: 'Writes English the way it is spelt, not in Devanagari.',
    directoryName: SpeechModels.parakeetTdtEnglishInt8.directoryName,
    feature: ModelFeature.englishSpeech,
    files: <DownloadableFile>[
      _entry(
        SpeechModels.parakeetTdtEnglishInt8.id,
        SpeechModels.parakeetTdtEnglishInt8.modelFile,
        '0f35509ddeb9b39002fb077d979a9fe74f06eb0bc4dd5c34f512f82e5111d657',
      ),
      _entry(
        SpeechModels.parakeetTdtEnglishInt8.id,
        SpeechModels.parakeetTdtEnglishInt8.decoderFile!,
        'f7c331c5504c2e593c76ed22b728e3f554af6c4a383dde862e719ced08b1da19',
      ),
      _entry(
        SpeechModels.parakeetTdtEnglishInt8.id,
        SpeechModels.parakeetTdtEnglishInt8.joinerFile!,
        'bf7dff69e9f2cdbe9943d70da358f38b361c115ba0105bae7e908e0d6ec782f6',
      ),
      _entry(
        SpeechModels.parakeetTdtEnglishInt8.id,
        SpeechModels.parakeetTdtEnglishInt8.tokensFile,
        '450e56bd2f036fe5b6aa821865838cc5aa9d8b0106134ce9a9ba0664abe6cd10',
      ),
    ],
  );

  /// pyannote segmentation-3.0 plus 3D-Speaker CAM++. Who said what.
  static final ModelRelease speakerDetection = ModelRelease(
    id: DiarizationModels.pyannoteCamPlus.id,
    displayName: 'Speaker detection',
    enables: 'Marks who said what in a note with more than one voice.',
    directoryName: DiarizationModels.pyannoteCamPlus.directoryName,
    feature: ModelFeature.speakerDetection,
    files: <DownloadableFile>[
      _entry(
        DiarizationModels.pyannoteCamPlus.id,
        DiarizationModels.pyannoteCamPlus.segmentationFile,
        '220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079',
      ),
      _entry(
        DiarizationModels.pyannoteCamPlus.id,
        DiarizationModels.pyannoteCamPlus.embeddingFile,
        'aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2',
      ),
    ],
  );

  /// Every set, in the order a screen should list them: the one the app is
  /// useless without first.
  static final List<ModelRelease> all = List<ModelRelease>.unmodifiable(
    <ModelRelease>[hindiSpeech, englishSpeech, speakerDetection],
  );

  static ModelRelease forFeature(ModelFeature feature) =>
      all.firstWhere((release) => release.feature == feature);

  static ModelRelease? byId(String id) {
    for (final release in all) {
      if (release.id == id) return release;
    }
    return null;
  }

  /// Everything, if a phone installed the lot.
  static int get everythingBytes =>
      all.fold<int>(0, (sum, release) => sum + release.totalBytes);
}

/// Where one model set stands.
enum ModelInstallState {
  /// Nothing of it is on this phone, or not all of it is.
  notInstalled,

  /// Bytes are arriving, or are waiting for the app to come back on screen.
  downloading,

  /// Every byte is here and the sha256 is being checked.
  verifying,

  /// Every file is present at its exact size. The feature works.
  installed,

  /// It stopped and will not start again by itself. [ModelInstallStatus.
  /// failure] says why, in words.
  failed,
}

/// Why a download stopped.
enum ModelDownloadProblem {
  /// There is not enough free storage for what is still to come.
  notEnoughSpace,

  /// The phone is on mobile data and the user has not said that is allowed.
  needsWifi,

  /// No network at all.
  offline,

  /// The connection broke, or the server would not serve the file, and
  /// retrying did not help.
  network,

  /// Everything arrived and the sha256 did not match. The file is gone.
  corrupt,

  /// The phone would not let the app write the file.
  storage,
}

/// Why a download stopped, and what to tell the user about it.
///
/// PLAIN WORDS AND A WAY OUT: every message says what happened and what the
/// person can do, with no error codes in it. [detail] is for the log.
class ModelDownloadFailure {
  const ModelDownloadFailure({
    required this.problem,
    required this.message,
    this.detail,
  });

  /// Not enough room: says how much more is needed, rounded up to whole
  /// megabytes so the number is actionable.
  factory ModelDownloadFailure.notEnoughSpace({
    required int neededBytes,
    required int freeBytes,
  }) {
    final short = neededBytes - freeBytes;
    return ModelDownloadFailure(
      problem: ModelDownloadProblem.notEnoughSpace,
      message: 'There is not enough room. Free about '
          '${formatBytes(short < 0 ? 0 : short)} and try again.',
      detail: 'needs $neededBytes B, $freeBytes B free',
    );
  }

  static const ModelDownloadFailure needsWifi = ModelDownloadFailure(
    problem: ModelDownloadProblem.needsWifi,
    message: 'Waiting for Wi-Fi. You can download on mobile data instead.',
  );

  static const ModelDownloadFailure offline = ModelDownloadFailure(
    problem: ModelDownloadProblem.offline,
    message: 'No connection. Connect and try again.',
  );

  static const ModelDownloadFailure corrupt = ModelDownloadFailure(
    problem: ModelDownloadProblem.corrupt,
    message: 'The download did not arrive intact. It has been removed - '
        'try again.',
  );

  static ModelDownloadFailure network([String? detail]) => ModelDownloadFailure(
        problem: ModelDownloadProblem.network,
        message: 'The download stopped. Try again when you have a moment.',
        detail: detail,
      );

  static ModelDownloadFailure storage([String? detail]) => ModelDownloadFailure(
        problem: ModelDownloadProblem.storage,
        message: 'The phone would not let the app save the file.',
        detail: detail,
      );

  final ModelDownloadProblem problem;

  /// One line, for the screen.
  final String message;

  /// For the log, never for the screen.
  final String? detail;

  @override
  bool operator ==(Object other) =>
      other is ModelDownloadFailure &&
      other.problem == problem &&
      other.message == message &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(problem, message, detail);

  @override
  String toString() => 'ModelDownloadFailure($problem, $message)';
}

/// Everything the screen needs about one model set, in one value.
class ModelInstallStatus {
  const ModelInstallStatus({
    required this.release,
    required this.state,
    this.bytesDone = 0,
    this.currentFileName,
    this.failure,
    this.paused = false,
    this.retrying = false,
  });

  /// Nothing has happened yet: the presence check has not run.
  factory ModelInstallStatus.unknown(ModelRelease release) =>
      ModelInstallStatus(
        release: release,
        state: ModelInstallState.notInstalled,
      );

  final ModelRelease release;

  final ModelInstallState state;

  /// Bytes already on this phone for this set - files already installed plus
  /// what has arrived of the one in flight.
  final int bytesDone;

  /// Total for the set. Never zero for a real release.
  int get bytesTotal => release.totalBytes;

  /// Which file is arriving, for a screen that wants to say so. Null when
  /// nothing is running.
  final String? currentFileName;

  /// Set exactly when [state] is [ModelInstallState.failed].
  final ModelDownloadFailure? failure;

  /// Downloading, but stopped for now because the app went off screen. It
  /// starts again by itself when the app is opened.
  final bool paused;

  /// Downloading, and waiting out a backoff before asking the server again.
  /// The screen says so - a bar that has not moved for half a minute with no
  /// word about why reads as broken, and the honest word is that it is still
  /// trying. See [DownloadRetryPolicy].
  final bool retrying;

  ModelFeature get feature => release.feature;

  String get id => release.id;

  bool get isInstalled => state == ModelInstallState.installed;

  bool get isBusy =>
      state == ModelInstallState.downloading ||
      state == ModelInstallState.verifying;

  /// 0..1. One when installed, whatever the byte counters say.
  double get progress {
    if (state == ModelInstallState.installed) return 1;
    if (bytesTotal <= 0) return 0;
    final value = bytesDone / bytesTotal;
    if (value.isNaN) return 0;
    return value < 0 ? 0 : (value > 1 ? 1 : value);
  }

  /// What is still to come, in bytes. Never negative.
  int get bytesRemaining {
    final left = bytesTotal - bytesDone;
    return left < 0 ? 0 : left;
  }

  ModelInstallStatus copyWith({
    ModelInstallState? state,
    int? bytesDone,
    String? currentFileName,
    ModelDownloadFailure? failure,
    bool? paused,
    bool? retrying,
    bool clearFile = false,
    bool clearFailure = false,
  }) =>
      ModelInstallStatus(
        release: release,
        state: state ?? this.state,
        bytesDone: bytesDone ?? this.bytesDone,
        currentFileName:
            clearFile ? null : (currentFileName ?? this.currentFileName),
        failure: clearFailure ? null : (failure ?? this.failure),
        paused: paused ?? this.paused,
        retrying: retrying ?? this.retrying,
      );

  @override
  bool operator ==(Object other) =>
      other is ModelInstallStatus &&
      other.release.id == release.id &&
      other.state == state &&
      other.bytesDone == bytesDone &&
      other.currentFileName == currentFileName &&
      other.failure == failure &&
      other.paused == paused &&
      other.retrying == retrying;

  @override
  int get hashCode => Object.hash(
        release.id,
        state,
        bytesDone,
        currentFileName,
        failure,
        paused,
        retrying,
      );

  @override
  String toString() =>
      'ModelInstallStatus(${release.id}, ${state.name}, $bytesDone/$bytesTotal'
      '${paused ? ', paused' : ''}${retrying ? ', retrying' : ''})';
}

/// What to do with the bytes already on disk for one file.
enum ResumeAction {
  /// Nothing is there: ask for the whole file.
  fromStart,

  /// Some of it is there and it is shorter than the file: ask for the rest.
  resume,

  /// All the bytes are there. Nothing to fetch - verify what is on disk.
  complete,

  /// More bytes are there than the file has. Whatever that is, it is not this
  /// file: throw it away and start again.
  discard,
}

/// What a partly-downloaded file means, decided on two numbers and nothing
/// else.
///
/// Pure so that "the app was killed half way" is a unit test rather than an
/// experiment with a phone.
class ResumePlan {
  const ResumePlan({required this.action, required this.startAt});

  factory ResumePlan.decide({
    required int bytesOnDisk,
    required int expectedBytes,
  }) {
    if (bytesOnDisk <= 0) {
      return const ResumePlan(action: ResumeAction.fromStart, startAt: 0);
    }
    if (bytesOnDisk > expectedBytes) {
      return const ResumePlan(action: ResumeAction.discard, startAt: 0);
    }
    if (bytesOnDisk == expectedBytes) {
      return ResumePlan(action: ResumeAction.complete, startAt: bytesOnDisk);
    }
    return ResumePlan(action: ResumeAction.resume, startAt: bytesOnDisk);
  }

  final ResumeAction action;

  /// The first byte to ask the server for.
  final int startAt;

  @override
  bool operator ==(Object other) =>
      other is ResumePlan && other.action == action && other.startAt == startAt;

  @override
  int get hashCode => Object.hash(action, startAt);

  @override
  String toString() => 'ResumePlan(${action.name}, from $startAt)';
}

/// When asking the server again is worth anything, and how long to wait
/// before doing it.
///
/// WHY THESE NUMBERS. A release asset nobody has fetched yet is cold on the
/// CDN. On a real phone the first request for the speaker-detection
/// segmentation file answered `504 Gateway Time-out` over and over and only
/// started serving bytes after about SIXTY SECONDS of warming up. Three tries
/// over seven seconds - what this used to do - turns that minute into "The
/// download stopped", which is both wrong and something the user can do
/// nothing about. So: nine tries, 1 s doubling to a 20 s ceiling, which is
/// 1+2+4+8+16+20+20+20 = 91 s of waiting, about 109 s with the jitter at its
/// worst. Comfortably past the warm-up that was measured, and still under the
/// two minutes past which a person would rather be told than left watching.
///
/// THE CEILING MATTERS AS MUCH AS THE COUNT: doubling all the way to the
/// ninth try would be a four-minute wait between two requests, which looks
/// exactly like a hang.
///
/// THE JITTER IS NOT DECORATION. Every phone that opened the app after a
/// release retries on the same schedule otherwise, and a cold CDN is the one
/// moment that happens at once.
///
/// PURE: attempt in, delay out; status in, verdict out. It does not sleep, it
/// does not read a clock and it holds no random source of its own - the roll
/// is handed in - so the sequence, the ceiling and the jitter bounds are unit
/// tests rather than a stopwatch.
class DownloadRetryPolicy {
  const DownloadRetryPolicy({
    this.maxAttempts = 9,
    this.firstDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 20),
    this.jitterFraction = 0.2,
    this.maxServerDelay = const Duration(seconds: 30),
  });

  /// What the app ships with, and what the numbers above describe.
  static const DownloadRetryPolicy standard = DownloadRetryPolicy();

  /// Transfers of one file, the first one included. Nine.
  final int maxAttempts;

  /// The wait after the first failure.
  final Duration firstDelay;

  /// The longest wait between two tries, however many have failed.
  final Duration maxDelay;

  /// How far either side of the nominal wait the jitter can land: 0.2 means
  /// 80 % to 120 % of it.
  final double jitterFraction;

  /// The longest a server's own `Retry-After` is honoured for. A CDN that
  /// asks for an hour is not worth waiting for with a progress bar on screen;
  /// the download stops instead and the user can start it again.
  final Duration maxServerDelay;

  /// HTTP statuses worth asking again about: the request timed out, came too
  /// early, was rate-limited, or the origin is having a moment. Everything
  /// else - 401, 403, 404, 410 - means this URL will answer the same way in
  /// twenty seconds, so the download fails at once and says so.
  static const Set<int> transientStatuses = <int>{
    408, // Request Time-out
    425, // Too Early
    429, // Too Many Requests
    500, // Internal Server Error
    502, // Bad Gateway
    503, // Service Unavailable
    504, // Gateway Time-out - the one that was actually seen.
  };

  /// Whether there is another go after [attempt] transfers have failed.
  bool canRetry(int attempt) => attempt < maxAttempts;

  bool shouldRetryStatus(int statusCode) =>
      transientStatuses.contains(statusCode);

  /// Whether [statusOrError] is worth another go.
  ///
  /// An `int` is an HTTP status and is judged on its own. ANYTHING ELSE is a
  /// connection that never became a status - a dropped socket, a timeout, a
  /// handshake that failed - which is the wire rather than the file, and the
  /// wire is exactly what retrying is for.
  bool shouldRetry(Object statusOrError) =>
      statusOrError is int ? shouldRetryStatus(statusOrError) : true;

  /// How long to wait before transfer number `attempt + 1`.
  ///
  /// [attempt] is how many have failed, counting from one. [roll] is a random
  /// number in 0..1 for the jitter, handed in so the caller owns the
  /// randomness: 0.5 is the nominal wait, 0 the shortest, 1 the longest.
  /// [retryAfter] is what the server asked for, and a server that names a
  /// number beats any guess - clamped to [maxServerDelay] and never jittered,
  /// because it is an instruction and not an estimate.
  Duration delayFor(int attempt, {double roll = 0.5, Duration? retryAfter}) {
    if (attempt < 1) return Duration.zero;
    if (retryAfter != null) {
      if (retryAfter <= Duration.zero) return Duration.zero;
      return retryAfter > maxServerDelay ? maxServerDelay : retryAfter;
    }
    final ceiling = maxDelay.inMicroseconds;
    var micros = firstDelay.inMicroseconds;
    for (var i = 1; i < attempt && micros < ceiling; i++) {
      micros *= 2;
    }
    if (micros > ceiling) micros = ceiling;
    final clamped = roll < 0 ? 0.0 : (roll > 1 ? 1.0 : roll);
    final factor = 1 + jitterFraction * (2 * clamped - 1);
    return Duration(microseconds: (micros * factor).round());
  }

  /// Every wait of a run that uses all its tries, with the jitter at its
  /// worst. The bound the comment above claims, as a number anything can
  /// check.
  Duration get longestTotalWait {
    var micros = 0;
    for (var attempt = 1; attempt < maxAttempts; attempt++) {
      micros += delayFor(attempt, roll: 1).inMicroseconds;
    }
    return Duration(microseconds: micros);
  }

  @override
  String toString() =>
      'DownloadRetryPolicy($maxAttempts tries, ${firstDelay.inSeconds}s to '
      '${maxDelay.inSeconds}s)';
}

/// `197 MB`, `34 MB`, `9.7 kB` - for a screen and for a failure message.
///
/// Decimal megabytes, because that is what a phone's storage screen and every
/// download UI the user has ever seen use.
String formatBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  // One decimal below ten, whole numbers above - and the threshold is checked
  // AFTER rounding, so 9,953 B reads as `10 kB` rather than `10.0 kB`.
  final kb = bytes / 1000;
  if (kb < 1000) return '${_short(kb)} kB';
  final mb = bytes / (1000 * 1000);
  if (mb < 1000) return '${_short(mb)} MB';
  return '${_short(bytes / (1000 * 1000 * 1000))} GB';
}

String _short(double value) =>
    value < 9.95 ? value.toStringAsFixed(1) : '${value.round()}';

