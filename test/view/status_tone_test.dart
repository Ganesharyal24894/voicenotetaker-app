import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/home_status.dart';
import 'package:voicenotetaker_app/view/theme.dart';
import 'package:voicenotetaker_app/view/widgets/status_tone.dart';

/// Every tone has one dot colour and one label colour, and privacy mode is
/// purple - never the amber a fault wears.
void main() {
  test('the dot colours are the theme\'s status colours', () {
    expect(StatusToneColors.dot(HomeStatusTone.good), AppColors.connected);
    expect(StatusToneColors.dot(HomeStatusTone.warning), AppColors.warning);
    expect(StatusToneColors.dot(HomeStatusTone.idle), AppColors.disconnected);
    expect(StatusToneColors.dot(HomeStatusTone.privacy), AppColors.purple400);
  });

  test('only a warning and privacy mode colour the words', () {
    expect(StatusToneColors.label(HomeStatusTone.good), AppColors.textSecondary);
    expect(StatusToneColors.label(HomeStatusTone.idle), AppColors.textSecondary);
    expect(StatusToneColors.label(HomeStatusTone.warning), AppColors.warning);
    expect(StatusToneColors.label(HomeStatusTone.privacy), AppColors.purple300);
  });

  test('privacy mode never wears the warning colours', () {
    expect(StatusToneColors.dot(HomeStatusTone.privacy),
        isNot(StatusToneColors.dot(HomeStatusTone.warning)));
    expect(StatusToneColors.label(HomeStatusTone.privacy),
        isNot(StatusToneColors.label(HomeStatusTone.warning)));
  });
}
