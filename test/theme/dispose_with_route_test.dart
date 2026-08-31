// test/theme/dispose_with_route_test.dart
//
// Regression cover for the red screen on Commit & push:
//
//   'package:flutter/src/widgets/framework.dart': Failed assertion:
//   line 6281 pos 12: '_dependents.isEmpty': is not true.
//
// The dialog helpers used to create a TextEditingController, await
// showDialog(...), then dispose it in a `finally`. showDialog's future
// completes at Navigator.pop, but the popped route stays mounted and keeps
// updating through the close animation — a *focused* field re-listens to its
// controller mid-animation (_AnimatedState.didUpdateWidget -> addListener),
// hits "A TextEditingController was used after being disposed", and the
// broken build cascades into the _dependents.isEmpty assert.
//
// Focus is what arms it: without tapping the field first, nothing re-listens
// and the old pattern survives. That is why these tests type into the field.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/theme/app_theme.dart';

/// Pumps a host, opens a dialog built by [dialog], focuses and types into its
/// field, taps OK, and settles across the whole close animation.
Future<String?> _runDialogLifecycle(
  WidgetTester tester,
  Widget Function(BuildContext hostContext, TextEditingController controller) dialog,
  TextEditingController controller,
) async {
  late BuildContext hostContext;
  await tester.pumpWidget(MaterialApp(
    home: Builder(builder: (c) {
      hostContext = c;
      return const Scaffold(body: SizedBox.expand());
    }),
  ));

  final future = showDialog<String>(
    context: hostContext,
    builder: (ctx) => dialog(ctx, controller),
  );
  await tester.pumpAndSettle();

  // Focus the field and type: this is the on-device state (keyboard up) that
  // makes the close animation touch the controller again.
  await tester.tap(find.byType(TextField));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'a real commit message');
  await tester.pumpAndSettle();

  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle(); // the full close animation
  return future;
}

Widget _alert(BuildContext ctx, TextEditingController controller) => AlertDialog(
      content: appBorderedField(controller: controller, hint: 'Commit message'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text),
          child: const Text('OK'),
        ),
      ],
    );

void main() {
  testWidgets('a route-owned field survives the close animation', (tester) async {
    final controller = TextEditingController(text: 'Update from pocket_rag_okf');
    final result = await _runDialogLifecycle(
      tester,
      (ctx, c) => DisposeWithRoute(controllers: [c], child: _alert(ctx, c)),
      controller,
    );

    // The whole point: the old `finally { controller.dispose(); }` threw here.
    expect(tester.takeException(), isNull);
    expect(result, 'a real commit message');
  });

  testWidgets('the caller can still read the text after the await', (tester) async {
    // Every converted call site reads controller.text after showDialog
    // returns; the route must not have disposed it by then.
    final controller = TextEditingController(text: 'seed');
    await _runDialogLifecycle(
      tester,
      (ctx, c) => DisposeWithRoute(controllers: [c], child: _alert(ctx, c)),
      controller,
    );
    expect(controller.text, 'a real commit message');
    expect(tester.takeException(), isNull);
  });

  testWidgets('every controller handed to the route is disposed, exactly once', (tester) async {
    // config_screen's cloud-LLM dialog hands over five at a time.
    final controllers = List.generate(5, (i) => TextEditingController(text: '$i'));
    await _runDialogLifecycle(
      tester,
      (ctx, c) => DisposeWithRoute(controllers: controllers, child: _alert(ctx, c)),
      controllers.first,
    );
    // Once the route is gone the controllers are disposed: touching one throws.
    // (A second dispose() would have thrown during pumpAndSettle instead.)
    for (final c in controllers) {
      expect(() => c.addListener(() {}), throwsFlutterError);
    }
    expect(tester.takeException(), isNull);
  });
}
