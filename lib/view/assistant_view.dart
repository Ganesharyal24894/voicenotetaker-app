/// "Send to Instinct" - every screen of the one thing this app sends.
///
/// `canvas-instinct/InstinctSetup.dc.html` and `InstinctSettings.dc.html` are
/// the two states of [AssistantView]; `InstinctUndo.dc.html` is
/// [AssistantUndoBanner]; `InstinctNote.dc.html` is [AssistantNoteMark].
///
/// EVERYTHING COMES FROM [AssistantController]. No store, no service and no
/// `AppController` field is touched here - see `doc/assistant-instructions.md`,
/// "What the screens have to do".
///
/// THE PASSWORD IS WRITE-ONLY. It goes in through a field that is obscured,
/// never read back, never put in a label, a semantics node, a snackbar or a
/// log, and the field is emptied the moment it has been handed to the
/// controller.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../controller/assistant_controller.dart';
import '../model/assistant/assistant_send.dart';
import 'assistant/assistant_failure_copy.dart';
import 'format.dart';
import 'note_list.dart';
import 'theme.dart';
import 'widgets/app_icons.dart';
import 'widgets/common.dart';
import 'widgets/home_icons.dart';
import 'widgets/home_widgets.dart';


/// The words, in one place, so a test asserts what a user reads rather than
/// what a widget happens to build.
abstract final class AssistantCopy {
  static const String title = 'Send to Instinct';

  /// The Recorder settings row's second line, per state.
  static const String rowNotSetUp = 'Not set up';
  static const String rowOn = 'On';
  static const String rowOff = 'Off';

  static const String blurbOne =
      'Start a note with “Instinct,” and the app emails that one '
      'instruction to your assistant.';
  static const String blurbTwo =
      'Instinct replies to you by email. Nothing else leaves your phone.';

  static const String assistantCaption = 'Assistant';
  static const String assistantHint = "Instinct's email address";
  static const String senderCaption = 'Send from';
  static const String senderHint = 'Your email address';
  static const String passwordHint = 'App password';

  static const String appPasswordLink = "What's an app password?";
  static const String appPasswordTitle = appPasswordLink;
  static const String appPasswordBody =
      'Gmail will not take your normal password here. In your Google account, '
      'under Security, turn on 2-Step Verification and then make an App '
      'password. It is sixteen letters. Paste it in once and you are done.\n\n'
      'The app keeps it in this phone’s keystore and never shows it '
      'again.';

  static const String spareAddress =
      'A spare address is safer here than your main one.';
  static const String approveOnce =
      'Approve it once in your WhatsApp chat with Instinct, then any address '
      'works.';

  static const String finishSetup = 'Finish setting this up.';
  static const String notAnAddress = "That doesn't look like an email address.";

  static const String test = 'Send a test email';
  static const String testSending = 'Sending…';
  static const String testSent =
      'Sent. Look in your chat with Instinct for the reply.';

  static const String save = 'Save';

  static const String sendingRow = 'Sending';
  static const String wakeCaption = 'Wake phrase';
  static const String wakeMeta = 'Say this first and the rest is sent';
  static const String edit = 'Edit';
  static const String wakeTooShort =
      'That phrase is too short. Try a longer one.';

  static const String emailCaption = 'Email';
  static const String to = 'To';
  static const String from = 'From';

  static const String buzzes = 'This phone buzzes when it hears you.';
  static const String cannotBuzz =
      'An iPhone cannot buzz from the background, so the Undo banner is the '
      'only nudge you get.';

  static const String recentCaption = 'Recent sends';
  static const String nothingSentYet = 'Nothing sent yet.';
  static const String waiting = 'One waiting to send…';
  static const String sent = 'Sent';
  static const String failed = 'Failed';

  static const String forget = 'Turn off and forget these details';
  static const String forgetTitle = 'Forget these details?';
  static const String forgetBody =
      'Sending stops and the app password is removed from this phone. Your '
      'notes are not touched.';
  static const String forgetConfirm = 'Forget';
  static const String cancel = 'Cancel';

  // The banner and the note screen.
  static const String sendingTo = 'Sending to Instinct';
  static const String undo = 'Undo';
  static const String stopped = 'Not sent';
  static const String tooLate = 'Already sent to Instinct';
  static const String sentMark = 'Sent to Instinct';
  static const String failedMark = "Couldn't send · Try again";
  static const String sendAgain = 'Send again';

