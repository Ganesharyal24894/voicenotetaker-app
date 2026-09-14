import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../controller/app_controller.dart';
import '../model/device_profile.dart';
import '../model/device_state.dart';
import 'format.dart';
import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';
import 'widgets/device_mark.dart';
import 'widgets/edge_state.dart';
import 'widgets/motion.dart';
import 'widgets/scan_control.dart';

/// Screen 1 - scan and pair.
///
/// The MAC address under each name is deliberately shown: two voiceNotetaker
/// recorders advertise the same local name, and the address is the only thing
/// that tells them apart.
class ScanView extends StatelessWidget {
  const ScanView({
    required this.controller,
    this.onOpenLibrary,
    this.onBack,
    super.key,
  });

  final AppController controller;

  /// Opens the recordings library. The unsupported-phone screen is the reason
  /// this exists: that screen has no primary action, and pointing at what DOES
  /// still work is the only useful thing left to offer.
  final VoidCallback? onOpenLibrary;

  /// Returns to Home, when pairing was opened from there. Null - the app's
  /// first screen - draws no back control.
  final VoidCallback? onBack;

  /// The [Hero] tag shared with the Home header's logo slot. The board flies
  /// from the device card into that slot when you connect, and the framework
  /// computes the flight - the mock's -171/-83 offsets exist only because a
  /// design canvas has no layout engine to ask.
  static const String deviceMarkHeroTag = 'device-mark';

  /// Vertical space the centred scan control is always given, whatever else
  /// is on screen: the 116px ripple area, its 20px gap and the label.
  static const double controlReserve = 176;

  /// A device is "known" when it advertises the recorder's name; everything
  /// else in range is shown dimmed and cannot be connected to.
  static bool isKnown(DiscoveredDevice device) =>
      device.name == DeviceProfile.advertisedName;

