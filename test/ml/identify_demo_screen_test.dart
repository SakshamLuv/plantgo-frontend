import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plantgo/presentation/screens/identify/identify_demo_screen.dart';

/// Pumps until [finder] matches, or fails after [timeout].
///
/// The screen finishes booting in a plain `Future` (loading the label asset and
/// probing for a model), and `pumpAndSettle` only waits on timers and
/// animations — not arbitrary futures. Polling makes these tests order
/// independent instead of passing alone and failing in a suite.
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('timed out waiting for $finder');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('comes up and reports a missing on-device model rather than crashing',
      (tester) async {
    // No plant_model.tflite is bundled until training has run — this is the
    // state of a fresh checkout, and the screen must still be usable.
    await tester.pumpWidget(const MaterialApp(home: IdentifyDemoScreen()));

    expect(find.text('PlantGo — identify'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Gallery'), findsOneWidget);

    await pumpUntilFound(tester, find.textContaining('no local model'));
    expect(find.textContaining('Point the camera at a plant'), findsOneWidget);
  });

  testWidgets('empty hint names the species count from the loaded catalog',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: IdentifyDemoScreen()));

    // Proves labels.json was really read from assets during boot.
    await pumpUntilFound(tester, find.textContaining('40 species'));
  });

  testWidgets('no cloud chip when no endpoint is configured', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: IdentifyDemoScreen()));
    await pumpUntilFound(tester, find.textContaining('no local model'));

    expect(find.text('cloud'), findsNothing);
  });

  testWidgets('cloud chip appears once an endpoint is configured',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: IdentifyDemoScreen(apiBaseUrl: 'https://plantgo.invalid'),
    ));

    await pumpUntilFound(tester, find.text('cloud'));
    expect(find.text('cloud'), findsOneWidget);
  });

  testWidgets('both capture controls are present and enabled at rest',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: IdentifyDemoScreen()));
    await pumpUntilFound(tester, find.textContaining('no local model'));

    // Matched via the button's own text: `FilledButton.icon` does not build a
    // concrete `FilledButton` element, and `find.byType` is an exact-type match.
    for (final label in ['Camera', 'Gallery']) {
      expect(find.text(label), findsOneWidget, reason: '$label button missing');
    }
    expect(find.byIcon(Icons.photo_camera_outlined), findsOneWidget);
    expect(find.byIcon(Icons.photo_library_outlined), findsOneWidget);

    // No progress bar at rest means the buttons are not disabled by _busy.
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}
