import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/assistant/assistant_settings.dart';
import 'package:voicenotetaker_app/model/assistant/wake_phrase.dart';
import 'package:voicenotetaker_app/services/assistant/assistant_settings_store.dart';

import 'assistant_fakes.dart';

const AssistantSettings _defaults = AssistantSettings();
const String _directory = '/data/settings';
const String _path = '$_directory/${AssistantSettingsStore.fileName}';

AssistantSettingsStore _store(MemoryFileStore files) =>
    AssistantSettingsStore(fileStore: files, directory: _directory);

/// A store whose file is there but will not come back off the disk.
class _UnreadableFileStore extends MemoryFileStore {
  @override
  Future<Uint8List> read(String path) async =>
      throw const FileSystemExceptionStub('unreadable');
}

void main() {
  group('the defaults are the privacy promise', () {
    test('a fresh install is off', () {
      expect(_defaults.enabled, isFalse);
    });

    test('the wake phrase is the detector default', () {
      expect(_defaults.wakePhrase, WakePhraseDetector.defaultPhrase);
      expect(_defaults.wakePhrase, 'Instinct,');
    });

    test('the assistant address is the documented one', () {
      expect(_defaults.assistantAddress,
          AssistantSettings.defaultAssistantAddress);
      expect(_defaults.assistantAddress, 'bo1dx6@mail.instinct.com');
      expect(_defaults.assistantAddress, testAssistant);
    });

    test('the sending account the setup screen offers', () {
      expect(AssistantSettings.defaultSenderAddress, 'giftinjsr@gmail.com');
      expect(AssistantSettings.defaultSenderAddress, testAccount.address);
    });
  });

  group('copyWith and value semantics', () {
    test('copyWith changes one field and leaves the rest', () {
      final on = _defaults.copyWith(enabled: true);
      expect(on.enabled, isTrue);
      expect(on.wakePhrase, _defaults.wakePhrase);
      expect(on.assistantAddress, _defaults.assistantAddress);
    });

    test('copyWith with nothing given changes nothing', () {
      expect(_defaults.copyWith(), _defaults);
    });

    test('copyWith can change the phrase and the address', () {
      final changed = _defaults.copyWith(
        wakePhrase: 'Jarvis,',
        assistantAddress: 'other@example.org',
      );
      expect(changed.wakePhrase, 'Jarvis,');
      expect(changed.assistantAddress, 'other@example.org');
      expect(changed.enabled, isFalse);
    });

    test('equal settings are equal and hash the same', () {
      const one = AssistantSettings(enabled: true, wakePhrase: 'Jarvis,');
      const two = AssistantSettings(enabled: true, wakePhrase: 'Jarvis,');
      expect(one, two);
      expect(one.hashCode, two.hashCode);
    });

    test('a difference in any field is a difference', () {
      expect(_defaults, isNot(_defaults.copyWith(enabled: true)));
      expect(_defaults, isNot(_defaults.copyWith(wakePhrase: 'Jarvis,')));
      expect(_defaults, isNot(_defaults.copyWith(assistantAddress: 'a@b.com')));
    });
  });

  group('JSON', () {
    test('a round trip keeps every field', () {
      const settings = AssistantSettings(
        enabled: true,
        wakePhrase: 'Jarvis,',
        assistantAddress: 'other@example.org',
      );
      final back =
          AssistantSettings.fromJson(jsonDecode(jsonEncode(settings.toJson())));
      expect(back, settings);
      expect(back.enabled, isTrue);
      expect(back.wakePhrase, 'Jarvis,');
      expect(back.assistantAddress, 'other@example.org');
    });

    test('the defaults round-trip to the defaults', () {
      expect(
        AssistantSettings.fromJson(
            jsonDecode(jsonEncode(_defaults.toJson()))),
        _defaults,
      );
    });

    test('the file says which version wrote it', () {
      expect(_defaults.toJson()['version'], 1);
    });
  });

  group('fromJson fails closed', () {
    test('junk of any shape gives the defaults', () {
      expect(AssistantSettings.fromJson(null), _defaults);
      expect(AssistantSettings.fromJson('enabled'), _defaults);
      expect(AssistantSettings.fromJson(42), _defaults);
      expect(AssistantSettings.fromJson(<Object?>['enabled', true]), _defaults);
      expect(AssistantSettings.fromJson(<String, Object?>{}), _defaults);
    });

    test('a version this build does not know gives the defaults', () {
      expect(
        AssistantSettings.fromJson(<String, Object?>{
          'version': 2,
          'enabled': true,
          'wakePhrase': 'Jarvis,',
        }),
        _defaults,
      );
      expect(
        AssistantSettings.fromJson(
            <String, Object?>{'version': '1', 'enabled': true}),
        _defaults,
      );
      expect(
        AssistantSettings.fromJson(<String, Object?>{'enabled': true}),
        _defaults,
      );
    });

    test('junk can never switch the feature on', () {
      expect(AssistantSettings.fromJson(null).enabled, isFalse);
      expect(AssistantSettings.fromJson('true').enabled, isFalse);
      expect(AssistantSettings.fromJson(<Object?>[true]).enabled, isFalse);
      expect(
        AssistantSettings.fromJson(
            <String, Object?>{'version': 2, 'enabled': true}).enabled,
        isFalse,
      );
      expect(
        AssistantSettings.fromJson(
            <String, Object?>{'version': 1, 'enabled': 'yes'}).enabled,
        isFalse,
      );
      expect(
        AssistantSettings.fromJson(
            <String, Object?>{'version': 1, 'enabled': 1}).enabled,
        isFalse,
      );
      expect(
        AssistantSettings.fromJson(
            <String, Object?>{'version': 1, 'enabled': null}).enabled,
        isFalse,
      );
    });

    test('only an honest true switches it on', () {
      expect(
        AssistantSettings.fromJson(
            <String, Object?>{'version': 1, 'enabled': true}).enabled,
        isTrue,
      );
    });

    test('a blank wake phrase falls back to the default phrase', () {
      for (final phrase in <Object?>['', '   ', '\n', null, 7, true]) {
        final settings = AssistantSettings.fromJson(<String, Object?>{
          'version': 1,
          'enabled': true,
          'wakePhrase': phrase,
        });
        expect(settings.wakePhrase, WakePhraseDetector.defaultPhrase,
            reason: '$phrase');
        expect(settings.enabled, isTrue, reason: '$phrase');
      }
    });

    test('a missing or blank address falls back to the default address', () {
      for (final address in <Object?>['', null, 7, true]) {
        final settings = AssistantSettings.fromJson(<String, Object?>{
          'version': 1,
          'enabled': true,
          'assistantAddress': address,
        });
        expect(settings.assistantAddress,
            AssistantSettings.defaultAssistantAddress,
            reason: '$address');
      }
      expect(
        AssistantSettings.fromJson(
            <String, Object?>{'version': 1, 'enabled': true}).assistantAddress,
        AssistantSettings.defaultAssistantAddress,
      );
    });
  });

  group('isComplete and the detector', () {
    test('the defaults are already complete', () {
      expect(_defaults.isComplete, isTrue);
    });

    test('a phrase too short to match anything is not complete', () {
      expect(_defaults.copyWith(wakePhrase: 'hi').isComplete, isFalse);
      expect(_defaults.copyWith(wakePhrase: '  ').isComplete, isFalse);
      expect(_defaults.copyWith(wakePhrase: ',,,').isComplete, isFalse);
    });

    test('an address with no @ is not complete', () {
      expect(_defaults.copyWith(assistantAddress: 'nobody').isComplete, isFalse);
      expect(_defaults.copyWith(assistantAddress: '').isComplete, isFalse);
    });

    test('the detector is built from the chosen phrase', () {
      expect(_defaults.detector.phrase, WakePhraseDetector.defaultPhrase);
      expect(_defaults.copyWith(wakePhrase: 'Jarvis,').detector.phrase,
          'Jarvis,');
    });

    test('the detector these settings imply is the one that matches', () {
      final match = _defaults.detector.match('Instinct, remind me at six');
      expect(match, isNotNull);
      expect(match!.instruction, 'remind me at six');
    });
  });

  group('AssistantSettingsStore', () {
    test('no file at all loads the defaults, which are off', () async {
      final files = MemoryFileStore();
      final settings = await _store(files).load();
      expect(settings, _defaults);
      expect(settings.enabled, isFalse);
      expect(files.files, isEmpty);
    });

    test('the path is one file beside the other settings', () {
      expect(_store(MemoryFileStore()).path, _path);
      expect(AssistantSettingsStore.fileName, 'assistant-settings.json');
    });

    test('save then load round-trips', () async {
      final files = MemoryFileStore();
      const settings = AssistantSettings(
        enabled: true,
        wakePhrase: 'Jarvis,',
        assistantAddress: 'other@example.org',
      );
      await _store(files).save(settings);
      expect(await _store(files).load(), settings);
    });

    test('the saved file holds no password and is readable JSON', () async {
      final files = MemoryFileStore();
      await _store(files).save(_defaults.copyWith(enabled: true));
      final text = files.textOf(_path);
      expect(text, isNotNull);
      expect(text, isNot(contains(testAccount.password)));
      expect(text, isNot(contains('password')));
      expect(jsonDecode(text!), isA<Map<String, Object?>>());
    });

    test('garbage bytes load as the defaults and do not throw', () async {
      final files = MemoryFileStore();
      await files.writeBytes(_path, <int>[0, 1, 2, 3, 255, 254]);
      expect(await _store(files).load(), _defaults);
    });

    test('text that is not JSON loads as the defaults', () async {
      final files = MemoryFileStore();
      await files.writeBytes(_path, utf8.encode('enabled = true'));
      final settings = await _store(files).load();
      expect(settings, _defaults);
      expect(settings.enabled, isFalse);
    });

    test('JSON of the wrong shape loads as the defaults', () async {
      final files = MemoryFileStore();
      await files.writeBytes(_path, utf8.encode('[{"enabled": true}]'));
      expect((await _store(files).load()).enabled, isFalse);
    });

    test('a file that will not read loads as the defaults', () async {
      final files = _UnreadableFileStore();
      await files.writeBytes(_path, utf8.encode('{"version":1,'
          '"enabled":true}'));
      final settings = await _store(files).load();
      expect(settings, _defaults);
      expect(settings.enabled, isFalse);
    });

    test('a save onto a full disk is not swallowed', () async {
      final files = MemoryFileStore()..unwritable.add(_path);
      await expectLater(
        _store(files).save(_defaults.copyWith(enabled: true)),
        throwsA(isA<FileSystemExceptionStub>()),
      );
      expect(await _store(files).load(), _defaults);
    });

    test('a later save replaces the earlier one', () async {
      final files = MemoryFileStore();
      final store = _store(files);
      await store.save(_defaults.copyWith(enabled: true));
      await store.save(_defaults);
      expect((await store.load()).enabled, isFalse);
      expect(files.writes[_path], 2);
    });
  });
}
