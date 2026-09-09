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
import 'widgets/motion.dart';
import 'widgets/scan_control.dart';

/// Screen 1 - scan and pair.
///
/// The MAC address under each name is deliberately shown: two voiceNotetaker
/// recorders advertise the same local name, and the address is the only thing
/// that tells them apart.
class ScanView extends StatelessWidget {
  const ScanView({required this.controller, super.key});

  final AppController controller;

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
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              const Text('Devices', style: AppText.h1),
              const Spacer(),
              // The count lives in the header now: the control below is a
              // button, not a status line.
              Text(foundLabel(devices.length), style: AppText.meta13),
            ],
          ),
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