  /// The first line of an instruction, for a banner or a row that has one
  /// line to give it.
  static String firstLine(String instruction) {
    final line = instruction.split('\n').first.trim();
    return line.isEmpty ? instruction.trim() : line;
  }

  /// `Today, 09:14`.
  static String when(DateTime at, {required DateTime now}) =>
      '${NoteLabels.group(at, now: now)}, ${Fmt.timeOfDay(at)}';

  /// Whether [text] is worth calling an email address. The controller only
  /// asks for an `@`; the screen is stricter so Save is not offered for
  /// something that cannot work.
  static bool isAddress(String text) {
    final trimmed = text.trim();
    if (trimmed.contains(' ') || trimmed.contains('\t')) return false;
    final at = trimmed.indexOf('@');
    if (at <= 0 || at != trimmed.lastIndexOf('@')) return false;
    final domain = trimmed.substring(at + 1);
    return domain.length > 2 && domain.contains('.') && !domain.endsWith('.');
  }
}

/// The one screen: setup until there is an account, the settled state after.
class AssistantView extends StatefulWidget {
  const AssistantView({required this.assistant, this.onBack, this.now, super.key});

  final AssistantController assistant;
  final VoidCallback? onBack;

  /// "Today, 09:14" on the recent sends is relative to this; the wall clock
  /// when null.
  final DateTime? now;

  @override
  State<AssistantView> createState() => _AssistantViewState();
}

class _AssistantViewState extends State<AssistantView> {
  final TextEditingController _assistantAddress = TextEditingController();
  final TextEditingController _sender = TextEditingController();

  /// OBSCURED, AND EMPTIED THE MOMENT IT IS SAVED. Nothing reads it but
  /// [AssistantController.saveAccount].
  final TextEditingController _password = TextEditingController();

  /// The form is filled from the controller once, when it has loaded.
  bool _seeded = false;
  bool _busy = false;

  AssistantController get _assistant => widget.assistant;

  DateTime get _now => widget.now ?? DateTime.now();

  @override
  void dispose() {
    _assistantAddress.dispose();
    _sender.dispose();
    _password.dispose();
    super.dispose();
  }

  void _seed() {
    if (_seeded || !_assistant.isLoaded) return;
    _seeded = true;
    _assistantAddress.text = _assistant.assistantAddress;
    _sender.text = _assistant.senderAddress ??
        AssistantController.defaultSenderAddress;
  }

  bool get _formIsComplete =>
      AssistantCopy.isAddress(_assistantAddress.text) &&
      AssistantCopy.isAddress(_sender.text) &&
      _password.text.isNotEmpty;