  @override
  Widget build(BuildContext context) {
    // Five of the seven edge states belong to this screen, and each one
    // REPLACES the device list and the scan control rather than sitting above
    // them: in every one of them, scanning is either impossible or has already
    // been tried.
    final edge = _edgeState(context);
    if (edge != null) {
      return ScreenScaffold(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _Header(status: edge.status, onBack: onBack),
            Expanded(child: edge.child),
          ],
        ),
      );
    }

    final devices = controller.devices;
    final known = devices.where(isKnown).toList();
    final unknown = devices.where((d) => !isKnown(d)).toList();
    final connecting = controller.phase == AppPhase.connecting;
    final ordered = <DiscoveredDevice>[...known, ...unknown];

    Widget cardFor(int i) {
      if (i < known.length) {
        return _KnownDeviceCard(
          device: known[i],
          connecting: connecting,
          // Only the first card carries the Hero: two of them under one tag
          // in the same route is an error, and the flight has one origin.
          hero: i == 0,
          onConnect: () => controller.connect(known[i]),
        );
      }
      return _UnknownDeviceCard(device: unknown[i - known.length]);
    }

    return ScreenScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // The count lives in the header now: the control below is a button,
          // not a status line.
          _Header(status: foundLabel(devices.length), onBack: onBack),
          // Only failures NO edge state covers reach this line - a library
          // that could not be listed, a write that the device refused. The
          // categorised ones have a screen of their own above, and deleting
          // this line entirely would simply hide the rest.
          if (controller.errorMessage != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              controller.errorMessage!,
              style: AppText.body13.copyWith(color: AppColors.error),
            ),
          ],
          const SizedBox(height: 28),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    // The list never grows into the control's space, so the
                    // control stays reachable however many radios are in
                    // range; past that the list scrolls.
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: math.max(
                          0,
                          constraints.maxHeight - controlReserve,
                        ),
                      ),
                      child: ListView.separated(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: ordered.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        // Rows slide in from the right, staggered when several
                        // arrive together, so the list reads as filling up.
                        itemBuilder: (context, i) => SlideInFromRight(
                          key: ValueKey<String>(ordered[i].id),
                          index: i,
                          child: cardFor(i),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            ScanControl(
                              scanning: controller.isScanning,
                              onTap: controller.isScanning
                                  ? controller.stopScan
                                  : controller.startScan,
                            ),
                            const SizedBox(height: 20),
                            Text(
                              controller.isScanning
                                  ? 'Scanning…'
                                  : 'Tap to scan',
                              style: AppText.body13,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          const SizedBox(
            width: double.infinity,
            child: Text(
              'Hold the recorder near your phone.\n'
              'It advertises for 30 seconds after power-on.',
              textAlign: TextAlign.center,
              style: AppText.footnote12,
            ),
          ),
        ],
      ),
    );
  }

  /// The header's device count, as the mock writes it: "1 found".
  static String foundLabel(int count) => '$count found';

  /// Which edge state, if any, this screen is in.
  ///
  /// ORDER IS MEANING. Unsupported comes first because it is permanent and
  /// nothing below it could be acted on anyway; permission before power,
  /// because a phone with the radio off AND the permission missing has two
  /// problems and the grant is the one that outlives the toggle; and a link
  /// failure before "nothing found", because the recorder demonstrably WAS
  /// found.
  _EdgeState? _edgeState(BuildContext context) {
    switch (controller.availability) {
      case BleAvailability.unsupported:
        return _EdgeState(
          status: 'Unsupported',
          child: EdgeState(
            glyph: AppGlyph.circleSlash,
            // Red: it genuinely cannot work. No primary action either - a
            // "Try again" on a phone with no Bluetooth LE radio would be a
            // lie, so the only action points at what still works.
            tint: AppColors.error,
            headline: "This phone can't use Bluetooth LE",
            body: 'Your recorder needs Bluetooth Low Energy, which this '
                "device doesn't support. Recordings already saved here still "
                'play.',
            secondaryLabel: onOpenLibrary == null ? null : 'Open library',
            onSecondary: onOpenLibrary,
          ),
        );
      case BleAvailability.unauthorized:
        return _permissionState(context);
      case BleAvailability.poweredOff:
        return _EdgeState(
          status: 'Bluetooth off',
          child: EdgeState(
            glyph: AppGlyph.bluetoothOff,
            // Amber: the user can fix this in one tap.
            tint: AppColors.warning,
            headline: 'Bluetooth is off',
            body: 'voiceNotetaker finds your recorder over Bluetooth. Turn it '
                'on to scan.',
            primaryLabel: 'Open Bluetooth settings',
            onPrimary: () => unawaited(controller.openBluetoothSettings()),
          ),
        );
      case BleAvailability.unknown:
      case BleAvailability.poweredOn:
        break;
    }

    // A denied runtime permission leaves the adapter powered on and the app
    // unable to use it, so it is its own fact rather than an availability.
    if (controller.permissionDenied) return _permissionState(context);

    if (controller.linkOutcome == LinkOutcome.connectFailed) {
      return _EdgeState(
        status: 'Not connected',
        child: EdgeState(
          glyph: AppGlyph.linkBroken,
          // Red: this one really did fail.
          tint: AppColors.error,
          headline: "Couldn't connect",
          body: 'voiceNotetaker found the recorder but the connection '
              "didn't complete. This usually clears on a second try.",
          primaryLabel: 'Try again',
          onPrimary: () => unawaited(controller.retryConnection()),
          secondaryLabel: 'Choose another device',
          // Drops the explanation, not the devices: the list the user was
          // choosing from is still there behind it.
          onSecondary: controller.dismissLinkFailure,
        ),
      );
    }

    if (controller.scanOutcome == ScanOutcome.nothingFound &&
        !controller.isScanning) {
      return _EdgeState(
        status: 'None found',
        child: EdgeState(
          glyph: AppGlyph.broadcast,
          // PURPLE, not amber and not red: a scan that finished having seen
          // nothing is a RESULT. Nothing has gone wrong, and this screen must
          // not read as though something had.
          tint: AppColors.purpleText,
          headline: 'No recorder nearby',
          body: 'Nothing answered in 10 seconds. Check the recorder is awake '
              'and within a few metres.',
          primaryLabel: 'Scan again',
          onPrimary: () => unawaited(controller.startScan()),
        ),
      );
    }

    return null;
  }

  _EdgeState _permissionState(BuildContext context) {
    return _EdgeState(
      status: 'No permission',
      child: EdgeState(
        glyph: AppGlyph.lock,
        // Amber: a grant away from working.
        tint: AppColors.warning,
        headline: 'Bluetooth permission needed',
        body: 'Nearby-device access is off, so scanning finds nothing. You '
            'can grant it in Settings.',
        primaryLabel: 'Open app settings',
        onPrimary: () => unawaited(controller.openAppSettings()),
        secondaryLabel: 'Why is this needed?',
        onSecondary: () => unawaited(explainScanPermission(context)),
      ),
    );
  }
}

