import 'dart:async';

import '../../drivers/disk_space.dart';
import '../../drivers/download_client.dart';
import '../../drivers/file_store.dart';
import '../../drivers/hashing.dart';
import '../../drivers/network_status.dart';
import '../../model/model_download.dart';
import 'speech_model_store.dart';

/// Fetches model sets onto this phone, so that transcription and speaker
/// detection work on a device nobody can reach with `adb`.
///
/// WHAT IT GUARANTEES
///
///   * **A half file is never a model.** Bytes land in `<name>.part`; the file
///     only takes the name the engine loads after its sha256 matches, and the
///     step that gives it that name is a rename inside one directory.
///   * **A kill is survivable.** The `.part` file IS the resume state - there
///     is no journal to get out of step with it. Next time, whatever is there
///     is either resumed with a `Range` request, or thrown away because it is
///     longer than the file it claims to be.
///   * **Nothing is downloaded twice.** One job per set, and a file already
///     installed at its exact size is skipped.
///   * **Nobody's data allowance is spent by accident.** Wi-Fi only, unless
///     the caller passes `allowMobileData`.
///   * **It fails early and in words.** Free space is checked before the first
///     byte, and every failure carries a line for the screen - see
///     [ModelDownloadFailure].
///
/// WHAT IT DOES NOT DO. It does not run off screen. See [pauseAll]: on iOS the
/// OS suspends the process and on Android nothing here is worth keeping a
/// foreground service alive for, so a download stops when the app does and
/// picks up exactly where it stopped when the app is opened. The rule is the
/// same on both platforms, which is one behaviour to explain rather than two.
class ModelDownloadService {
  ModelDownloadService({
    required FileStore fileStore,
    required SpeechModelStore models,
    required DownloadClient client,
    required Hashing hashing,
    NetworkStatus network = const FixedNetworkStatus(),
    DiskSpace diskSpace = const FixedDiskSpace(),
    List<ModelRelease>? catalogue,
    Future<void> Function(Duration)? delay,
    int maxAttempts = 3,
    int headroomBytes = defaultHeadroomBytes,
    int progressStepBytes = defaultProgressStepBytes,
    // Every one of these is a plain field behind a public name; an
    // initializing formal cannot be used because the fields are private and
    // the parameters are part of the API.
    // ignore: prefer_initializing_formals
  })  : _fileStore = fileStore,
        // ignore: prefer_initializing_formals
        _models = models,
        // ignore: prefer_initializing_formals
        _client = client,
        // ignore: prefer_initializing_formals
        _hashing = hashing,
        // ignore: prefer_initializing_formals
        _network = network,
        // ignore: prefer_initializing_formals
        _diskSpace = diskSpace,
        _catalogue = catalogue ?? ModelCatalogue.all,
        _delay = delay ?? Future<void>.delayed,
        _maxAttempts = maxAttempts < 1 ? 1 : maxAttempts,
        // ignore: prefer_initializing_formals
        _headroomBytes = headroomBytes,
        // ignore: prefer_initializing_formals
        _progressStepBytes = progressStepBytes {
    for (final release in _catalogue) {
      _statuses[release.id] = ModelInstallStatus.unknown(release);
    }
  }

  /// Room left over after the download, so installing a model does not leave
  /// the phone with nowhere to write the next recording.
  static const int defaultHeadroomBytes = 64 * 1000 * 1000;

  /// How many bytes have to arrive before another progress event is sent.
  /// A 197 MB file in 32 kB chunks is six thousand events; half a megabyte
  /// makes it four hundred, which is still a smooth bar.
  static const int defaultProgressStepBytes = 512 * 1000;

  /// How long the hash reads at a time. Big enough that a 197 MB file is fifty
  /// reads, small enough that the phone never holds more than this.
  static const int _hashChunkBytes = 4 * 1000 * 1000;

  final FileStore _fileStore;
  final SpeechModelStore _models;
  final DownloadClient _client;
  final Hashing _hashing;
  final NetworkStatus _network;
  final DiskSpace _diskSpace;
  final List<ModelRelease> _catalogue;
  final Future<void> Function(Duration) _delay;
  final int _maxAttempts;
  final int _headroomBytes;
  final int _progressStepBytes;

