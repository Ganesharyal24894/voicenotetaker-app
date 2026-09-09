import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/app_controller.dart';
import '../model/audio_codec.dart';
import 'format.dart';
import 'placeholder_data.dart';
import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';

/// The ONLY construction site of [DeveloperView].
///
/// [kDebugMode] is a compile-time constant, so in a release build the body of
/// the `if` below is dead code and the whole screen - along with everything it
/// pulls in - is tree-shaken out of the binary. Never construct
/// [DeveloperView] anywhere else, or that guarantee is lost.
Widget? debugOnlyDeveloperView({
  required AppController controller,
  VoidCallback? onBack,
}) {
  if (kDebugMode) {
    return DeveloperView(controller: controller, onBack: onBack);
  }
  return null;
}

/// Screen 6 - developer diagnostics. Debug builds only; reach it through
/// [debugOnlyDeveloperView].
class DeveloperView extends StatelessWidget {
  const DeveloperView({required this.controller, this.onBack, super.key});

  final AppController controller;
  final VoidCallback? onBack;

  String _diagnostics() {
    final device = controller.connectedDevice;
    final stats = controller.stats;
    final info = controller.streamInfo;
    return <String>[
      'voiceNotetaker diagnostics',
      'generated: ${DateTime.now().toIso8601String()}',
      'phase: ${controller.phase.name}',
      'adapter: ${controller.availability.name}',
      'address: ${device?.id ?? '—'}',
      'name: ${device?.name ?? '—'}',
      'rssi: ${Fmt.rssi(device?.rssi)}',
      'codec requested: ${controller.preferredCodec.name}',
      'stream: ${info == null ? '—' : info.toString()}',
      'frames received: ${stats.framesReceived}',
      'frames lost: ${stats.framesLost}',
      'malformed frames: ${stats.malformedFrames}',
      'wire bytes: ${stats.wireBytes}',
      'decoded bytes: ${stats.decodedBytes}',
      'last file: ${controller.lastRecording?.path ?? '—'}',
      'error: ${controller.errorMessage ?? 'none'}',
    ].join('\n');
  }

  Future<void> _export(BuildContext context) async {
    final text = _diagnostics();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: const RoundedRectangleBorder(borderRadius: AppShape.card),
        title: const Text('Diagnostics', style: AppText.title22),
        content: SingleChildScrollView(
          child: SelectableText(text, style: AppText.footnote12),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (context.mounted) Navigator.of(context).pop();
            },
            child: Text(
              'Copy',
              style: AppText.label13.copyWith(color: AppColors.purpleText),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close', style: AppText.label13),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final device = controller.connectedDevice;
    final stats = controller.stats;
    final lossPercent = (stats.lossRatio * 100).toStringAsFixed(2);

    return ScreenScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (onBack != null) ...<Widget>[
                TapTarget(
                  onTap: onBack,
                  semanticLabel: 'Back',
                  child: const AppIcon(
                    AppGlyph.chevronLeft,
                    size: 20,
                    color: AppColors.textSecondary,
                    strokeWidth: 1.7,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              const Expanded(
                child: Text(
                  'Developer',
                  style: AppText.title22,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.warningBadgeFill,
                  border: Border.all(color: AppColors.warningBadgeBorder),
                  borderRadius: const BorderRadius.all(Radius.circular(6)),
                ),
                child: const Text('DEBUG ONLY', style: AppText.badge),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Compiled out of release builds. Everything the technical '
            'direction put on the main screen lives here instead.',
            style: AppText.footnote12,
          ),
          const SizedBox(height: 22),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: <Widget>[
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const SectionCaption('Link', small: true),
                      const SizedBox(height: 12),
                      KeyValueRow(
                        label: 'Address',
                        value: device?.id ?? PlaceholderData.unknownValue,
                      ),
                      const SizedBox(height: 12),
                      // ATT MTU, interval and PHY are not exposed by
                      // `BleTransport`; adding them is a driver change, not a
                      // view one, so they read as unknown until it happens.
                      const KeyValueRow(
                        label: 'ATT MTU',
                        value: PlaceholderData.unknownValue,
                      ),
                      const SizedBox(height: 12),
                      const KeyValueRow(
                        label: 'Interval',
                        value: PlaceholderData.unknownValue,
                      ),
                      const SizedBox(height: 12),
                      const KeyValueRow(
                        label: 'PHY',
                        value: PlaceholderData.unknownValue,
                      ),
                      const SizedBox(height: 12),
                      KeyValueRow(
                        label: 'RSSI',
                        value: Fmt.rssi(device?.rssi),
                        valueColor: device?.rssi == null
                            ? AppColors.textPrimary
                            : AppColors.connected,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const SectionCaption('Stream', small: true),
                      const SizedBox(height: 12),
                      // Throughput needs a capture clock, which no layer
                      // publishes yet; the byte counters below are real.
                      const KeyValueRow(
                        label: 'Throughput',
                        value: PlaceholderData.unknownValue,
                      ),
                      const SizedBox(height: 12),
                      KeyValueRow(
                        label: 'Packets lost',
                        value: '${stats.framesLost} ($lossPercent%)',
                        valueColor: stats.framesLost == 0
                            ? AppColors.connected
                            : AppColors.warning,
                      ),
                      const SizedBox(height: 12),
                      KeyValueRow(
                        label: 'Frames received',
                        value: '${stats.framesReceived}',
                      ),
                      const SizedBox(height: 12),
                      KeyValueRow(
                        label: 'Decoded',
                        value: Fmt.bytes(stats.decodedBytes),
                      ),
                      const SizedBox(height: 12),
                      const KeyValueRow(
                        label: 'Jitter buffer',
                        value: PlaceholderData.unknownValue,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const SectionCaption('Codec', small: true),
                      const SizedBox(height: 12),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: _CodecSegment(
                              label: 'ADPCM',
                              selected: controller.preferredCodec ==
                                  AudioCodec.imaAdpcm,
                              onTap: () => controller.preferredCodec =
                                  AudioCodec.imaAdpcm,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _CodecSegment(
                              label: 'Raw PCM',
                              selected: controller.preferredCodec ==
                                  AudioCodec.pcmS16le,
                              onTap: () => controller.preferredCodec =
                                  AudioCodec.pcmS16le,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Raw PCM needs ATT MTU ≥ 247. iOS negotiates ~185, so '
                        'it is unavailable there.',
                        style: AppText.footnote11,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          QuietButton(
            label: 'Export diagnostics',
            onPressed: () => _export(context),
          ),
        ],
      ),
    );
  }
}

/// One half of the codec selector. Selected: purple fill with LIGHT text.
class _CodecSegment extends StatelessWidget {
  const _CodecSegment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      container: true,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: AppShape.minTapTarget,
          child: Center(
            child: Container(
              height: 38,
              decoration: BoxDecoration(
                color: selected ? AppColors.primaryFill : null,
                border: selected
                    ? null
                    : Border.all(color: AppColors.border),
                borderRadius: AppShape.segment,
              ),
              alignment: Alignment.center,
              child: Text(
                label,
                style: selected
                    ? AppText.devValue.copyWith(
                        fontWeight: FontWeight.w500,
                        color: AppColors.onPrimaryFill,
                      )
                    : AppText.devLabel.copyWith(
                        fontWeight: FontWeight.w400,
                        color: AppColors.textSecondary,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
