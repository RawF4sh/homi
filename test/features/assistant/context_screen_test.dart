import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assistant/assistant_context_v2.dart';
import 'package:safe_at_home/features/assistant/assistant_model.dart';
import 'package:safe_at_home/features/assistant/plan_assistant_screen.dart';
import 'package:safe_at_home/shared/navigation/homi_destination.dart';
import 'assistant_test.dart' show app, FakeModel;

AssistantContextV2 _context({
  String scope = 'account-one',
  bool authorized = true,
}) => AssistantContextV2.fromAuthorizedRecords(
  scopeKey: scope,
  authorized: authorized,
  access: const AssistantRecordAccess.owner(),
  destination: HomiDestination.plan,
  capabilities: {
    for (final d in HomiDestination.values) d: FeatureAvailability.supported,
  },
);

void main() {
  testWidgets(
    'deterministic sources remain usable without a model and revalidate at tap',
    (tester) async {
      var current = _context();
      final opened = <HomiTarget>[];
      await tester.pumpWidget(
        app(
          PlanAssistantScreen(
            onSection: (_) {},
            onTarget: opened.add,
            appContextProvider: () => current,
            model: FakeModel()
              ..status = AssistantAvailability.unsupportedDevice,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final open = find.widgetWithText(OutlinedButton, 'Open Plan');
      expect(open, findsOneWidget);
      // A permission change after paint must make the already-visible button inert.
      current = _context(authorized: false);
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      current = _context();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        app(
          PlanAssistantScreen(
            onSection: (_) {},
            onTarget: opened.add,
            appContextProvider: () => current,
            model: FakeModel()
              ..status = AssistantAvailability.unsupportedDevice,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(opened.single.destination, HomiDestination.plan);
      expect(opened.single.caseId, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'grounded guidance fits large text and translated narrow layouts',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final locale in [
        const Locale('es'),
        const Locale('vi'),
        const Locale('fil'),
      ]) {
        await tester.pumpWidget(
          app(
            MediaQuery(
              data: const MediaQueryData(
                size: Size(360, 640),
                textScaler: TextScaler.linear(2.5),
              ),
              child: PlanAssistantScreen(
                onSection: (_) {},
                onTarget: (_) {},
                appContextProvider: _context,
                model: FakeModel()
                  ..status = AssistantAvailability.unsupportedDevice,
              ),
            ),
            locale: locale,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
