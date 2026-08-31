// test/theme/app_theme_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/theme/app_theme.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

Finder _arrow(IconData icon) => find.widgetWithIcon(OutlinedButton, icon);

bool _enabled(WidgetTester tester, IconData icon) =>
    tester.widget<OutlinedButton>(_arrow(icon)).onPressed != null;

void main() {
  testWidgets('appStepper reports the next value on each arrow', (tester) async {
    final seen = <int>[];
    await tester.pumpWidget(_host(appStepper(
      label: 'Max reasoning loops',
      value: 3,
      min: 1,
      max: 10,
      onChanged: seen.add,
    )));

    expect(find.text('3'), findsOneWidget);
    await tester.tap(_arrow(Icons.chevron_right));
    await tester.tap(_arrow(Icons.chevron_left));
    expect(seen, [4, 2]);
  });

  testWidgets('appStepper disables the arrow at each bound instead of no-oping', (tester) async {
    await tester.pumpWidget(_host(appStepper(
      label: 'Max reasoning loops',
      value: 1,
      min: 1,
      max: 10,
      onChanged: (_) => fail('a disabled arrow must not fire'),
    )));
    expect(_enabled(tester, Icons.chevron_left), isFalse);
    expect(_enabled(tester, Icons.chevron_right), isTrue);

    await tester.pumpWidget(_host(appStepper(
      label: 'Max reasoning loops',
      value: 10,
      min: 1,
      max: 10,
      onChanged: (_) => fail('a disabled arrow must not fire'),
    )));
    expect(_enabled(tester, Icons.chevron_left), isTrue);
    expect(_enabled(tester, Icons.chevron_right), isFalse);
  });
}
