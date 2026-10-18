/// The recorder's firmware version, as `fe0a` reports it and as a release is
/// tagged: `MAJOR.MINOR.PATCH`, optionally `-PRERELEASE`, optionally
/// `+VARIANT`.
///
/// The firmware takes the number from Zephyr's `VERSION` file
/// (`VERSION_MAJOR`, `VERSION_MINOR`, `PATCHLEVEL` and an optional
/// `EXTRAVERSION`). A hardware build appends semver build metadata naming
/// itself: `0.1.0` (default), `0.1.0+sd`, `0.1.0+nostorage`. That is kept as
/// [variant], and - as semver requires - ignored by every comparison: two
/// builds of one number are the same version, but they are NOT
/// interchangeable images, so the update flow checks [variant] itself.
///
/// THE APP IS THE ONLY THING THAT REFUSES A DOWNGRADE. The bootloader does
/// not check the application version in the init packet, so whether an update
/// applies is decided here and nowhere else - which is why the comparison is
/// strict semver precedence rather than string order (`0.10.0` > `0.9.0`).
class FirmwareVersion implements Comparable<FirmwareVersion> {
  const FirmwareVersion(this.major, this.minor, this.patch,
      [this.preRelease, this.variant]);

  final int major;
  final int minor;
  final int patch;

  /// The part after `-`, or null for a release. A pre-release sorts BELOW the
  /// release of the same number: `0.2.0-rc1` < `0.2.0`.
  final String? preRelease;

  /// The build metadata after `+` (`sd`, `nostorage`), or null for the
  /// default build. Never part of ordering or `==`.
  final String? variant;

  static final RegExp _pattern = RegExp(
    r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z-]+))?$',
  );

  /// Parses `0.1.0`, `v0.1.0` (a release tag), `0.2.0-rc1` or `0.1.0+sd`. Null for
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
      match.group(5),
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

  /// The number only, for the screen.
  @override
  String toString() =>
      '$major.$minor.$patch${preRelease == null ? '' : '-$preRelease'}';

  /// The number and its `+variant`, which round-trips through [tryParse].
  String get full => variant == null ? '$this' : '$this+$variant';
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

  /// `voiceNotetaker-<version>[-<variant>].zip`, which is also the name it is kept under
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
        'version': version.full,
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
  /// [externalPower] is the `fe05` external-power bit, which is exactly what
  /// the firmware gates `OTA!` on (VBUS). The charging bit is not: a full
  /// cell still on its cable reads "not charging".
  ///
  /// [charging] is only the fallback for a firmware that predates the
  /// external-power bit (absent reads as 0): charging implies power is in,
  /// so `externalPower || charging` is the "on its charger" test. The
  /// firmware stays the authority either way; a refusal comes back as an
  /// error on the `OTA!` write.
  static UpdateDecision evaluate({
    required FirmwareVersion? current,
    required FirmwareRelease? latest,
    required bool charging,
    required bool externalPower,
    required bool connected,
  }) {
    if (latest == null) return const UpdateNone();
    if (current == null) {
      return connected
          ? UpdateBlocked(latest, UpdateBlockReason.unknownVersion)
          : const UpdateNone();
    }
    // Another hardware build's image (a release cached before the recorder's
    // variant was known): never offered, whatever its number.
    if (latest.version.variant != current.variant) return const UpdateNone();
    // Equal or older is never offered: a downgrade is a decision for a
    // cable and a person, not for a background check.
    if (!(latest.version > current)) return const UpdateNone();
    if (!connected) return UpdateBlocked(latest, UpdateBlockReason.notConnected);
    if (!externalPower && !charging) {
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
