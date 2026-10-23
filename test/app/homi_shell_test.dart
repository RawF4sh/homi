import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/cases/case_home_screen.dart';
import 'package:safe_at_home/features/cases/case_workspace_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/shared/navigation/homi_destination.dart';
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;
import '../services/case_evidence_api_client_test.dart' as http;

void main() {
  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets(
      'five destinations and app guidance without implicit creation: $locale',
      (tester) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 3.2;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        final transport = FakeTransport((request) async {
          if (request.endpoint.path == '/v2/list-cases') {
            return http.jsonResponse({
              'schemaVersion': '2',
              'cases': [],
              'nextAfterCaseId': null,
            });
          }
          throw StateError('Tab selection must not mutate or create a case');
        });
        final app = services(MemoryPrivateStore(), transport);
        addTearDown(app.dispose);
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            theme: SafeAtHomeTheme.light(),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: CaseHomeScreen(services: app),
          ),
        );
        await tester.pumpAndSettle();
        final generation = app.coordinator.generation;
        for (final tab in HomiDestination.values) {
          await tester.tap(find.byKey(ValueKey('plan-tab-${tab.name}')));
          await tester.pumpAndSettle();
          expect(app.coordinator.draft, isNull);
          expect(app.coordinator.generation, generation);
          expect(find.byKey(const ValueKey('ask-homi')), findsOneWidget);
          for (final destination in HomiDestination.values) {
            expect(
              find.byKey(ValueKey('plan-tab-${destination.name}')),
              findsOneWidget,
            );
          }
          expect(tester.takeException(), isNull, reason: '$locale $tab');
        }
        expect(
          transport.requests.map((r) => r.endpoint.path),
          everyElement('/v2/list-cases'),
        );
      },
    );
  }
  testWidgets(
    'reminder opens Tasks in the existing shell after leave guards allow it',
    (tester) async {
      final app = services(
        MemoryPrivateStore(),
        FakeTransport(
          (_) async => http.jsonResponse({
            'schemaVersion': '2',
            'cases': [],
            'nextAfterCaseId': null,
          }),
        ),
      );
      addTearDown(app.dispose);
      await tester.pumpWidget(MaterialApp(home: CaseHomeScreen(services: app)));
      await tester.pumpAndSettle();
      app.coordinator.busy = true;
      app.reminderOpen.value = true;
      await tester.pumpAndSettle();
      expect(app.reminderOpen.value, isTrue);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0,
      );
      app.coordinator.busy = false;
      await tester.tap(find.text('Open tasks'));
      await tester.pumpAndSettle();
      expect(app.reminderOpen.value, isFalse);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        3,
      );
      expect(find.byType(CaseHomeScreen), findsOneWidget);
      expect(find.byType(Scaffold), findsOneWidget);
      expect(app.coordinator.draft, isNull);
    },
  );
  testWidgets('management retains selected workspace and returns to it', (
    tester,
  ) async {
    final app = services(
      MemoryPrivateStore(),
      FakeTransport(
        (_) async => http.jsonResponse({
          'schemaVersion': '2',
          'cases': [],
          'nextAfterCaseId': null,
        }),
      ),
    );
    addTearDown(app.dispose);
    await app.coordinator.createDraft();
    await tester.pumpWidget(MaterialApp(home: CaseHomeScreen(services: app)));
    await tester.pumpAndSettle();
    final workspace = tester.state<CaseWorkspaceScreenState>(
      find.byType(CaseWorkspaceScreen),
    );
    await tester.tap(find.byKey(const ValueKey('active-plan-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manage plans').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan-search')), findsOneWidget);
    expect(
      tester.state<CaseWorkspaceScreenState>(
        find.byType(CaseWorkspaceScreen, skipOffstage: false),
      ),
      same(workspace),
    );
    await tester.tap(find.text('Return to plan').first);
    await tester.pumpAndSettle();
    expect(
      tester.state<CaseWorkspaceScreenState>(find.byType(CaseWorkspaceScreen)),
      same(workspace),
    );
    expect(find.byType(Scaffold), findsOneWidget);
  });
}