/// An edge state and the word that replaces the device count while it shows.
class _EdgeState {
  const _EdgeState({required this.status, required this.child});

  final String status;
  final Widget child;
}

/// "Devices", and a status word on the right.
class _Header extends StatelessWidget {
  const _Header({required this.status, this.onBack});

  final String status;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        if (onBack != null)
          Transform.translate(
            offset: const Offset(-12, 0),
            child: TapTarget(
              onTap: onBack,
              semanticLabel: 'Back',
              child: const AppIcon(
                AppGlyph.chevronLeft,
                size: 20,
                color: AppColors.textSecondary,
                strokeWidth: 1.7,
              ),
            ),
          ),
        const Text('Devices', style: AppText.h1),
        const Spacer(),
        // Flexible, because the edge states put a word here rather than "0
        // found" - a narrow phone or a large text scale must ellipsise it
        // rather than overflow the header, the same way Home's status line
        // does.
        Flexible(
          child: Text(
            status,
            style: AppText.meta13,
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Answers "Why is this needed?" on the permission screen.
///
/// The design leaves this action's destination open; a dialog is what keeps it
/// on the screen the user is already stuck on. The wording matches what the
/// Android manifest actually declares - `neverForLocation` - so the
/// explanation and the permission cannot drift apart.
Future<void> explainScanPermission(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: AppShape.card),
      title: const Text('Why Bluetooth is needed', style: AppText.title22),
      content: const Text(
        'Your recorder is a Bluetooth Low Energy device, so finding it means '
        'scanning for nearby Bluetooth devices. Both Android and iOS treat '
        'that as privacy-sensitive, because a scan can reveal where you '
        'are.\n\n'
        'voiceNotetaker looks only for the recorder\u2019s own advertisement '
        'and never derives your location from it.',
        style: AppText.footnote12,
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close', style: AppText.label13),
        ),
      ],
    ),
  );
}

/// The primary card: purple hairline, the board as its mark, filled Connect.
class _KnownDeviceCard extends StatelessWidget {
  const _KnownDeviceCard({
    required this.device,
    required this.connecting,
    required this.hero,
    required this.onConnect,
  });

  final DiscoveredDevice device;
  final bool connecting;
  final bool hero;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    // The recorder shows the board itself rather than a generic Bluetooth
    // rune: it is the thing you are pairing with, and it is what flies into
    // the Home header's logo slot when you connect.
    Widget mark = const DeviceMark(
      width: DeviceMark.foundWidth,
      semanticLabel: 'voiceNotetaker recorder',
    );
    if (hero) {
      mark = Hero(tag: ScanView.deviceMarkHeroTag, child: mark);
    }

    return AppCard(
      padding: const EdgeInsets.all(18),
      borderColor: AppColors.primaryFill,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              DeviceFoundEntrance(child: mark),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      device.name ?? DeviceProfile.advertisedName,
                      style: AppText.deviceName,
                    ),
                    const SizedBox(height: 4),
                    Text(device.id, style: AppText.macAddress),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                Fmt.rssi(device.rssi),
                style: AppText.meta12.copyWith(color: AppColors.connected),
              ),
            ],
          ),
          const SizedBox(height: 16),
          PrimaryButton(
            label: connecting ? 'Connecting…' : 'Connect',
            onPressed: connecting ? null : onConnect,
          ),
        ],
      ),
    );
  }
}

/// Anything else in range: dimmed to 55% and not connectable.
class _UnknownDeviceCard extends StatelessWidget {
  const _UnknownDeviceCard({required this.device});

  final DiscoveredDevice device;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.55,
      child: AppCard(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: <Widget>[
            Container(
              width: 42,
              height: 42,
              decoration: const BoxDecoration(
                color: AppColors.raised,
                borderRadius: AppShape.control,
              ),
              alignment: Alignment.center,
              child: const AppIcon(
                AppGlyph.bluetooth,
                size: 19,
                color: AppColors.textTertiary,
                strokeWidth: 1.7,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    device.name ?? 'Unknown device',
                    style: AppText.deviceName.copyWith(
                      fontWeight: FontWeight.w400,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    device.id,
                    style: AppText.macAddress.copyWith(letterSpacing: 0),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(Fmt.rssi(device.rssi), style: AppText.meta12),
          ],
        ),
      ),
    );
  }
}
