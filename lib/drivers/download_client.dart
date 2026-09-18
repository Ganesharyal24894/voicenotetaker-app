import 'dart:async';
import 'dart:io';

/// Raised for anything that went wrong on the wire, so `services/` never sees
/// a `dart:io` type.
class DownloadException implements Exception {
  const DownloadException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'DownloadException: $message${cause == null ? '' : ' ($cause)'}';
}

/// One HTTP response, as a download cares about it.
class DownloadResponse {
  const DownloadResponse({
    required this.statusCode,
    required this.contentLength,
    required this.body,
    required this.abort,
  });

  final int statusCode;

  /// Length of THIS response body, or null when the server did not say.
  /// For a resumed request this is what is still to come, not the file.
  final int? contentLength;

  /// The bytes. Listened to once.
  final Stream<List<int>> body;

  /// 206: the server honoured the range and is sending the rest.
  bool get isPartial => statusCode == 206;

  /// 200: the whole file, whatever was asked for. A resumed request that gets
  /// this has to start again from zero.
  bool get isWholeFile => statusCode == 200;

  /// Stops the transfer without waiting for the rest of the body. Safe to call
  /// twice.
  final Future<void> Function() abort;
}

/// Fetching a file over HTTP, with the two things a model download needs:
/// a byte range, and a way to stop.
///
/// Abstract like every other driver, so the downloader service can be tested
/// against a scripted server with no socket anywhere near it.
///
/// WHY NOT `http` OR `dio`. `http` is not a dependency of this app and its
/// `Client.send` gives no way to abort a response mid-body; `dio` would be a
/// second HTTP stack, a second set of platform adapters and 300 kB of API for
/// two features `dart:io`'s own `HttpClient` already has - `headers.set`
/// ('range', ...) and `subscription.cancel()`. The rule this repo keeps - one
/// abstract driver, one implementation, the package named in one file - makes
/// the small interface below the cheaper option, and it is the same interface
/// either way.
abstract class DownloadClient {
  /// GETs [url]. When [from] is greater than zero, asks for the bytes from
  /// there to the end.
  ///
  /// Throws [DownloadException] when the request cannot be made at all. A
  /// status the caller does not like is NOT an exception: it comes back as
  /// [DownloadResponse.statusCode].
  Future<DownloadResponse> get(String url, {int from = 0});

  /// Releases whatever the implementation holds open.
  void close();
}

/// `dart:io` implementation.
///
/// Follows redirects, which is what a GitHub release asset is: a 302 to a
/// signed storage URL. The `Range` header survives that redirect - verified
/// against the real host, see `tool/verify_download.dart`.
class IoDownloadClient implements DownloadClient {
  IoDownloadClient({Duration? connectionTimeout, Duration? idleTimeout})
      : _client = HttpClient()
          ..connectionTimeout = connectionTimeout ?? const Duration(seconds: 20)
          ..idleTimeout = idleTimeout ?? const Duration(seconds: 15)
          // The bytes are already compressed model weights; asking for gzip
          // only costs the phone a decompression pass, and it would make
          // `contentLength` describe the wire rather than the file.
          ..autoUncompress = false;

  final HttpClient _client;

  @override
  Future<DownloadResponse> get(String url, {int from = 0}) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.isScheme('https')) {
      throw DownloadException('not an https URL: $url');
    }
    try {
      final request = await _client.getUrl(uri);
      request.followRedirects = true;
      request.maxRedirects = 5;
      if (from > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
      final response = await request.close();
      return DownloadResponse(
        statusCode: response.statusCode,
        contentLength:
            response.contentLength < 0 ? null : response.contentLength,
        body: response,
        abort: () async {
          try {
            // Drops the connection without reading the body. Throws when the
            // caller is already listening - and then cancelling THAT
            // subscription is what stops it, so there is nothing to do here.
            await response.listen(null, cancelOnError: true).cancel();
          } on Object {
            // Nothing left to stop, which is the outcome asked for.
          }
        },
      );
    } on SocketException catch (error) {
      throw DownloadException('could not reach $url', error);
    } on HttpException catch (error) {
      throw DownloadException('the request to $url failed', error);
    } on HandshakeException catch (error) {
      throw DownloadException('could not secure the connection to $url', error);
    } on TimeoutException catch (error) {
      throw DownloadException('$url did not answer', error);
    }
  }

  @override
  void close() => _client.close(force: true);
}
