import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/services/frame_reassembler.dart';

/// Builds one notification: 2-byte little-endian sequence header + payload.
Uint8List notification(int sequence, [List<int> payload = const [1, 2, 3]]) {
  final bytes = Uint8List(2 + payload.length);
  ByteData.sublistView(bytes).setUint16(0, sequence, Endian.little);
  bytes.setRange(2, bytes.length, payload);
  return bytes;
}

void main() {
  late FrameReassembler reassembler;

  setUp(() => reassembler = FrameReassembler());

  group('header stripping', () {
    test('the sequence number is read little-endian', () {
      // 0x1234 little-endian is 0x34 0x12.
      final frame = reassembler.accept(
        Uint8List.fromList([0x34, 0x12, 0xAA, 0xBB]),
      );
      expect(frame!.sequence, 0x1234);
    });

    test('the payload is everything after the 2-byte header', () {
      final frame = reassembler.accept(notification(0, [9, 8, 7, 6]));
      expect(frame!.payload, equals(Uint8List.fromList([9, 8, 7, 6])));
    });

    test('a payload-less notification yields an empty payload', () {
      final frame = reassembler.accept(notification(0, const []));
      expect(frame!.payload, isEmpty);
      expect(reassembler.framesReceived, 1);
    });
  });

  group('contiguous streams', () {
    test('no loss is reported for an in-order run', () {
      for (var seq = 0; seq < 100; seq++) {
        final frame = reassembler.accept(notification(seq));
        expect(frame!.droppedBefore, 0);
        expect(frame.hasGap, isFalse);
      }
      expect(reassembler.framesReceived, 100);
      expect(reassembler.framesLost, 0);
      expect(reassembler.lossRatio, 0.0);
    });

    test('the first frame never counts as a gap, whatever its sequence', () {
      final frame = reassembler.accept(notification(40000));
      expect(frame!.droppedBefore, 0);
      expect(reassembler.framesLost, 0);
      expect(reassembler.expectedSequence, 40001);
    });
  });

  group('sequence gaps', () {
    test('a single missing packet is counted once', () {
      reassembler.accept(notification(0));
      final frame = reassembler.accept(notification(2));
      expect(frame!.droppedBefore, 1);
      expect(frame.hasGap, isTrue);
      expect(reassembler.framesLost, 1);
      expect(reassembler.framesReceived, 2);
      expect(reassembler.framesExpected, 3);
    });

    test('a burst gap is counted in full', () {
      reassembler.accept(notification(10));
      final frame = reassembler.accept(notification(60));
      expect(frame!.droppedBefore, 49);
      expect(reassembler.framesLost, 49);
    });

    test('losses accumulate across several gaps', () {
      for (final seq in [0, 2, 5, 6, 10]) {
        reassembler.accept(notification(seq));
      }
      // gaps: 0->2 is 1, 2->5 is 2, 5->6 is 0, 6->10 is 3.
      expect(reassembler.framesLost, 6);
      expect(reassembler.framesReceived, 5);
      expect(reassembler.framesExpected, 11);
      expect(reassembler.lossRatio, closeTo(6 / 11, 1e-12));
    });

    test('tracking resynchronises to the sequence actually received', () {
      reassembler.accept(notification(0));
      reassembler.accept(notification(500));
      expect(reassembler.expectedSequence, 501);
      final frame = reassembler.accept(notification(501));
      expect(frame!.droppedBefore, 0);
    });
  });

  group('16-bit wraparound', () {
    test('0xFFFF followed by 0x0000 is not a gap', () {
      reassembler.accept(notification(0xFFFF));
      expect(reassembler.expectedSequence, 0);
      final frame = reassembler.accept(notification(0));
      expect(frame!.droppedBefore, 0);
      expect(reassembler.framesLost, 0);
    });

    test('a gap spanning the wrap point counts forwards, not backwards', () {
      // 0xFFFE -> 0x0002 skips 0xFFFF, 0x0000 and 0x0001: three packets, not
      // 65532.
      reassembler.accept(notification(0xFFFE));
      final frame = reassembler.accept(notification(2));
      expect(frame!.droppedBefore, 3);
      expect(reassembler.framesLost, 3);
    });

    test('an out-of-order packet reads as an almost-complete wrap', () {
      // Deliberate documentation of the tradeoff: with a bare 16-bit counter
      // and no reordering buffer, seq 0 after seq 5 is indistinguishable from
      // a 65531-packet gap. BLE notifications on one link arrive in order, so
      // this is accepted rather than guessed at.
      reassembler.accept(notification(5));
      final frame = reassembler.accept(notification(0));
      expect(frame!.droppedBefore, 0x10000 - 6);
    });

    test('a full lap of the counter stays contiguous', () {
      for (var i = 0; i < 0x10000 + 10; i++) {
        reassembler.accept(notification(i % 0x10000, const [0]));
      }
      expect(reassembler.framesLost, 0);
      expect(reassembler.framesReceived, 0x10000 + 10);
    });
  });

  group('malformed notifications', () {
    test('a notification shorter than the header is rejected', () {
      expect(reassembler.accept(Uint8List.fromList([7])), isNull);
      expect(reassembler.accept(Uint8List(0)), isNull);
      expect(reassembler.malformedFrames, 2);
      expect(reassembler.framesReceived, 0);
    });

    test('a malformed notification does not disturb sequence tracking', () {
      reassembler.accept(notification(0));
      reassembler.accept(Uint8List.fromList([1]));
      final frame = reassembler.accept(notification(1));
      expect(frame!.droppedBefore, 0);
      expect(reassembler.framesLost, 0);
      expect(reassembler.malformedFrames, 1);
    });

    test('a two-byte notification is valid, not malformed', () {
      final frame = reassembler.accept(notification(3, const []));
      expect(frame, isNotNull);
      expect(reassembler.malformedFrames, 0);
    });
  });

  group('counters', () {
    test('wire bytes include headers and malformed notifications', () {
      reassembler.accept(notification(0, const [1, 2, 3, 4]));
      reassembler.accept(Uint8List.fromList([9]));
      expect(reassembler.wireBytes, 6 + 1);
    });

    test('lossRatio is zero before any frame arrives', () {
      expect(reassembler.lossRatio, 0.0);
      expect(reassembler.framesExpected, 0);
    });

    test('stats mirror the individual counters', () {
      reassembler.accept(notification(0));
      reassembler.accept(notification(3));
      reassembler.accept(Uint8List.fromList([0]));
      final stats = reassembler.stats;
      expect(stats.framesReceived, 2);
      expect(stats.framesLost, 2);
      expect(stats.malformedFrames, 1);
      expect(stats.wireBytes, reassembler.wireBytes);
      expect(stats.lossRatio, closeTo(0.5, 1e-12));
    });

    test('reset clears everything', () {
      reassembler.accept(notification(0));
      reassembler.accept(notification(9));
      reassembler.accept(Uint8List(1));
      reassembler.reset();

      expect(reassembler.expectedSequence, isNull);
      expect(reassembler.framesReceived, 0);
      expect(reassembler.framesLost, 0);
      expect(reassembler.malformedFrames, 0);
      expect(reassembler.wireBytes, 0);

      final frame = reassembler.accept(notification(1234));
      expect(frame!.droppedBefore, 0);
    });
  });
}
