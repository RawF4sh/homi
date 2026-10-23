import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens plan management through the persistent shell's selected-plan menu.
/// Bounded frames also support discovery tests with deliberately pending I/O.
Future<void> openManagePlans(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('active-plan-selector')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  final manage = find.byWidgetPredicate(
    (widget) => widget is PopupMenuItem<String> && widget.value == 'manage',
  );
  await tester.ensureVisible(manage);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(manage);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}