  final Map<String, ModelInstallStatus> _statuses =
      <String, ModelInstallStatus>{};
  final Map<String, _Job> _jobs = <String, _Job>{};

  /// Sets that stopped because the app went off screen, and whether mobile
  /// data was allowed for them, so [resumeAll] can start the same download.
  final Map<String, bool> _pausedIds = <String, bool>{};

  final StreamController<ModelInstallStatus> _changes =
      StreamController<ModelInstallStatus>.broadcast();

  bool _disposed = false;

  /// Every change to any set's status. Broadcast: the controller listens, and
  /// so may a screen.
  Stream<ModelInstallStatus> get changes => _changes.stream;

  /// What this build can install, in the order a screen should list it.
  List<ModelRelease> get catalogue => List<ModelRelease>.unmodifiable(_catalogue);

  /// Every set's status, in catalogue order.
  List<ModelInstallStatus> get statuses => <ModelInstallStatus>[
        for (final release in _catalogue) _statuses[release.id]!,
      ];

  ModelInstallStatus statusOf(ModelRelease release) =>
      _statuses[release.id] ?? ModelInstallStatus.unknown(release);

  ModelInstallStatus statusFor(ModelFeature feature) =>
      statusOf(releaseFor(feature));

  /// True while any set is downloading or being verified.
  bool get isBusy => _jobs.isNotEmpty;

  /// Bytes the installed models take on this phone.
  int get installedBytes {
    var total = 0;
    for (final status in statuses) {
      if (status.isInstalled) total += status.bytesTotal;
    }
    return total;
  }

  /// The set that switches [feature] on, from THIS service's catalogue.
  ///
  /// The caller asks here rather than reading [ModelCatalogue] itself, so a
  /// test can hand the service a catalogue of its own and everything above it
  /// - the controller included - downloads what the test is serving.
  ModelRelease releaseFor(ModelFeature feature) =>
      _catalogue.firstWhere((release) => release.feature == feature);

  // ---------------------------------------------------------------------------
  // Looking
  // ---------------------------------------------------------------------------

  /// Re-reads the disk for every set that is not being downloaded right now.
  ///
  /// Cheap - one `stat` per file - and never throws: a disk that will not
  /// answer reads as "not installed", which is what the rest of the app
  /// already does with a model it cannot see.
  Future<void> refresh() async {
    for (final release in _catalogue) {
      if (_jobs.containsKey(release.id)) continue;
      await _refreshOne(release);
    }
  }