  /// Writes what is on the form into the controller. The password goes
  /// straight into the keystore and the field is cleared behind it.
  ///
  /// Returns false when the controller refused something, having already said
  /// so on screen.
  Future<bool> _persist() async {
    if (!await _assistant.setAssistantAddress(_assistantAddress.text)) {
      if (mounted) showHomeMessage(context, AssistantCopy.notAnAddress);
      return false;
    }
    final saved = await _assistant.saveAccount(
      address: _sender.text,
      password: _password.text,
    );
    if (!saved) {
      if (mounted) showHomeMessage(context, AssistantCopy.notAnAddress);
      return false;
    }
    _password.clear();
    return true;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Save, on the setup screen: keep the details and turn it on.
  Future<void> _save() => _run(() async {
        if (!await _persist()) return;
        await _assistant.setEnabled(true);
      });

  /// The test email, from either state. On setup it keeps the typed details
  /// first, because a test of something other than what is on screen would
  /// answer the wrong question.
  Future<void> _test() => _run(() async {
        if (!_assistant.hasAccount || _password.text.isNotEmpty) {
          if (!await _persist()) return;
        }
        await _assistant.sendTestEmail();
      });

  Future<void> _editWakePhrase() async {
    final phrase = await showDialog<String>(
      context: context,
      builder: (context) => _WakePhraseDialog(initial: _assistant.wakePhrase),
    );
    if (phrase == null) return;
    final ok = await _assistant.setWakePhrase(phrase);
    if (!ok && mounted) showHomeMessage(context, AssistantCopy.wakeTooShort);
  }

  Future<void> _forget() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: const RoundedRectangleBorder(borderRadius: AppShape.card),
        title: const Text(AssistantCopy.forgetTitle, style: AppText.title22),
        content: const Text(
          AssistantCopy.forgetBody,
          style: AppText.footnote12,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(AssistantCopy.cancel, style: AppText.label13),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              AssistantCopy.forgetConfirm,
              style: AppText.label13.copyWith(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _assistant.forgetEverything();
    // The form goes back to its defaults, so the setup screen is not showing
    // details the phone has just been told to forget.
    _password.clear();
    _seeded = false;
    if (mounted) setState(_seed);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _assistant,
      builder: (context, _) {
        _seed();
        return ScreenScaffold(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (widget.onBack != null)
                Transform.translate(
                  offset: const Offset(-12, 0),
                  child: TapTarget(
                    onTap: widget.onBack,
                    semanticLabel: 'Back',
                    child: const AppIcon(
                      AppGlyph.chevronLeft,
                      size: 20,
                      color: AppColors.textSecondary,
                      strokeWidth: 1.7,
                    ),
                  ),
                ),
              const Text(AssistantCopy.title, style: AppText.title22),
              const SizedBox(height: 10),
              Expanded(
                child: !_assistant.isLoaded
                    ? const SizedBox.shrink()
                    : _assistant.hasAccount
                        ? _settled()
                        : _setup(),
              ),
            ],
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------------ setup

  Widget _setup() {
    return ListView(
      padding: EdgeInsets.zero,
      children: <Widget>[
        const Text(AssistantCopy.blurbOne, style: AppText.body13),
        const SizedBox(height: 4),
        const Text(AssistantCopy.blurbTwo, style: AppText.body13),
        if (_assistant.needsSetup) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            AssistantCopy.finishSetup,
            style: AppText.body13.copyWith(color: AppColors.warning),
          ),
        ],
        const SizedBox(height: 26),
        const SectionCaption(AssistantCopy.assistantCaption),
        const SizedBox(height: 8),
        _Field(
          controller: _assistantAddress,
          hint: AssistantCopy.assistantHint,
          keyboardType: TextInputType.emailAddress,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 24),
        const SectionCaption(AssistantCopy.senderCaption),
        const SizedBox(height: 8),
        _Field(
          controller: _sender,
          hint: AssistantCopy.senderHint,
          keyboardType: TextInputType.emailAddress,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 10),
        _Field(
          controller: _password,
          hint: AssistantCopy.passwordHint,
          obscure: true,
          onChanged: (_) => setState(() {}),
        ),
        TapTarget(
          onTap: () => showInfoSheet(
            context,
            title: AssistantCopy.appPasswordTitle,
            body: AssistantCopy.appPasswordBody,
          ),
          semanticLabel: AssistantCopy.appPasswordLink,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              AssistantCopy.appPasswordLink,
              style: AppText.label13.copyWith(color: AppColors.purpleText),
            ),
          ),
        ),
        const Text(AssistantCopy.spareAddress, style: AppText.footnote12),
        const Text(AssistantCopy.approveOnce, style: AppText.footnote12),
        const SizedBox(height: 24),
        _testButton(),
        const SizedBox(height: 10),
        PrimaryButton(
          label: AssistantCopy.save,
          onPressed: _formIsComplete && !_busy ? () => unawaited(_save()) : null,
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  // ---------------------------------------------------------------- settled

  Widget _settled() {
    final sends = _assistant.recentSends(3);
    return ListView(
      padding: EdgeInsets.zero,
      children: <Widget>[
        const SizedBox(height: 8),
        AppCard(
          padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(AssistantCopy.sendingRow, style: AppText.rowTitle),
                    const SizedBox(height: 4),
                    Text(
                      _assistant.enabled
                          ? AssistantCopy.rowOn
                          : AssistantCopy.rowOff,
                      style: AppText.rowMeta,
                    ),
                  ],
                ),
              ),
              HomeSwitch(
                label: AssistantCopy.sendingRow,
                value: _assistant.enabled,
                onChanged: (on) => unawaited(_assistant.setEnabled(on)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const SectionCaption(AssistantCopy.wakeCaption),
        const SizedBox(height: 8),
        AppCard(
          padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // The phrase carries its own comma - the default is
                    // "Instinct," - so nothing is added to it here.
                    Text(
                      '“${_assistant.wakePhrase}”',
                      style: AppText.rowTitle,
                    ),
                    const SizedBox(height: 4),
                    const Text(AssistantCopy.wakeMeta, style: AppText.rowMeta),
                  ],
                ),
              ),
              _Pill(
                label: AssistantCopy.edit,
                onTap: () => unawaited(_editWakePhrase()),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const SectionCaption(AssistantCopy.emailCaption),
        const SizedBox(height: 8),
        AppCard(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            children: <Widget>[
              _AddressRow(
                label: AssistantCopy.to,
                value: _assistant.assistantAddress,
              ),
              const SizedBox(height: 10),
              _AddressRow(
                label: AssistantCopy.from,
                value: _assistant.senderAddress ?? '',
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _assistant.canVibrate
              ? AssistantCopy.buzzes
              : AssistantCopy.cannotBuzz,
          style: AppText.footnote12,
        ),
        const SizedBox(height: 12),
        _testButton(),
        const SizedBox(height: 18),
        const SectionCaption(AssistantCopy.recentCaption),
        const SizedBox(height: 6),
        if (sends.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(AssistantCopy.nothingSentYet, style: AppText.rowMeta),
          )
        else
          for (final send in sends)
            _SendRow(
              send: send,
              now: _now,
              onRetry: send.status == AssistantSendStatus.failed
                  ? () => unawaited(_assistant.retry(send.noteId))
                  : null,
            ),
        if (_assistant.hasPending) ...<Widget>[
          const SizedBox(height: 8),
          const Text(AssistantCopy.waiting, style: AppText.rowMeta),
        ],
        const SizedBox(height: 24),
        _ForgetButton(onPressed: () => unawaited(_forget())),
        const SizedBox(height: 16),
      ],
    );
  }

  /// "Send a test email", and the one line underneath that says how it went.
  Widget _testButton() {
    final sending = _assistant.testState == AssistantTestState.sending;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        QuietButton(
          label: sending ? AssistantCopy.testSending : AssistantCopy.test,
          onPressed: sending || _busy || !(_assistant.hasAccount || _formIsComplete)
              ? null
              : () => unawaited(_test()),
        ),
        ?_testState(),
      ],
    );
  }

  Widget? _testState() {
    final message = switch (_assistant.testState) {
      AssistantTestState.idle || AssistantTestState.sending => null,
      AssistantTestState.sent => AssistantCopy.testSent,
      AssistantTestState.failed => _assistant.testFailure?.message,
    };
    if (message == null) return null;
    final good = _assistant.testState == AssistantTestState.sent;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        message,
        style: AppText.footnote12.copyWith(
          color: good ? AppColors.connected : AppColors.warning,
        ),
      ),
    );
  }
}

/// One of the form's fields. The mock puts the label inside the field, so an
/// empty form has one column to read rather than two.
class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.hint,
    this.obscure = false,
    this.keyboardType,
    this.autofocus = false,
    this.onChanged,
  });

  final TextEditingController controller;
  final String hint;

  /// True for the app password, and for nothing else in this app.
  final bool obscure;
  final TextInputType? keyboardType;
  final bool autofocus;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: AppShape.minTapTarget),
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border.all(color: AppColors.raised),
        borderRadius: AppShape.control,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.centerLeft,
      child: TextField(
        controller: controller,
        obscureText: obscure,
        // The password must not be offered to a suggestion strip or an
        // autocorrect dictionary on its way in.
        autocorrect: !obscure,
        enableSuggestions: !obscure,
        autofocus: autofocus,
        keyboardType: keyboardType,
        onChanged: onChanged,
        style: AppText.meta14.copyWith(color: AppColors.textPrimary),
        cursorColor: AppColors.purpleText,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          hintText: hint,
          hintStyle: AppText.meta14,
        ),
      ),
    );
  }
}

