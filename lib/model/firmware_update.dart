/// The recorder's firmware version, as `fe0a` reports it and as a release is
/// tagged: `MAJOR.MINOR.PATCH`, optionally `-PRERELEASE`.
///
/// The firmware takes it from Zephyr's `VERSION` file (`VERSION_MAJOR`,
/// `VERSION_MINOR`, `PATCHLEVEL` and an optional `EXTRAVERSION`), so this is
/// the whole grammar there is; build metadata (`+...`) never appears and is
/// rejected rather than guessed at.
///
/// THE APP IS THE ONLY THING THAT REFUSES A DOWNGRADE. The bootloader does
/// not check the application version in the init packet, so whether an update
/// applies is decided here and nowhere else - which is why the comparison is
/// strict semver precedence rather than string order (`0.10.0` > `0.9.0`).
class FirmwareVersion implements Comparable<FirmwareVersion> {
  const FirmwareVersion(this.major, this.minor, this.patch, [this.preRelease]);

  final int major;
  final int minor;
  final int patch;

  /// The part after `-`, or null for a release. A pre-release sorts BELOW the
  /// release of the same number: `0.2.0-rc1` < `0.2.0`.
  final String? preRelease;

  static final RegExp _pattern = RegExp(
    r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?$',
  );

  /// Parses `0.1.0`, `v0.1.0` (a release tag) or `0.2.0-rc1`. Null for
  /// anything else - including a value with a trailing NUL, which `fe0a` is
  /// specified never to send, so seeing one means a firmware this build does
  /// not understand.
  static FirmwareVersion? tryParse(String text) {
    final match = _pattern.firstMatch(text.trim());
    if (match == null) return null;
    final pre = match.group(4);
    if (pre != null && pre.split('.').any((part) => part.isEmpty)) return null;
    return FirmwareVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      pre,
    );
  }

  @override
  int compareTo(FirmwareVersion other) {
    for (final (a, b) in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      if (a != b) return a.compareTo(b);
    }
    return _comparePreRelease(preRelease, other.preRelease);
  }

  /// Semver section 11: no pre-release beats any pre-release; identifiers are
  /// compared left to right, numbers numerically and below any text.
  static int _comparePreRelease(String? a, String? b) {
    if (a == b) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    final left = a.split('.');
    final right = b.split('.');
    for (var i = 0; i < left.length && i < right.length; i++) {
      final l = int.tryParse(left[i]);
      final r = int.tryParse(right[i]);
      final order = switch ((l, r)) {
        (final int x, final int y) => x.compareTo(y),
        (int(), null) => -1,
        (null, int()) => 1,
        _ => left[i].compareTo(right[i]),
      };
      if (order != 0) return order;
    }
    return left.length.compareTo(right.length);
  }

  bool operator >(FirmwareVersion other) => compareTo(other) > 0;
  bool operator <(FirmwareVersion other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) =>
      other is FirmwareVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease);

  @override
  String toString() =>
      '$major.$minor.$patch${preRelease == null ? '' : '-$preRelease'}';
}

/// One published firmware package: the Nordic legacy DFU zip that the
/// firmware repository's `release.sh` writes, and what is needed to trust it.
class FirmwareRelease {
  const FirmwareRelease({
    required this.version,
    required this.zipName,
    required this.zipUrl,
    required this.sha256,
    required this.sizeBytes,
    required this.publishedAt,
    required this.notes,
  });

  final FirmwareVersion version;

  /// `voiceNotetaker-<version>.zip`, which is also the name it is kept under
  /// on the phone.
  final String zipName;
  final String zipUrl;

  /// Lowercase hex, from the `.zip.sha256` beside the zip. Checked before a
  /// single byte goes to the recorder: the bootloader erases the old image
  /// before it can find out a package is bad.
  final String sha256;
  final int sizeBytes;
  final DateTime? publishedAt;

  /// The release body, for the screen to show as-is. Empty when there is none.
  final String notes;

  Map<String, Object?> toJson() => <String, Object?>{
        'version': '$version',
        'zipName': zipName,
        'zipUrl': zipUrl,
        'sha256': sha256,
        'sizeBytes': sizeBytes,
        'publishedAt': publishedAt?.toIso8601String(),
        'notes': notes,
      };

