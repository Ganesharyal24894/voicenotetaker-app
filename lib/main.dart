import 'dart:io';

import 'package:flutter/material.dart';

import 'controller/app_controller.dart';
import 'drivers/ble_transport_universal.dart';
import 'drivers/file_store.dart';
import 'view/app_root.dart';
import 'view/theme.dart';

/// Entry point. Wires the concrete drivers into the controller and hands the
/// controller to the view layer; no logic lives here.
///
/// This is the single place that names a concrete driver implementation, which
/// is what makes `lib/drivers/` a genuine swap layer.
void main() {
  WidgetsFlutterBinding.ensureInitialized();

  const fileStore = IoFileStore();
  final controller = AppController(
    transport: UniversalBleTransport(),
    fileStore: fileStore,
    // TODO(storage): replace with a per-platform app documents directory once
    // the storage location is decided. Deliberately not pulling in
    // `path_provider` before that call is made.
    recordingsDirectory:
        fileStore.join(Directory.systemTemp.path, 'voicenotetaker'),
  );

  runApp(VoiceNotetakerApp(controller: controller));
}

class VoiceNotetakerApp extends StatefulWidget {
  const VoiceNotetakerApp({required this.controller, super.key});

  final AppController controller;

  @override
  State<VoiceNotetakerApp> createState() => _VoiceNotetakerAppState();
}

class _VoiceNotetakerAppState extends State<VoiceNotetakerApp> {
  @override
  void initState() {
    super.initState();
    widget.controller.initialise();
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'voiceNotetaker',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      home: AppRoot(controller: widget.controller),
    );
  }
}