/// The one field behind "Edit" on the wake phrase.
///
/// A WIDGET OF ITS OWN, so the [TextEditingController] lives exactly as long
/// as the dialog does. Disposing one the moment `showDialog` returns is a use
/// after dispose: the route is still animating out and still rebuilding the
/// field it is holding.
class _WakePhraseDialog extends StatefulWidget {
  const _WakePhraseDialog({required this.initial});

  final String initial;

  @override
  State<_WakePhraseDialog> createState() => _WakePhraseDialogState();
}

class _WakePhraseDialogState extends State<_WakePhraseDialog> {
  late final TextEditingController _field =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: AppShape.card),
      title: const Text(AssistantCopy.wakeCaption, style: AppText.title22),
      content: _Field(
        controller: _field,
        hint: AssistantCopy.wakeCaption,
        autofocus: true,
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(AssistantCopy.cancel, style: AppText.label13),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_field.text),
          child: Text(
            AssistantCopy.save,
            style: AppText.label13.copyWith(color: AppColors.purpleText),
          ),
        ),
      ],
    );
  }
}

/// `To instinct@…` / `From notes@…`, on one line each.
///
/// NOT [KeyValueRow], which sizes its value to the text: a real address is
/// longer than the mock's `example.com` one and pushed the row off the card.
/// The label is what gives way here, and the address ellipsises rather than
/// wrapping, because the interesting end of an address is the front.
class _AddressRow extends StatelessWidget {
  const _AddressRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Text(label, style: AppText.devLabel),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            style: AppText.devValue,
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// The mock's small outlined pill - "Edit".
class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapTarget(
      onTap: onTap,
      semanticLabel: label,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border),
          borderRadius: AppShape.pill,
        ),
        child: Text(label, style: AppText.label13),
      ),
    );
  }
}

