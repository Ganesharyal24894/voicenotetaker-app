import 'dart:async';

import 'package:flutter/material.dart';

import '../../controller/assistant_controller.dart';
import '../assistant_view.dart';
import '../widgets/end_row.dart';

/// "Send to Instinct", as a row at the foot of Recorder settings: not set up,
/// off, or on.
///
/// IT LIVES IN THE FEATURE, not in `settings_view.dart`. Recorder settings
/// knows only that it has a nullable [AssistantController] and, if it has one,
/// puts this row in its list of end rows; everything the row says, and the
/// screen it opens, is here. Deleting the feature is deleting this folder and
/// the one `if` block that names it.
///
/// It follows the controller, because turning the feature on lives one screen
/// further in and the row must not still say "Not set up" when the user comes
/// back.
///
/// IT IS ALSO WHAT WAKES THE FEATURE UP. With the feature off nothing about it
/// is read at launch - see [AssistantController.initialise] - so the row asks
/// for the account and the outbox itself, the first time somebody looks at
/// Recorder settings. Without that the row would say "Not set up" to a user
/// who has an account and simply has the switch off.
class AssistantSettingsRow extends StatefulWidget {
  const AssistantSettingsRow({
    required this.assistant,
    this.onTap,
    super.key,
  });

  final AssistantController assistant;

  /// Opens "Send to Instinct". Null pushes it from here, which is what makes
  /// Recorder settings able to show the row without importing the screen.
  final VoidCallback? onTap;

  @override
  State<AssistantSettingsRow> createState() => _AssistantSettingsRowState();
}

class _AssistantSettingsRowState extends State<AssistantSettingsRow> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.assistant.prepare());
  }

  @override
  Widget build(BuildContext context) {
    final assistant = widget.assistant;
    return ListenableBuilder(
      listenable: assistant,
      builder: (context, _) => EndRow(
        title: AssistantCopy.title,
        meta: !assistant.hasAccount
            ? AssistantCopy.rowNotSetUp
            : assistant.enabled
                ? AssistantCopy.rowOn
                : AssistantCopy.rowOff,
        onTap: widget.onTap ?? () => _open(context),
      ),
    );
  }

  /// "Send to Instinct" is a page under Recorder settings, the way Diagnostics
  /// is.
  void _open(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => AssistantView(
          assistant: widget.assistant,
          onBack: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }
}
