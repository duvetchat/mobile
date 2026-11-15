import 'package:duvet/main.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

// A file of its own: it starts as audio_service's engine runs main(), with no lifecycle state yet and no screen, which a
// test file's binding has only before any test sets a state.
void main() {
  // The activity a notification's tap or button launches comes to that engine after main() ran: what the notification
  // asks for (a message, a call's Answer) is read once the app shows, once.
  testWidgets('a notification that started the app with no screen is read once the app shows, once', (tester) async {
    expect(tester.binding.lifecycleState, isNull);
    tester.view.physicalSize = Size.zero;
    addTearDown(tester.view.reset);
    var reads = 0;
    await tester.pumpWidget(DuvetApp(repository: FakeRepository(), readLaunch: () => reads++));
    expect(reads, 0);
    tester.view.reset();
    for (final state in [AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    expect(reads, 1);
    for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    expect(reads, 1);
  });
}
