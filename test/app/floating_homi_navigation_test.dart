import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/cases/case_home_screen.dart';
import 'package:safe_at_home/shared/presentation/sah_floating_nav.dart';

import '../services/case_evidence_api_client_test.dart' as http;
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show services;
import '../features/assessment/home_safety/home_safety_support.dart'
    show SafetyStore;

void phoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('SAVE_UI_PREVIEWS')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('preview')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '/tmp/homi-approved-$name.png',
    ).writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    const fontPath = String.fromEnvironment('UI_PREVIEW_FONT');
    if (fontPath.isEmpty) return;
    final font = FontLoader('Roboto')
      ..addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  testWidgets('content scrolls behind dock and last action clears bubble', (
    tester,
  ) async {
    phoneSize(tester);
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light().copyWith(platform: TargetPlatform.iOS),
        home: SahFloatingScaffold(
          selectedIndex: 0,
          onDestinationSelected: (_) {},
          onAssistant: () {},
          body: Builder(
            builder: (context) => ListView(
              padding: sahFloatingContentPadding(context),
              children: [
                for (var i = 0; i < 20; i++)
                  SizedBox(height: 80, child: Text('Room $i')),
                FilledButton(
                  key: const ValueKey('last-action'),
                  onPressed: () => tapped = true,
                  child: const Text('Last action'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final viewport = tester.getRect(find.byType(Scrollable));
    final navigation = tester.getRect(find.byType(SahFloatingNavBar));
    expect(viewport.bottom, greaterThan(navigation.top));
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).extendBody, isTrue);
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    final action = find.byKey(const ValueKey('last-action'));
    expect(
      tester.getRect(action).bottom,
      lessThan(tester.getRect(find.byKey(const ValueKey('ask-homi'))).top),
    );
    await tester.tap(action);
    expect(tapped, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plan controls are labelled and Rename is beside the title', (
    tester,
  ) async {
    phoneSize(tester);
    final app = services(
      SafetyStore(),
      FakeTransport(
        (request) async => request.endpoint.path == '/v2/list-cases'
            ? http.jsonResponse({
                'schemaVersion': '2',
                'cases': [],
                'nextAfterCaseId': null,
              })
            : http.apiError('SERVICE_UNAVAILABLE', 503),
      ),
    );
    addTearDown(app.dispose);
    await app.coordinator.createDraft(name: 'David’s house');
    app.coordinator.snapshot = app.coordinator.draft!.atRevision(1);
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light().copyWith(platform: TargetPlatform.iOS),
        builder: (context, child) =>
            RepaintBoundary(key: const ValueKey('preview'), child: child!),
        home: CaseHomeScreen(services: app),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Switch plan'), findsOneWidget);
    expect(find.text('Suggested next step'), findsNothing);
    final title = tester.getRect(find.byKey(const ValueKey('case-plan-title')));
    final rename = tester.getRect(find.byKey(const ValueKey('plan-rename')));
    expect(rename.left, greaterThan(title.right));
    expect(rename.center.dy, closeTo(title.center.dy, 1));
    await capture(tester, 'plan');
    await tester.tap(find.byKey(const ValueKey('plan-tab-rooms')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('active-plan-selector')).hitTestable(),
      findsOneWidget,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('active-plan-selector'))).top,
      greaterThanOrEqualTo(0),
    );
    expect(find.byType(Scaffold), findsOneWidget);
    await capture(tester, 'rooms');
    await tester.tap(find.byKey(const ValueKey('plan-tab-plan')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('case-profile')));
    await tester.pumpAndSettle();
    await capture(tester, 'resident');
    expect(find.text('Scan or view your bathroom'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