/// One row of "Recent sends": what was said, when, and whether it went.
class _SendRow extends StatelessWidget {
  const _SendRow({required this.send, required this.now, this.onRetry});

  final AssistantSend send;
  final DateTime now;

  /// Non-null on a failed row: tapping it tries again.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = send.status == AssistantSendStatus.failed;
    final word = switch (send.status) {
      AssistantSendStatus.sent => AssistantCopy.sent,
      AssistantSendStatus.failed => AssistantCopy.failed,
      _ => null,
    };
    final row = Container(
      constraints: const BoxConstraints(minHeight: AppShape.minTapTarget),
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.raised)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  AssistantCopy.firstLine(send.instruction),
                  style: AppText.rowTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  AssistantCopy.when(send.spokenAt, now: now),
                  style: AppText.rowMeta,
                ),
              ],
            ),
          ),
          if (word != null) ...<Widget>[
            const SizedBox(width: 12),
            Text(
              word,
              style: AppText.meta12.copyWith(
                color: failed ? AppColors.error : AppColors.connected,
              ),
            ),
          ],
        ],
      ),
    );
    final retry = onRetry;
    if (retry == null) return row;
    return Semantics(
      button: true,
      label: '${AssistantCopy.sendAgain}: '
          '${AssistantCopy.firstLine(send.instruction)}',
      container: true,
      excludeSemantics: true,
      onTap: retry,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: retry,
        child: row,
      ),
    );
  }
}

