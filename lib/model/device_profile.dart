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

  /// `fe04` - READ + WRITE, one byte holding the auto-sleep flag (see
  /// [AutoSleep]). The firmware persists it in flash, so it survives a
  /// reboot and must be read rather than assumed.
  ///
  /// Firmware older than this characteristic simply does not have it; the app
  /// treats the absence as "setting unavailable", never as "off".
  static const String autoSleepCharacteristicUuid =
      '6e40fe04-b5a3-f393-e0a9-e50e24dcca9e';

  /// `fe05` - READ + NOTIFY, two bytes of battery status (see
  /// [BatteryStatus]). Read once on connect and then followed by
  /// notifications, so the reading on screen stays live.
  ///
  /// Firmware older than this characteristic simply does not have it; the app
  /// treats the absence as "battery unavailable", never as a flat cell.
  static const String batteryCharacteristicUuid =
      '6e40fe05-b5a3-f393-e0a9-e50e24dcca9e';

  /// `fe07` - READ + NOTIFY, two bytes of nRF52840 DIE temperature (see
  /// [DieTemperature]): a little-endian signed int16 in decidegrees Celsius,
  /// with `0x8000` meaning unknown.
  ///
  /// A DIE temperature, not an ambient one. The sensor is inside the same
  /// package as the CPU and the radio, so it reads above the room, and it
  /// reads higher again inside a plastic case with a cell underneath. Firmware
  /// older than this characteristic simply does not have it; the app treats
  /// the absence as "temperature unavailable", never as 0 °C.
  static const String temperatureCharacteristicUuid =
      '6e40fe07-b5a3-f393-e0a9-e50e24dcca9e';

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
