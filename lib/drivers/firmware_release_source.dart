import 'dart:async';
import 'dart:convert';

import '../model/firmware_update.dart';
import 'download_client.dart';

/// Where the app learns which firmware is the newest.
///
/// Abstract like every other driver, so the update service is tested with a
/// release handed to it and no network anywhere near it.
abstract class FirmwareReleaseSource {
  /// The newest published firmware, or null when there is none or it could
  /// not be found out - no network, a rate limit, a malformed answer. NEVER
  /// throws: a failed check is "nothing to offer", and the next check is a
  /// day away anyway.
  Future<FirmwareRelease?> latest();
}

/// [FirmwareReleaseSource] over the GitHub Releases API.
///
/// Fetched with the app's own [DownloadClient], the one that already fetches
/// the speech models from GitHub release assets, so there is still one HTTP
/// stack in the app.
///
/// THE LIST, NOT `/releases/latest`. The likely host is the app repository,
/// whose releases also carry the speech models (`models-v1`), and
/// `/releases/latest` is simply the newest non-draft release - a models tag
/// as often as not. So the newest page is listed and the highest firmware
/// version with both assets wins, whatever else was published around it.
class GitHubFirmwareReleaseSource implements FirmwareReleaseSource {
  GitHubFirmwareReleaseSource({
    required this._client,
    this.repository = defaultRepository,
    this.variant,
  });

  /// `owner/repo` the firmware releases hang off.
  ///
  /// THE FINAL HOME IS STILL BEING DECIDED. The firmware repository is
  /// private, and a private repository's release assets need a token the app
  /// cannot ship, so the public app repository - where the speech models
  /// already are - is the likely host. Change it here and nowhere else.
  static const String defaultRepository = 'Ganesharyal24894/voicenotetaker-app';

  /// Prefix of every package `release.sh` writes.
  static const String packagePrefix = 'voiceNotetaker-';

  /// Hardware builds of the firmware (`voiceNotetaker/variants/*.conf`).
  /// `release.sh sd` names its zip `voiceNotetaker-<version>-sd.zip`, which
  /// would otherwise read as pre-release `sd` of the default build.
  static const Set<String> knownVariants = <String>{'sd'};

  /// Releases read per check. A page is plenty at one firmware release in a
  /// while; anything older than this many releases is not the newest.
  static const int pageSize = 30;

  /// More than any release list or `.sha256` file; a body past this is not
  /// what was asked for, and is not read into memory.
  static const int maxBodyBytes = 2 * 1000 * 1000;

  final DownloadClient _client;
  final String repository;

  /// Which hardware build to look for; null for the default (no storage).
  /// `fe0a` does not say which one the recorder runs, so the caller must.
  final String? variant;

  @override
  Future<FirmwareRelease?> latest() async {
    try {
      final list = await _getText(
        'https://api.github.com/repos/$repository/releases?per_page=$pageSize',
      );
      if (list == null) return null;
      final candidate = pickLatest(jsonDecode(list), variant: variant);
      if (candidate == null) return null;
      final shaText = await _getText(candidate.sha256Url);
      if (shaText == null) return null;
      final sha = parseSha256File(shaText, candidate.zipName);
      if (sha == null) return null;
      return candidate.toRelease(sha);
    } on Object {
      // DownloadException, FormatException, a socket that died mid-body: all
      // of them mean "could not find out", which is null by contract.
      return null;
    }
  }

  /// The body as text when the answer was a 200, else null.
  Future<String?> _getText(String url) async {
    final response = await _client.get(url);
    if (!response.isWholeFile) {
      await response.abort();
      return null;
    }
    final bytes = <int>[];
    await for (final chunk in response.body) {
      bytes.addAll(chunk);
      if (bytes.length > maxBodyBytes) {
        await response.abort();
        return null;
      }
    }
    return utf8.decode(bytes);
  }

  /// The newest firmware in a GitHub release list, before its `.sha256` is
  /// fetched. Drafts and pre-releases are skipped: a pre-release is
  /// published to be tried by hand, not offered to every recorder.
  static ReleaseCandidate? pickLatest(Object? json, {String? variant}) {
    if (json is! List) return null;
    ReleaseCandidate? best;
    for (final release in json) {
      if (release is! Map<String, Object?>) continue;
      if (release['draft'] == true || release['prerelease'] == true) continue;
      final assets = release['assets'];
      if (assets is! List) continue;
      final byName = <String, Map<String, Object?>>{
        for (final asset in assets)
          if (asset is Map<String, Object?> && asset['name'] is String)
            asset['name']! as String: asset,
      };
      for (final entry in byName.entries) {
        final version = versionOfPackage(entry.key, variant: variant);
        if (version == null) continue;
        final zip = entry.value;
        final sha = byName['${entry.key}.sha256'];
        final zipUrl = zip['browser_download_url'];
        final size = zip['size'];
        final shaUrl = sha?['browser_download_url'];
        if (zipUrl is! String || size is! int || shaUrl is! String) continue;
        if (best != null && !(version > best.version)) continue;
        final published = release['published_at'];
        final body = release['body'];
        best = ReleaseCandidate(
          version: version,
          zipName: entry.key,
          zipUrl: zipUrl,
          sizeBytes: size,
          sha256Url: shaUrl,
          publishedAt: published is String ? DateTime.tryParse(published) : null,
          notes: body is String ? body : '',
        );
      }
    }
    return best;
  }

  /// The version in `voiceNotetaker-<version>[-<variant>].zip`, or null when
  /// [name] is not a package for [variant].
  static FirmwareVersion? versionOfPackage(String name, {String? variant}) {
    if (!name.startsWith(packagePrefix) || !name.endsWith('.zip')) return null;
    var rest = name.substring(packagePrefix.length, name.length - 4);
    if (variant != null) {
      final suffix = '-$variant';
      if (!rest.endsWith(suffix)) return null;
      rest = rest.substring(0, rest.length - suffix.length);
    }
    final version = FirmwareVersion.tryParse(rest);
    if (version == null) return null;
    // `0.2.0-sd` asked for as the default build: that is the SD build.
    final tail = version.preRelease?.split('.').last.split('-').last;
    if (variant == null && knownVariants.contains(tail)) return null;
    return version;
  }

  /// The digest in a `sha256sum` line (`<hex>  <name>`), as `release.sh`
  /// writes it. Null unless it is 64 hex digits for [zipName] - or a bare
  /// digest with no name at all.
  static String? parseSha256File(String text, String zipName) {
    for (final line in const LineSplitter().convert(text)) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.isEmpty || fields.first.isEmpty) continue;
      final hex = fields.first.toLowerCase();
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) continue;
      if (fields.length == 1) return hex;
      // `sha256sum -b` marks the name with a leading `*`.
      final named = fields[1].startsWith('*') ? fields[1].substring(1) : fields[1];
      if (named == zipName) return hex;
    }
    return null;
  }
}

/// A firmware release before its digest has been fetched.
class ReleaseCandidate {
  const ReleaseCandidate({
    required this.version,
    required this.zipName,
    required this.zipUrl,
    required this.sizeBytes,
    required this.sha256Url,
    required this.publishedAt,
    required this.notes,
  });

  final FirmwareVersion version;
  final String zipName;
  final String zipUrl;
  final int sizeBytes;
  final String sha256Url;
  final DateTime? publishedAt;
  final String notes;

  FirmwareRelease toRelease(String sha256) => FirmwareRelease(
        version: version,
        zipName: zipName,
        zipUrl: zipUrl,
        sha256: sha256,
        sizeBytes: sizeBytes,
        publishedAt: publishedAt,
        notes: notes,
      );
}
