import 'dart:async';

import 'package:flutter/material.dart';

import '../controller/app_controller.dart';
import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';
import 'widgets/edge_state.dart';

/// The link dropped on its own - `design/edge-states/ConnectionLost.dc.html`.
///
/// It stands in for HOME, not for the scan screen, and keeps Home's title: the
/// user was connected a moment ago and this is that screen telling them what
/// happened, not a fresh start.
///
/// THE REASSURANCE IS THE POINT. The recorder captures without the phone, so a
/// dropped link is not lost audio - and the one thing a user fears when the
/// connection to a recorder goes away is exactly that. The body copy says so
/// before it says anything else about reconnecting.
///
/// Distinct from the "Couldn't connect" screen on `ScanView` by construction:
/// that one is [LinkOutcome.connectFailed] and this one is
/// [LinkOutcome.connectionLost].
class ConnectionLostView extends StatelessWidget {
  const ConnectionLostView({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              const Text('Home', style: AppText.h1),
              const Spacer(),
              // See `ScanView`'s header: it ellipsises rather than overflowing.
              Flexible(
                child: Text(
                  'Disconnected',
                  style: AppText.meta13,
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Expanded(
            child: EdgeState(
              glyph: AppGlyph.signalLost,
              // Amber: walking back into range fixes it, so this is something
              // the user can act on rather than a failure.
              tint: AppColors.warning,
              headline: 'Recorder disconnected',
              body: 'The link dropped, most likely out of range. Your '
                  'recorder keeps capturing on its own and will sync when you '
                  'reconnect.',
              primaryLabel: 'Reconnect',
              onPrimary: () => unawaited(controller.retryConnection()),
            ),
          ),
        ],
      ),
    );
  }
}
