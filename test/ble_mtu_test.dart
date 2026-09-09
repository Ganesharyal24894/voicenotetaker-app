import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/drivers/ble_transport_universal.dart';
import 'package:voicenotetaker_app/model/device_profile.dart';

/// Regression guard for a bug found on real hardware.
///
/// The app connected happily and recorded a WAV containing nothing but its
/// 44-byte header. Cause: nobody requested an ATT MTU, so the link stayed at
/// Android's 23-byte default, leaving 20 bytes of notification payload. A
/// 166-byte ADPCM frame cannot fit, so the firmware correctly refused to send
/// and dropped every frame -- 300,800 bytes of audio, silently, from the
/// user's point of view.
///
/// These tests pin the arithmetic so lowering the requested MTU, or growing a
/// frame past it, fails here rather than on a phone.
void main() {
  /// A notification value is the ATT MTU minus the 3-byte ATT header
  /// (opcode + handle).
  const attHeaderBytes = 3;

  /// Frame layout on the wire: 2-byte sequence number, then the payload.
  const seqHeaderBytes = 2;

  /// One self-contained IMA ADPCM block: 4-byte state header, then 320
  /// samples at 4 bits each.
  const adpcmBlockBytes = 4 + (DeviceProfile.adpcmSamplesPerBlock ~/ 2);

  test('an ADPCM frame does not fit the default 23-byte ATT MTU', () {
    const defaultMtu = 23;
    const usable = defaultMtu - attHeaderBytes;
    const needed = seqHeaderBytes + adpcmBlockBytes;

    expect(needed, greaterThan(usable),
        reason: 'if this ever passes the MTU request has become optional; '
            'until then it is mandatory and must not be removed');
    expect(usable, 20);
    expect(needed, 166);
  });

  test('the requested MTU is large enough for an ADPCM frame', () {
    final usable = UniversalBleTransport.desiredMtu - attHeaderBytes;
    const needed = seqHeaderBytes + adpcmBlockBytes;

    expect(usable, greaterThanOrEqualTo(needed),
        reason: 'lowering desiredMtu below ${needed + attHeaderBytes} silently '
            'breaks streaming: the firmware drops frames it cannot send');
  });

  test('the requested MTU also covers a full raw-PCM frame', () {
    // Raw PCM is diagnostic-only and iOS will not carry it, but on Android
    // the requested MTU should not be the thing that prevents it.
    const maxPcmFrame = seqHeaderBytes + 242;
    final usable = UniversalBleTransport.desiredMtu - attHeaderBytes;

    expect(usable, greaterThanOrEqualTo(maxPcmFrame));
  });
}