  /// Null for anything that is not a release this build wrote.
  static FirmwareRelease? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final version = FirmwareVersion.tryParse('${json['version']}');
    final zipName = json['zipName'];
    final zipUrl = json['zipUrl'];
    final sha256 = json['sha256'];
    final size = json['sizeBytes'];
    final published = json['publishedAt'];
    if (version == null ||
        zipName is! String ||
        zipUrl is! String ||
        sha256 is! String ||
        size is! int) {
      return null;
    }
    return FirmwareRelease(
      version: version,
      zipName: zipName,
      zipUrl: zipUrl,
      sha256: sha256,
      sizeBytes: size,
      publishedAt: published is String ? DateTime.tryParse(published) : null,
      notes: json['notes'] is String ? json['notes']! as String : '',
    );
  }

  @override
  String toString() => 'FirmwareRelease($version, $zipName, $sizeBytes B)';
}

/// Why an update that exists cannot be started right now.
enum UpdateBlockReason {
  /// The firmware refuses `OTA!` without USB power: the transfer erases the
  /// old image first, so a cell that dies part-way leaves no application.
  notOnCharger,

  /// `OTA!` is written over the recorder's own encrypted link.
  notConnected,

  /// Connected, but `fe0a` did not answer or did not parse. A firmware without
  /// `fe0a` predates `OTA!` as well, so it can only be updated by cable.
  unknownVersion,
}

/// Whether to offer the latest release to the recorder in front of us.
///
/// Pure, so every combination is a unit test.
sealed class UpdateDecision {
  const UpdateDecision();

  /// [current] is the version last read from `fe0a` - kept across a
  /// disconnect, so "an update exists, connect to install it" can be said.
  /// [latest] is null when nothing has been fetched.
  ///
  /// [charging] is the `fe05` charging bit, which is NOT what the firmware
  /// checks: it gates `OTA!` on VBUS, and a full cell still on its cable reads
  /// "not charging". So a cell at 100 % that is not charging is not blocked
  /// here - it may well be plugged in, and the firmware is the authority
  /// either way; a refusal comes back as an error on the `OTA!` write.
  static UpdateDecision evaluate({
    required FirmwareVersion? current,
    required FirmwareRelease? latest,
    required bool charging,
    required bool connected,
    required int? batteryPercent,
  }) {
    if (latest == null) return const UpdateNone();
    if (current == null) {
      return connected
          ? UpdateBlocked(latest, UpdateBlockReason.unknownVersion)
          : const UpdateNone();
    }
    // Equal or older is never offered: a downgrade is a decision for a
    // cable and a person, not for a background check.
    if (!(latest.version > current)) return const UpdateNone();
    if (!connected) return UpdateBlocked(latest, UpdateBlockReason.notConnected);
    final maybeFullOnCable = batteryPercent == 100;
    if (!charging && !maybeFullOnCable) {
      return UpdateBlocked(latest, UpdateBlockReason.notOnCharger);
    }
    return UpdateOffered(latest);
  }
}

/// Nothing to offer: no release known, or the recorder is already on it.
class UpdateNone extends UpdateDecision {
  const UpdateNone();

  @override
  bool operator ==(Object other) => other is UpdateNone;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'UpdateNone';
}

/// Newer firmware exists and nothing stands in the way.
class UpdateOffered extends UpdateDecision {
  const UpdateOffered(this.release);

  final FirmwareRelease release;

  @override
  bool operator ==(Object other) =>
      other is UpdateOffered && other.release.version == release.version;

  @override
  int get hashCode => release.version.hashCode;

  @override
  String toString() => 'UpdateOffered(${release.version})';
}

/// Newer firmware may exist, but [reason] has to be fixed first.
class UpdateBlocked extends UpdateDecision {
  const UpdateBlocked(this.release, this.reason);

  final FirmwareRelease release;
  final UpdateBlockReason reason;

  @override
  bool operator ==(Object other) =>
      other is UpdateBlocked &&
      other.reason == reason &&
      other.release.version == release.version;

  @override
  int get hashCode => Object.hash(reason, release.version);

  @override
  String toString() => 'UpdateBlocked(${release.version}, ${reason.name})';
}