  Future<void> _refreshOne(ModelRelease release) async {
    try {
      final missing = await _models.missingFiles(release);
      final onDisk = await _models.installedBytes(release);
      _emit(
        ModelInstallStatus(
          release: release,
          state: missing.isEmpty
              ? ModelInstallState.installed
              : ModelInstallState.notInstalled,
          bytesDone: missing.isEmpty ? release.totalBytes : onDisk,
        ),
      );
    } on Object {
      _emit(
        ModelInstallStatus(
          release: release,
          state: ModelInstallState.notInstalled,
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Downloading
  // ---------------------------------------------------------------------------

  /// Installs [release], resuming whatever is already on disk.
  ///
  /// ONE AT A TIME PER SET: asking again while the same set is downloading
  /// does nothing at all, so a second tap on the button cannot start a second
  /// transfer into the same `.part` file.
  ///
  /// Completes when the set is installed, or when it has stopped and
  /// [statusOf] says why. Never throws.
  Future<void> download(
    ModelRelease release, {
    bool allowMobileData = false,
  }) async {
    if (_disposed) return;
    if (_jobs.containsKey(release.id)) return;
    _pausedIds.remove(release.id);
    final job = _Job(release, allowMobileData: allowMobileData);
    _jobs[release.id] = job;
    try {
      await _run(job);
    } on Object catch (error) {
      job.failure ??= ModelDownloadFailure.network('$error');
      _finish(job);
    } finally {
      _jobs.remove(release.id);
      job.markStopped();
    }
  }

  /// Stops the download of [release] and keeps what has arrived, so asking
  /// again carries on from there.
  Future<void> cancel(ModelRelease release) async {
    final job = _jobs[release.id];
    _pausedIds.remove(release.id);
    if (job == null) return;
    job.cancelled = true;
    await job.stopped;
  }

  /// Removes every file of [release] from the phone, the part-downloaded ones
  /// included. Frees [ModelRelease.totalBytes].
  Future<void> remove(ModelRelease release) async {
    await cancel(release);
    for (final file in release.files) {
      await _safeDelete(_models.releasePathOf(release, file));
      await _safeDelete(_models.partPathOf(release, file));
    }
    _emit(
      ModelInstallStatus(
        release: release,
        state: ModelInstallState.notInstalled,
      ),
    );
  }

  /// The app went off screen: every running download stops where it is.
  ///
  /// THE SAME ON BOTH PLATFORMS. iOS suspends the process within seconds
  /// whatever the app would prefer, and on Android the foreground service that
  /// keeps always-listening alive is for the recorder, not for this - a model
  /// download is something the user started and is watching, and finishing it
  /// unattended on mobile data or a low battery is not a favour. What was
  /// downloaded is kept, and [resumeAll] carries on.
  void pauseAll() {
    for (final job in _jobs.values) {
      job.paused = true;
      job.cancelled = true;
      _pausedIds[job.release.id] = job.allowMobileData;
    }
  }

  /// The app is back on screen: everything [pauseAll] stopped starts again.
  Future<void> resumeAll() async {
    final resuming = Map<String, bool>.from(_pausedIds);
    _pausedIds.clear();
    for (final entry in resuming.entries) {
      ModelRelease? release;
      for (final candidate in _catalogue) {
        if (candidate.id == entry.key) release = candidate;
      }
      if (release == null) continue;
      unawaited(download(release, allowMobileData: entry.value));
    }
  }

  void dispose() {
    _disposed = true;
    for (final job in _jobs.values) {
      job.cancelled = true;
    }
    _pausedIds.clear();
    unawaited(_changes.close());
  }

  // ---------------------------------------------------------------------------
  // The job
  // ---------------------------------------------------------------------------

  Future<void> _run(_Job job) async {
    final release = job.release;

    final missing = await _models.missingFiles(release);
    job.bytesBase = await _models.installedBytes(release);
    if (missing.isEmpty) {
      _emit(
        ModelInstallStatus(
          release: release,
          state: ModelInstallState.installed,
          bytesDone: release.totalBytes,
        ),
      );
      return;
    }

    _emit(
      ModelInstallStatus(
        release: release,
        state: ModelInstallState.downloading,
        bytesDone: job.bytesBase,
        currentFileName: missing.first.name,
      ),
    );

    if (!await _roomFor(job, missing)) return _finish(job);
    if (!await _networkAllows(job)) return _finish(job);

    for (final file in missing) {
      if (job.cancelled) return _finish(job);
      job.bytesInFlight = 0;
      job.currentFileName = file.name;
      final outcome = await _fetchFile(job, file);
      if (outcome != _FileOutcome.installed) return _finish(job);
      job.bytesBase += file.sizeBytes;
      job.bytesInFlight = 0;
    }

    _emit(
      ModelInstallStatus(
        release: release,
        state: ModelInstallState.installed,
        bytesDone: release.totalBytes,
      ),
    );
  }

  /// Emits whatever a stopped job means: paused, failed, or back where it was.
  void _finish(_Job job) {
    final failure = job.failure;
    if (failure != null) {
      _emit(
        ModelInstallStatus(
          release: job.release,
          state: ModelInstallState.failed,
          bytesDone: job.bytesDone,
          failure: failure,
        ),
      );
      return;
    }
    _emit(
      ModelInstallStatus(
        release: job.release,
        state: job.paused
            ? ModelInstallState.downloading
            : ModelInstallState.notInstalled,
        bytesDone: job.bytesDone,
        currentFileName: job.paused ? job.currentFileName : null,
        paused: job.paused,
      ),
    );
  }

  /// FAILS BEFORE THE FIRST BYTE. Asking for 197 MB on a phone with 40 MB free
  /// and finding out 40 MB later is the one outcome worth a check of its own.
  Future<bool> _roomFor(_Job job, List<DownloadableFile> missing) async {
    var needed = 0;
    for (final file in missing) {
      final part =
          (await _fileStore.stat(_models.partPathOf(job.release, file)))
                  ?.sizeBytes ??
              0;
      final left = file.sizeBytes - (part > file.sizeBytes ? 0 : part);
      needed += left < 0 ? 0 : left;
    }
    final free =
        await _diskSpace.freeBytesFor(_models.releaseDirectory(job.release));
    // Null means the platform would not say. Starting anyway is right: a
    // phone that cannot report its disk must not lose the feature.
    if (free == null) return true;
    if (free >= needed + _headroomBytes) return true;
    job.failure = ModelDownloadFailure.notEnoughSpace(
      neededBytes: needed + _headroomBytes,
      freeBytes: free,
    );
    return false;
  }

  Future<bool> _networkAllows(_Job job) async {
    final NetworkKind kind;
    try {
      kind = await _network.current();
    } on Object {
      return true;
    }
    switch (kind) {
      case NetworkKind.none:
        job.failure = ModelDownloadFailure.offline;
        return false;
      case NetworkKind.metered:
        if (job.allowMobileData) return true;
        job.failure = ModelDownloadFailure.needsWifi;
        return false;
      case NetworkKind.unmetered:
      case NetworkKind.unknown:
        return true;
    }
  }

  Future<_FileOutcome> _fetchFile(_Job job, DownloadableFile file) async {
    final release = job.release;
    final partPath = _models.partPathOf(release, file);
    final finalPath = _models.releasePathOf(release, file);

    var attempt = 0;
    var discarded = false;
    while (true) {
      if (job.cancelled) return _FileOutcome.stopped;

      final onDisk = (await _fileStore.stat(partPath))?.sizeBytes ?? 0;
      final plan =
          ResumePlan.decide(bytesOnDisk: onDisk, expectedBytes: file.sizeBytes);
      if (plan.action == ResumeAction.discard) {
        // Longer than the file it claims to be: whatever it is, it is not
        // this. Once - if it is still there after that, the disk is the
        // problem, not the download.
        if (discarded) {
          job.failure = ModelDownloadFailure.storage(partPath);
          return _FileOutcome.stopped;
        }
        discarded = true;
        await _safeDelete(partPath);
        continue;
      }

      if (plan.action != ResumeAction.complete) {
        job.bytesInFlight = plan.startAt;
        _emitProgress(job, force: true);
        final error = await _transfer(job, file, partPath, plan.startAt);
        if (job.cancelled) return _FileOutcome.stopped;
        switch (error) {
          case null:
            break;
          case _TransferError.storage:
            job.failure = ModelDownloadFailure.storage(partPath);
            return _FileOutcome.stopped;
          case _TransferError.network:
            attempt++;
            if (attempt >= _maxAttempts) {
              job.failure = ModelDownloadFailure.network(
                '${file.name} after $attempt attempts',
              );
              return _FileOutcome.stopped;
            }
            // 1 s, then 2 s, then 4 s: long enough for a lift or a lost
            // handover, short enough that nobody thinks it has given up.
            await _delay(Duration(seconds: 1 << (attempt - 1)));
            continue;
        }
      }

      // Every byte is here. Check them, ONCE, before this becomes a model.
      _emit(
        statusOf(release).copyWith(
          state: ModelInstallState.verifying,
          bytesDone: job.bytesDone,
        ),
      );
      final size = (await _fileStore.stat(partPath))?.sizeBytes ?? 0;
      final digest = await _digestOf(partPath);
      if (size != file.sizeBytes || digest != file.sha256) {
        // Whatever this is, it is not the model. It does not get kept and it
        // does not get resumed: resuming corrupt bytes only wastes the rest.
        await _safeDelete(partPath);
        job.failure = ModelDownloadFailure.corrupt;
        return _FileOutcome.stopped;
      }
      try {
        await _fileStore.move(partPath, finalPath);
      } on Object catch (error) {
        job.failure = ModelDownloadFailure.storage('$error');
        return _FileOutcome.stopped;
      }
      _emit(
        statusOf(release).copyWith(
          state: ModelInstallState.downloading,
          bytesDone: job.bytesBase + file.sizeBytes,
        ),
      );
      return _FileOutcome.installed;
    }
  }

  /// One HTTP transfer into the `.part` file. Null when it ran to the end.
  Future<_TransferError?> _transfer(
    _Job job,
    DownloadableFile file,
    String partPath,
    int startAt,
  ) async {
    DownloadResponse response;
    try {
      response = await _client.get(file.url, from: startAt);
    } on DownloadException {
      return _TransferError.network;
    } on Object {
      return _TransferError.network;
    }

    var from = startAt;
    if (startAt > 0 && response.isWholeFile) {
      // The server ignored the range and is sending the lot. Take it, from
      // zero - some CDNs do this and failing would strand the download.
      await _safeDelete(partPath);
      from = 0;
      job.bytesInFlight = 0;
    } else if (startAt > 0 && !response.isPartial) {
      await response.abort();
      return _TransferError.network;
    } else if (startAt == 0 && !response.isWholeFile) {
      await response.abort();
      return _TransferError.network;
    }

    FileSink sink;
    try {
      sink = await _fileStore.openAppend(partPath);
    } on Object {
      await response.abort();
      return _TransferError.storage;
    }

    var written = from;
    Object? storageError;
    try {
      await for (final chunk in response.body) {
        if (job.cancelled) break;
        try {
          await sink.add(chunk);
        } on Object catch (error) {
          storageError = error;
          break;
        }
        written += chunk.length;
        job.bytesInFlight = written;
        _emitProgress(job);
      }
    } on Object {
      // The connection broke part way. What arrived is on disk and is
      // resumable; say so by asking for a retry.
      await _closeQuietly(sink);
      return _TransferError.network;
    }
    await _closeQuietly(sink);

    if (storageError != null) return _TransferError.storage;
    if (job.cancelled) return null;
    if (written < file.sizeBytes) return _TransferError.network;
    return null;
  }

  /// sha256 of [path], read a few megabytes at a time.
  Future<String> _digestOf(String path) async {
    final sink = _hashing.startSha256();
    var offset = 0;
    while (true) {
      final chunk =
          await _fileStore.readRange(path, offset, offset + _hashChunkBytes);
      if (chunk.isEmpty) break;
      sink.add(chunk);
      offset += chunk.length;
      if (chunk.length < _hashChunkBytes) break;
    }
    return sink.finish();
  }

  Future<void> _closeQuietly(FileSink sink) async {
    try {
      await sink.close();
    } on Object {
      // Nothing useful to do: the bytes that got there are what will be
      // resumed from.
    }
  }

  Future<void> _safeDelete(String path) async {
    try {
      await _fileStore.delete(path);
    } on Object {
      // A file that will not go is reported by the next size check, not here.
    }
  }

  void _emitProgress(_Job job, {bool force = false}) {
    final done = job.bytesDone;
    if (!force && done - job.lastEmitted < _progressStepBytes) return;
    job.lastEmitted = done;
    _emit(
      ModelInstallStatus(
        release: job.release,
        state: ModelInstallState.downloading,
        bytesDone: done,
        currentFileName: job.currentFileName,
      ),
    );
  }

  void _emit(ModelInstallStatus status) {
    final previous = _statuses[status.release.id];
    _statuses[status.release.id] = status;
    if (previous == status) return;
    if (!_changes.isClosed) _changes.add(status);
  }
}

/// One set being downloaded.
class _Job {
  _Job(this.release, {required this.allowMobileData});

  final ModelRelease release;
  final bool allowMobileData;

  /// Set by a cancel OR by the app going off screen; [paused] tells them
  /// apart, because one of them starts again by itself.
  bool cancelled = false;
  bool paused = false;

  ModelDownloadFailure? failure;

  /// Bytes of files that are fully installed.
  int bytesBase = 0;

  /// Bytes of the file being fetched that are on disk.
  int bytesInFlight = 0;

  String? currentFileName;

  int lastEmitted = -1;

  int get bytesDone => bytesBase + bytesInFlight;

  /// Completes when the run has stopped. Used by [ModelDownloadService.cancel]
  /// so that "cancelled" means the sink is closed, not merely asked for.
  final Completer<void> _stopped = Completer<void>();

  Future<void> get stopped => _stopped.future;

  void markStopped() {
    if (!_stopped.isCompleted) _stopped.complete();
  }
}

enum _FileOutcome { installed, stopped }

enum _TransferError { network, storage }
