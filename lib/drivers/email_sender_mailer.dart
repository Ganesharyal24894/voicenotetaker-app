/// The one file in this app that opens a socket to say something.
///
/// WHY `mailer` AND NOT SOMETHING ELSE.
///
///   * An HTTP API (SendGrid, Mailgun, Resend, Gmail's REST API) would mean a
///     third party holding a key that can send mail as the user, an account to
///     keep alive, and - for Gmail's own API - an OAuth consent screen and a
///     Google verification review for a restricted scope. The user's assistant
///     accepts mail from any address once authorised; it does not need a
///     provider, and adding one would put a company between a voice note and
///     the person it was for.
///   * A platform intent (`ACTION_SEND` / `MFMailComposeViewController`) opens
///     a mail app with the message filled in and waits for a tap. That is not
///     hands-free, which is the entire point of speaking an instruction.
///   * Writing SMTP by hand means implementing STARTTLS, AUTH LOGIN, dot
///     stuffing, MIME encoding and header folding - all of it security
///     sensitive and none of it this app's business.
///
/// `mailer` is MIT, pure Dart (no platform channel, no native dependency),
/// speaks SMTP over an implicit-TLS or STARTTLS socket, and is the package the
/// Dart ecosystem has used for this since 2014. It is named here and nowhere
/// else, so swapping it is one file.
library;

import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:mailer/mailer.dart' as mailer;
import 'package:mailer/smtp_server.dart' as mailer;

import '../model/assistant/assistant_message.dart';
import 'email_sender.dart';

/// [EmailSender] over SMTP.
class MailerEmailSender implements EmailSender {
  const MailerEmailSender({this.timeout = defaultTimeout});

  /// One attempt does not get to hold a socket open for longer than this. The
  /// outbox will try again on its own schedule; a socket that hangs on a dying
  /// Wi-Fi must not keep the queue occupied.
  static const Duration defaultTimeout = Duration(seconds: 30);

  final Duration timeout;

  @override
  Future<EmailResult> send(
    AssistantMessage message,
    SmtpAccount account,
  ) async {
    if (!account.isComplete) {
      return const EmailResult.failed(EmailFailure.signIn);
    }
    final server = mailer.SmtpServer(
      account.host,
      port: account.port,
      // 465: TLS from the first byte. When this is false the library still
      // upgrades with STARTTLS and, because `allowInsecure` is left false,
      // ABORTS rather than sending the password in the clear.
      ssl: account.useSsl,
      username: account.address,
      password: account.password,
    );

    final envelope = mailer.Message()
      ..from = mailer.Address(message.from)
      ..recipients.add(message.to)
      ..subject = message.subject
      // Plain text only. No `html`, no `attachments`: there is nothing to
      // attach and nowhere for anything else to ride along.
      ..text = message.body;

    try {
      await mailer.send(envelope, server, timeout: timeout);
      return const EmailResult.sent();
    } on mailer.SmtpClientAuthenticationException {
      return const EmailResult.failed(EmailFailure.signIn);
    } on mailer.SmtpMessageValidationException {
      return const EmailResult.failed(EmailFailure.recipient);
    } on mailer.SmtpUnsecureException {
      // The server offered no TLS. Nothing is sent in the clear, ever.
      return const EmailResult.failed(EmailFailure.connection);
    } on mailer.SmtpNoGreetingException {
      return const EmailResult.failed(EmailFailure.connection);
    } on mailer.SmtpClientCommunicationException catch (error) {
      return EmailResult.failed(failureForResponse(error.message));
    } on SocketException {
      return const EmailResult.failed(EmailFailure.connection);
    } on TimeoutException {
      return const EmailResult.failed(EmailFailure.connection);
    } on Object {
      // Deliberately not logged: a mailer exception can carry the SMTP
      // conversation, and the SMTP conversation carries the password.
      return const EmailResult.failed(EmailFailure.unknown);
    }
  }

  /// An SMTP reply code out of a communication failure's message.
  ///
  /// 5xx about a recipient is permanent; 5xx about authentication is a sign-in
  /// problem; everything else - 4xx especially - is worth another go. This is
  /// what decides whether an instruction is retried for twelve minutes or
  /// dropped at once, so it is exposed for a test rather than trusted.
  ///
  /// The message it is given is NEVER logged or returned - only the enum is.
  @visibleForTesting
  static EmailFailure failureForResponse(String message) {
    final code = RegExp(r'\b([45]\d\d)\b').firstMatch(message)?.group(1);
    if (code == null) return EmailFailure.unknown;
    if (code.startsWith('4')) return EmailFailure.server;
    return switch (code) {
      '530' || '534' || '535' || '538' => EmailFailure.signIn,
      '550' || '551' || '553' || '554' => EmailFailure.recipient,
      _ => EmailFailure.server,
    };
  }
}
