import 'package:flutter_test/flutter_test.dart';
import 'package:voicenotetaker_app/model/background_task_plan.dart';

/// When the app asks iOS for a block of background CPU time.
void main() {
  test('nothing queued: nothing to ask for', () {
    expect(BackgroundTaskPlan.plan(pending: 0, modelReady: true), isNull);
    expect(BackgroundTaskPlan.plan(pending: -1, modelReady: true), isNull);
  });

  test('no speech model installed: nothing to ask for', () {
    expect(BackgroundTaskPlan.plan(pending: 5, modelReady: false), isNull);
  });

  test('work waiting and a model to do it with: ask', () {
    final request = BackgroundTaskPlan.plan(pending: 1, modelReady: true);
    expect(request, isNotNull);
    expect(request!.requiresExternalPower, isTrue);
    expect(request.requiresNetworkConnectivity, isFalse);
    expect(request.earliestDelay, BackgroundTaskPlan.earliestDelay);
  });

  test('the same request whatever the size of the backlog', () {
    expect(
      BackgroundTaskPlan.plan(pending: 1, modelReady: true),
      BackgroundTaskPlan.plan(pending: 40, modelReady: true),
    );
  });

  test('the identifier matches Info.plist and AppDelegate.swift', () {
    expect(
      BackgroundTaskPlan.transcribeTaskId,
      'com.ganeshsharma.voicenotetaker_app.transcribe',
    );
  });

  test('the delay is the documented one', () {
    expect(BackgroundTaskPlan.earliestDelay, const Duration(minutes: 15));
  });

  test('two requests with the same terms are equal', () {
    const a = BackgroundTaskRequest(
      requiresExternalPower: true,
      requiresNetworkConnectivity: false,
      earliestDelay: Duration(minutes: 15),
    );
    const b = BackgroundTaskRequest(
      requiresExternalPower: true,
      requiresNetworkConnectivity: false,
      earliestDelay: Duration(minutes: 15),
    );
    const different = BackgroundTaskRequest(
      requiresExternalPower: false,
      requiresNetworkConnectivity: false,
      earliestDelay: Duration(minutes: 15),
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(different));
    expect(a.toString(), contains('after'));
  });
}
