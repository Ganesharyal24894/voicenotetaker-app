import 'package:flutter/material.dart';

import '../controller/app_controller.dart';
import '../model/device_profile.dart';
import '../model/device_state.dart';
import 'format.dart';
import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';

/// Screen 1 - scan and pair.
///
/// The MAC address under each name is deliberately shown: two voiceNotetaker
/// recorders advertise the same local name, and the address is the only thing
/// that tells them apart.
class ScanView extends StatelessWidget {
  const ScanView({required this.controller, super.key});

  final AppController controller;

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

    return ScreenScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('Devices', style: AppText.h1),
          const SizedBox(height: 6),
          TapTarget(
            onTap: controller.isScanning
                ? controller.stopScan
                : controller.startScan,
            semanticLabel:
                controller.isScanning ? 'Stop scanning' : 'Scan for devices',
            child: Align(
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  ScanSpinner(spinning: controller.isScanning),
                  const SizedBox(width: 9),
                  Text(
                    controller.isScanning ? 'Scanning…' : 'Tap to scan',
                    style: AppText.body13,
                  ),
                ],
              ),
            ),
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
            child: ListView(
              padding: EdgeInsets.zero,
              children: <Widget>[
                for (var i = 0; i < known.length; i++) ...<Widget>[
                  if (i > 0) const SizedBox(height: 12),
                  _KnownDeviceCard(
                    device: known[i],
                    connecting: connecting,
                    onConnect: () => controller.connect(known[i]),
                  ),
                ],
                for (final device in unknown) ...<Widget>[
                  const SizedBox(height: 12),
                  _UnknownDeviceCard(device: device),
                ],
              ],
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
}

/// The primary card: purple hairline, filled Connect button.
class _KnownDeviceCard extends StatelessWidget {
  const _KnownDeviceCard({
    required this.device,
    required this.connecting,
    required this.onConnect,
  });

  final DiscoveredDevice device;
  final bool connecting;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(18),
      borderColor: AppColors.primaryFill,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 42,
                height: 42,
                decoration: const BoxDecoration(
                  color: AppColors.primaryFill,
                  borderRadius: AppShape.control,
                ),
                alignment: Alignment.center,
                // Light glyph on the purple fill - the contrast rule.
                child: const AppIcon(
                  AppGlyph.bluetooth,
                  size: 19,
                  color: AppColors.onPrimaryFill,
                  strokeWidth: 1.7,
                ),
              ),
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
