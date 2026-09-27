import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/download_client.dart';

/// The real `IoDownloadClient`, which nothing else tests.
///
/// `model_download_service_test.dart` covers everything the DOWNLOADER decides
/// by scripting the `DownloadClient` interface, so what is left here is the
/// implementation's own decisions - and they are the ones no fake can make on
/// its behalf:
///
///   a 197 MB model is never fetched over plaintext, whatever the catalogue says
///   a host that is not there comes back as a DownloadException, not a
///   SocketException the services layer has no idea what to do with
///
/// Nothing here needs a server, and nothing here needs the network: the scheme
/// guard runs before a socket is opened, and "not there" is a port this test
/// has just closed.
void main() {
  /// A loopback port with nothing listening on it: bound to let the OS choose a
  /// free one, then closed again.
  Future<int> closedPort() async {
    final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close(force: true);
    return port;
  }

  IoDownloadClient build() =>
      IoDownloadClient(connectionTimeout: const Duration(seconds: 2));

  group('only https, and it is decided before a socket is opened', () {
    late IoDownloadClient client;

    setUp(() => client = build());
    tearDown(() => client.close());

    test('plain http is refused, whatever the catalogue asked for', () async {
      // The sha256 check is the only thing between the user and a model
      // somebody swapped in transit, and it is checked AFTER 197 MB have been
      // spent. This is the check that is cheap.
      await expectLater(
        client.get('http://example.com/model.int8.onnx'),
        throwsA(
          isA<DownloadException>().having(
            (e) => e.message,
            'message',
            'not an https URL: http://example.com/model.int8.onnx',
          ),
        ),
      );
    });

    test('so is a URL with no scheme at all', () async {
      await expectLater(
        client.get('example.com/model.int8.onnx'),
        throwsA(isA<DownloadException>()),
      );
    });

    test('and so is something that is not a URL', () async {
      // Uri.tryParse returns null rather than throwing, and the guard has to
      // cope with that itself.
      await expectLater(
        client.get('https://['),
        throwsA(
          isA<DownloadException>().having(
            (e) => e.message,
            'message',
            'not an https URL: https://[',
          ),
        ),
      );
    });

    test('the scheme is read without regard to case', () async {
      // Not a pedantic point: the guard is the only thing reading the scheme,
      // so if it were case-sensitive a perfectly good HTTPS:// URL would be
      // reported to the user as "not an https URL".
      final port = await closedPort();

      await expectLater(
        client.get('HTTPS://127.0.0.1:$port/model.int8.onnx'),
        throwsA(
          isA<DownloadException>().having(
            (e) => e.message,
            'message',
            startsWith('could not reach'),
          ),
        ),
      );
    });
  });

  group('a host that is not there', () {
    test('comes back as a DownloadException naming the URL', () async {
      final client = build();
      addTearDown(client.close);
      final port = await closedPort();
      final url = 'https://127.0.0.1:$port/model.int8.onnx';

      // The point is the TYPE. `services/` catches DownloadException; a
      // SocketException escaping here would be an unhandled error on a phone
      // that merely walked into a lift.
      await expectLater(
        client.get(url),
        throwsA(
          isA<DownloadException>()
              .having((e) => e.message, 'message', 'could not reach $url')
              .having((e) => e.cause, 'cause', isNotNull),
        ),
      );
    });

    test('and it is the same whether or not a range was asked for', () async {
      final client = build();
      addTearDown(client.close);
      final port = await closedPort();

      // Resuming must fail the same way as starting: the service decides
      // whether to retry from the exception, and a resumed attempt that threw
      // something else would abandon a part-downloaded 197 MB file.
      await expectLater(
        client.get('https://127.0.0.1:$port/model.int8.onnx', from: 1024),
        throwsA(isA<DownloadException>()),
      );
    });
  });

  group('what a response says about itself', () {
    DownloadResponse response(int statusCode) => DownloadResponse(
          statusCode: statusCode,
          contentLength: 0,
          body: const Stream<List<int>>.empty(),
          abort: () async {},
        );

    test('206 is a partial and 200 is the whole file, and nothing else is',
        () {
      // This pair is how a resumed download decides whether to keep the bytes
      // on disk or throw them away: a server that answered 200 to a Range
      // request is sending the file from zero, so appending would corrupt it.
      expect(response(206).isPartial, isTrue);
      expect(response(206).isWholeFile, isFalse);
      expect(response(200).isWholeFile, isTrue);
      expect(response(200).isPartial, isFalse);

      for (final status in <int>[416, 304, 404, 500]) {
        expect(response(status).isPartial, isFalse, reason: '$status');
        expect(response(status).isWholeFile, isFalse, reason: '$status');
      }
    });

    test('a length the server did not give is null, not minus one', () {
      // `dart:io` reports -1 for "no Content-Length". Letting that through
      // would make the downloader compare bytes against a negative expected
      // size and call a good file corrupt.
      expect(response(200).contentLength, 0);
      expect(
        DownloadResponse(
          statusCode: 200,
          contentLength: null,
          body: const Stream<List<int>>.empty(),
          abort: () async {},
        ).contentLength,
        isNull,
      );
    });
  });

  test('a download exception reads as one line, with the cause if there is one',
      () {
    expect(
      const DownloadException('could not reach x').toString(),
      'DownloadException: could not reach x',
    );
    expect(
      const DownloadException('could not reach x', 'refused').toString(),
      'DownloadException: could not reach x (refused)',
    );
  });
}