/// "Turn off and forget these details". Red because it takes something away,
/// an outline because it is not what the screen is for - the same pair of
/// reasons as Disconnect on Recorder settings.
class _ForgetButton extends StatelessWidget {
  const _ForgetButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: AssistantCopy.forget,
      container: true,
      excludeSemantics: true,
      onTap: onPressed,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Container(
          height: AppShape.minTapTarget + 2,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.errorBorder),
            borderRadius: AppShape.control,
          ),
          child: Text(
            AssistantCopy.forget,
            style: AppText.buttonLabelQuiet.copyWith(color: AppColors.error),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The Undo banner
// ---------------------------------------------------------------------------

/// The banner above the tab bar while an instruction can still be stopped.
///
/// NOTHING HAS BEEN SENT while this is on screen: the outbox will not touch an
/// entry whose undo window is open. The countdown is driven from
/// [AssistantController.undoRemaining], which is the same clock the outbox
/// uses, so what the user reads and what the queue does cannot drift apart.
///
/// AN UNDO THAT ARRIVES TOO LATE SAYS SO. [AssistantController.undo] returns
/// false once the window has closed, and the banner then reads "Already sent
/// to Instinct" rather than claiming it stopped something.
class AssistantUndoBanner extends StatefulWidget {
  const AssistantUndoBanner({required this.assistant, super.key});

  final AssistantController assistant;

  /// How often the countdown is redrawn. Fast enough that the number never
  /// looks stuck, slow enough to cost nothing.
  static const Duration tick = Duration(milliseconds: 200);

  /// How long the outcome of an Undo stays up before the banner goes.
  static const Duration outcomeLinger = Duration(seconds: 2);

  @override
  State<AssistantUndoBanner> createState() => _AssistantUndoBannerState();
}

class _AssistantUndoBannerState extends State<AssistantUndoBanner> {
  Timer? _ticker;
  Timer? _linger;

  /// What an Undo tap did, while it is still being shown.
  String? _outcome;
  String? _outcomeInstruction;

  AssistantController get _assistant => widget.assistant;

  @override
  void initState() {
    super.initState();
    _assistant.addListener(_onChanged);
  }

  @override
  void dispose() {
    _assistant.removeListener(_onChanged);
    _ticker?.cancel();
    _linger?.cancel();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// The one entry whose undo window is open, or null.
  AssistantSend? get _open {
    for (final send in _assistant.recentSends(5)) {
      if (send.status == AssistantSendStatus.pendingUndo &&
          _assistant.undoRemaining(send.noteId) > Duration.zero) {
        return send;
      }
    }
    return null;
  }

  /// One timer, running only while there is a countdown to draw.
  void _syncTicker(bool wanted) {
    if (wanted && _ticker == null) {
      _ticker = Timer.periodic(AssistantUndoBanner.tick, (_) {
        if (mounted) setState(() {});
      });
    } else if (!wanted && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  Future<void> _undo(AssistantSend send) async {
    final stopped = await _assistant.undo(send.noteId);
    if (!mounted) return;
    setState(() {
      _outcome = stopped ? AssistantCopy.stopped : AssistantCopy.tooLate;
      _outcomeInstruction = send.instruction;
    });
    _linger?.cancel();
    _linger = Timer(AssistantUndoBanner.outcomeLinger, () {
      if (mounted) {
        setState(() {
          _outcome = null;
          _outcomeInstruction = null;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final outcome = _outcome;
    if (outcome != null) {
      _syncTicker(false);
      return _banner(
        title: outcome,
        instruction: _outcomeInstruction ?? '',
        action: null,
      );
    }
    final send = _open;
    _syncTicker(send != null);
    if (send == null) return const SizedBox.shrink();
    final left = _assistant.undoRemaining(send.noteId);
    return _banner(
      title: AssistantCopy.sendingTo,
      instruction: send.instruction,
      action: _UndoPill(
        seconds: (left.inMilliseconds / 1000).ceil(),
        onTap: () => unawaited(_undo(send)),
      ),
    );
  }

  Widget _banner({
    required String title,
    required String instruction,
    required Widget? action,
  }) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: const BoxDecoration(
        color: AppColors.raised,
        borderRadius: AppShape.control,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: AppText.rowTitle),
                const SizedBox(height: 4),
                Text(
                  AssistantCopy.firstLine(instruction),
                  style: AppText.rowMeta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (action != null) ...<Widget>[
            const SizedBox(width: 12),
            action,
          ],
        ],
      ),
    );
  }
}

/// "Undo 4 s". The number sits in the pill rather than draining it: a ring
/// that empties says "hurry", and the point of this window is that it is
/// unhurried.
class _UndoPill extends StatelessWidget {
  const _UndoPill({required this.seconds, required this.onTap});

  final int seconds;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapTarget(
      onTap: onTap,
      semanticLabel: '${AssistantCopy.undo}, $seconds seconds left',
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border),
          borderRadius: AppShape.pill,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              AssistantCopy.undo,
              style: AppText.label13.copyWith(color: AppColors.purpleText),
            ),
            const SizedBox(width: 6),
            Text('$seconds s', style: AppText.rowMeta),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The note screen's mark
// ---------------------------------------------------------------------------

/// "Sent to Instinct" above a note's title - or, when it did not go, the amber
/// line that tries again.
///
/// Nothing at all for a note nobody addressed to the assistant, which is
/// almost every note.
class AssistantNoteMark extends StatelessWidget {
  const AssistantNoteMark({
    required this.assistant,
    required this.noteId,
    super.key,
  });

  final AssistantController assistant;

  /// The recording's path - the id the whole app uses.
  final String noteId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: assistant,
      builder: (context, _) {
        switch (assistant.statusFor(noteId)) {
          case AssistantSendStatus.sent:
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: <Widget>[
                  const HomeIcon(
                    HomeGlyph.check,
                    size: 14,
                    color: AppColors.connected,
                    strokeWidth: 1.8,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    AssistantCopy.sentMark,
                    style: AppText.rowMeta.copyWith(
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            );
          case AssistantSendStatus.failed:
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: TapTarget(
                minSize: 0,
                onTap: () => unawaited(assistant.retry(noteId)),
                semanticLabel: AssistantCopy.failedMark,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const StatusDot(color: AppColors.warning, size: 7),
                      const SizedBox(width: 7),
                      Text(
                        AssistantCopy.failedMark,
                        style: AppText.meta12
                            .copyWith(color: AppColors.warning),
                      ),
                    ],
                  ),
                ),
              ),
            );
          case AssistantSendStatus.notSent:
            return const SizedBox.shrink();
          case AssistantSendStatus.pendingUndo:
          case AssistantSendStatus.queued:
          case AssistantSendStatus.sending:
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                AssistantCopy.sendingTo,
                style: AppText.rowMeta,
              ),
            );
        }
      },
    );
  }
}
