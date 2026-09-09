/// Fixed identifiers of the voiceNotetaker peripheral.
///
/// The device is the fixed party in this relationship; the app adapts to it.
/// These constants live in `model/` (not `drivers/`) so that replacing the BLE
/// package never means retyping UUIDs.
abstract final class DeviceProfile {
  /// Advertised local name.
  static const String advertisedName = 'voiceNotetaker';

  /// Custom GATT service carrying the audio stream.
  static const String serviceUuid = '6e40fe00-b5a3-f393-e0a9-e50e24dcca9e';

  /// `fe01` - NOTIFY, audio frames.
  static const String dataCharacteristicUuid =
      '6e40fe01-b5a3-f393-e0a9-e50e24dcca9e';

  /// `fe02` - READ, packed stream info (see [StreamInfo]).
  static const String infoCharacteristicUuid =
      '6e40fe02-b5a3-f393-e0a9-e50e24dcca9e';

  /// `fe03` - WRITE, one byte selecting the codec.
  static const String controlCharacteristicUuid =
      '6e40fe03-b5a3-f393-e0a9-e50e24dcca9e';

  /// Every notification is prefixed with a little-endian uint16 sequence
  /// number; gaps in it are packets dropped on the link.
  static const int sequenceHeaderBytes = 2;

  /// ADPCM block header: int16 predictor (LE), uint8 step index, uint8 reserved.
  static const int adpcmBlockHeaderBytes = 4;

  /// Samples the firmware packs into one ADPCM block.
  static const int adpcmSamplesPerBlock = 320;

  /// Resulting on-air block size: 4 header bytes + 320 nibbles.
  static const int adpcmBlockBytes =
      adpcmBlockHeaderBytes + adpcmSamplesPerBlock ~/ 2;
}
