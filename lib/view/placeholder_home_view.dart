// ---------------------------------------------------------------------------
// PLACEHOLDER UI - THE REAL UI IS PENDING DESIGN.
//
// The visual design is still being decided by the project owner; the mockups
// in `design/` are the source of truth and none of them have been implemented
// here on purpose. This screen exists only to exercise the controller from a
// real device: it is deliberately unstyled, and every widget in it is expected
// to be thrown away. Do not treat anything below as a design decision.
// ---------------------------------------------------------------------------

import 'package:flutter/material.dart';

import '../controller/app_controller.dart';
import '../model/device_state.dart';

/// Bare harness over [AppController]. No styling effort, by instruction.
class PlaceholderHomeView extends StatefulWidget {
  const PlaceholderHomeView({required this.controller, super.key});

  final AppController controller;

  @override
  State<PlaceholderHomeView> createState() => _PlaceholderHomeViewState();
}

class _PlaceholderHomeViewState extends State<PlaceholderHomeView> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      appBar: AppBar(title: const Text('voiceNotetaker (placeholder UI)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('adapter: ${c.availability.name}'),
          Text('phase: ${c.phase.name}'),
          Text('device: ${c.connectedDevice?.name ?? '-'} '
              '(${c.connectedDevice?.id ?? 'not connected'})'),
          Text('frames: ${c.stats.framesReceived} received, '
              '${c.stats.framesLost} lost '
              '(${(c.stats.lossRatio * 100).toStringAsFixed(2)}%)'),
          Text('decoded: ${c.stats.decodedBytes} bytes'),
          if (c.lastRecording != null)
            Text('last file: ${c.lastRecording!.path} '
                '(${c.lastRecording!.audioDuration.inMilliseconds} ms)'),
          if (c.errorMessage != null)
            Text('error: ${c.errorMessage}',
                style: const TextStyle(color: Colors.red)),
          const Divider(),
          Wrap(
            spacing: 8,
            children: [
              ElevatedButton(
                onPressed: c.isScanning ? c.stopScan : c.startScan,
                child: Text(c.isScanning ? 'stop scan' : 'scan'),
              ),
              ElevatedButton(
                onPressed: c.connectedDevice == null ? null : c.disconnect,
                child: const Text('disconnect'),
              ),
              ElevatedButton(
                onPressed: c.connectedDevice == null
                    ? null
                    : (c.isRecording ? c.stopRecording : c.startRecording),
                child: Text(c.isRecording ? 'stop recording' : 'record'),
              ),
            ],
          ),
          const Divider(),
          const Text('discovered:'),
          for (final DiscoveredDevice device in c.devices)
            ListTile(
              dense: true,
              title: Text(device.name ?? '(unnamed)'),
              subtitle: Text('${device.id}  rssi ${device.rssi ?? '-'}'),
              onTap: () => c.connect(device),
            ),
        ],
      ),
    );
  }
}
