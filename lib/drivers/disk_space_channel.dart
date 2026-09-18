import 'package:flutter/services.dart';

import 'disk_space.dart';

/// [DiskSpace] over a [MethodChannel] handled in `MainActivity.kt` and
/// `AppDelegate.swift`.
///
/// WHY NO PACKAGE. Dart has no free-space API at all, and the job is one call
/// per platform - `StatFs` on Android, `attributesOfFileSystem` on iOS. The
/// packages that wrap it are one-person forks of an abandoned plugin; this is
/// about fifteen lines of platform code either side, written the same way
/// `MethodChannelPlatformSettings` is and for the same reason.
///
/// The channel name is the app's bundle id plus the capability, so it cannot
/// collide with a plugin's.
class MethodChannelDiskSpace implements DiskSpace {
  const MethodChannelDiskSpace();

  static const MethodChannel channel =
      MethodChannel('com.ganeshsharma.voicenotetaker_app/storage');

  @override
  Future<int?> freeBytesFor(String path) async {
    try {
      return await channel.invokeMethod<int>('freeBytes', <String, Object?>{
        'path': path,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      // A desktop or web build of this app, or a test: nobody answered, so
      // nothing is known about the disk.
      return null;
    }
  }
}
