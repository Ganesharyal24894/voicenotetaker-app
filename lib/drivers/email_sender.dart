/// THE ONLY WAY ANYTHING LEAVES THIS PHONE BY ITSELF.
///
/// Everything else in the app is either offline or user-driven: the model
/// downloader pulls files IN, the export writes a zip to disk and hands it to
/// the share sheet, and the summary prompt goes through the clipboard. This
/// seam is the single outbound path, and it carries exactly one kind of thing:
/// one [AssistantMessage] per note the user addressed to their assistant.
///
/// Abstract like every other driver, for the usual reason and one more: the
/// tests must be able to prove what is sent WITHOUT a socket, and a fake that
/// records its argument is how that is proved.
library;

import '../model/assistant/assistant_message.dart';

/// What the mail server said, in terms the outbox can act on.
enum EmailFailure {
  /// The server would not accept the sender's password. Permanent.
  signIn,

  /// The server refused the recipient. Permanent.
  recipient,

  /// Could not reach the server at all: no route, DNS, TLS, timeout.
  connection,

  /// Reached it, and it said "not now" - a 4xx, a rate limit, a greylist.
  server,

  /// Something else. Treated as worth one more try.
  unknown,
}

/// The outcome of one attempt.
class EmailResult {
  const EmailResult.sent()
      : ok = true,
        failure = null;

  const EmailResult.failed(this.failure) : ok = false;

  final bool ok;
  final EmailFailure? failure;

  @override
  String toString() => ok ? 'EmailResult(sent)' : 'EmailResult(${failure!.name})';
}

/// How to reach the sending account. Held only in memory and in the
/// platform's own secret store - never in a settings file, never in a log.
class SmtpAccount {
  const SmtpAccount({
    required this.address,
    required this.password,
    this.host = defaultHost,
    this.port = defaultPort,
    this.useSsl = defaultUseSsl,
  });

  /// Gmail, because that is what the user's sending account is. Any SMTP
  /// server works; the setup screen offers these three as the defaults and
  /// lets them be changed.
  static const String defaultHost = 'smtp.gmail.com';

  /// 465, implicit TLS: the connection is encrypted before a single byte of
  /// the password is written. 587 with STARTTLS begins in the clear and can be
  /// stripped by a hostile network; it is available by setting [useSsl] false,
  /// but it is not the default.
  static const int defaultPort = 465;

  static const bool defaultUseSsl = true;

  /// The account the mail is sent FROM, and the SMTP username.
  final String address;

  /// A Gmail app password, or whatever the chosen server wants. NEVER logged,
  /// never put in a [toString], never written to a settings file.
  final String password;

  final String host;
  final int port;
  final bool useSsl;

  bool get isComplete =>
      address.contains('@') && password.isNotEmpty && host.isNotEmpty && port > 0;

  SmtpAccount copyWith({
    String? address,
    String? password,
    String? host,
    int? port,
    bool? useSsl,
  }) =>
      SmtpAccount(
        address: address ?? this.address,
        password: password ?? this.password,
        host: host ?? this.host,
        port: port ?? this.port,
        useSsl: useSsl ?? this.useSsl,
      );

  /// Deliberately without the password, and without the address: this is the
  /// one object a stray `debugPrint` must not be able to leak.
  @override
  String toString() => 'SmtpAccount($host:$port, ssl: $useSsl)';
}

/// Sends one email over SMTP.
abstract class EmailSender {
  /// Sends [message] as [account]. Never throws: every failure comes back as
  /// an [EmailResult] so the outbox has one path to reason about.
  Future<EmailResult> send(AssistantMessage message, SmtpAccount account);
}
