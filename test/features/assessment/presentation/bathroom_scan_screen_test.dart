import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_adapter.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_session.dart';
import 'package:safe_at_home/features/assessment/domain/scan/bathroom_scan_scene.dart';
import 'package:safe_at_home/features/assessment/domain/scan/scan_suggestions.dart';
import 'package:safe_at_home/features/assessment/presentation/bathroom_model_view.dart';
import 'package:safe_at_home/features/assessment/presentation/bathroom_scan_screen.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';

import '../../../app/local_private_store_test.dart' show MemorySecrets;
import '../domain/scan/scan_test_fixtures.dart';

class _WidgetStore extends LocalPrivateStore {
  _WidgetStore({
    required super.directory,
    required super.accountId,
    required super.secrets,
  });
  bool failNextWrite = false;
  final failureObserved = Completer<void>();
  @override
  Future<void> writeBytes(String key, Uint8List bytes) {
    if (failNextWrite) {
      failNextWrite = false;
      if (!failureObserved.isCompleted) failureObserved.complete();
      return Future.error(const FileSystemException('Fictional full disk'));
    }
    return super.writeBytes(key, bytes);
  }
}

class _WidgetScanner implements BathroomScanAdapter {
  BathroomScanCapabilities capability = const BathroomScanCapabilities(
    supported: true,
    source: 'roomplan',
    reason: 'available',
    depthSupported: true,
  );
  final starts = <String>[], cancellations = <String>[];
  Future<BathroomScanScene> Function(String)? capture;
  @override
  Future<BathroomScanCapabilities> capabilities() async => capability;
  @override
  Future<BathroomScanScene> start(String id) async {
    starts.add(id);
    return capture == null
        ? BathroomScanScene.fromJson(
            scanSceneJson(
              source: capability.source,
              elements: capability.source == 'arcore'
                  ? [
                      scanElementJson(
                        kind: 'unknown',
                        nativeCategory: 'horizontal_upward',
                        dimensions: [2, 0, 3],
                        confidence: 'unknown',
                      ),
                    ]
                  : null,
            )..['scanId'] = id,
          )
        : await capture!(id);
  }

  @override
  Future<void> cancel(String id) async {
    cancellations.add(id);
  }
}

class _Harness {
  _Harness(this.directory) {
    store = _WidgetStore(
      directory: directory,
      accountId: 'fictional-widget-owner',
      secrets: MemorySecrets(),
    );
    session = BathroomScanSession(
      store: store,
      caseId: caseId,
      isCurrent: () => current.value,
      adapter: scanner,
    );
  }
  static const caseId = 'f4b1b823-f3e5-4a77-825c-9b1696f21fe6';
  final Directory directory;
  final current = ValueNotifier(true);
  final scanner = _WidgetScanner();
  final imports = <ScanSuggestion>[];

  final removed = <String>{};
  late final _WidgetStore store;
  late final BathroomScanSession session;

  Future<void> seed(BathroomScanReview review) => store.writeBytes(
    session.key,
    Uint8List.fromList(utf8.encode(jsonEncode(review.toJson(caseId)))),
  );

  Widget app({double textScale = 1}) => MaterialApp(
    theme: SafeAtHomeTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => BathroomScanScreen(
                  session: session,
                  scope: current,
                  onImport: (suggestion) async {
                    imports.add(suggestion);
                    return 'fictional-finding';
                  },
                  importedFinding: (id) => imports.any((s) => s.id == id)
                      ? 'fictional-finding'
                      : null,
                  activeImports: () => {
                    for (final s in imports)
                      if (!removed.contains(s.id)) s.id,
                  },
                ),
              ),
            ),
            child: const Text('Open scan review'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 400 && !condition(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(
    condition(),
    isTrue,
    reason: 'Bounded private scan operation completed',
  );
}

Future<void> _idle(WidgetTester tester, _Harness harness) async {
  await _until(
    tester,
    () => harness.session.initialized && !harness.session.busy,
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Future<void> _open(
  WidgetTester tester,
  _Harness harness, {
  double textScale = 1,
  bool initialize = true,
}) async {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    var closed = false;
    Object? failure;
    harness.store.close().then(
      (_) => closed = true,
      onError: (Object error) {
        failure = error;
        closed = true;
      },
    );
    await _until(tester, () => closed);
    expect(failure, isNull);
    harness.current.dispose();
    await tester.runAsync(() async {
      if (await harness.directory.exists()) {
        await harness.directory.delete(recursive: true);
      }
    });
  });
  await tester.pumpWidget(harness.app(textScale: textScale));
  await tester.tap(find.text('Open scan review'));
  await tester.pump();
  if (initialize) await _idle(tester, harness);
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  final scrollable = find.byType(Scrollable).first;
  final state = tester.state<ScrollableState>(scrollable);
  for (
    var attempt = 0;
    attempt < 5 && state.position.pixels != state.position.minScrollExtent;
    attempt++
  ) {
    state.position.jumpTo(state.position.minScrollExtent);
    await tester.pump();
  }
  for (var attempt = 0; attempt < 120 && finder.evaluate().isEmpty; attempt++) {
    final bounds = tester.getRect(scrollable);
    await tester.dragFrom(
      Offset(bounds.left + 8, bounds.center.dy),
      const Offset(0, -300),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsOneWidget);
  await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
  await tester.pump();
}

Future<void> _check(WidgetTester tester, _Harness harness, String label) async {
  final tile = find.widgetWithText(CheckboxListTile, label);
  await _reveal(tester, tile);
  final checkbox = find.descendant(of: tile, matching: find.byType(Checkbox));
  await Scrollable.ensureVisible(tester.element(checkbox), alignment: .5);
  await tester.pump();
  await tester.tap(checkbox);
  await _idle(tester, harness);
}

Future<void> _tapDialogAction(WidgetTester tester, String label) async {
  final target = find.descendant(
    of: find.byType(Dialog),
    matching: find.text(label),
  );
  expect(target, findsOneWidget);
  await Scrollable.ensureVisible(tester.element(target), alignment: .5);
  await tester.pump();
  await tester.tap(target);
}

void main() {
  late _Harness harness;
  setUp(
    () async => harness = _Harness(
      await Directory.systemTemp.createTemp('sah-scan-widget-'),
    ),
  );
  for (final readiness in {
    'permission_denied': 'Camera access is needed for 3D scanning.',
    'services_missing': 'This phone supports ARCore.',
    'services_update_required': 'Google Play Services for AR needs an update.',
  }.entries) {
    testWidgets(
      'Android ${readiness.key} offers deliberate setup and a manual fallback',
      (tester) async {
        harness.scanner.capability = BathroomScanCapabilities(
          supported: true,
          source: 'arcore',
          reason: readiness.key,
        );
        await _open(tester, harness);
        await _reveal(tester, find.textContaining(readiness.value));
        expect(harness.scanner.starts, isEmpty);
        final start = find.byKey(const ValueKey('bathroom-start-scan'));
        await _reveal(tester, start);
        expect(tester.widget<FilledButton>(start).onPressed, isNotNull);
        expect(find.text('Set up 3D scanning'), findsOneWidget);
        final fallback = find.byKey(const ValueKey('bathroom-use-manual'));
        await _reveal(tester, fallback);
        expect(tester.widget<OutlinedButton>(fallback).onPressed, isNotNull);
        await _reveal(tester, start);
        await tester.tap(start);
        await _idle(tester, harness);
        expect(harness.scanner.starts, hasLength(1));
        expect(harness.session.review.scene!.source, ScanSource.arcore);
      },
    );
  }

  testWidgets(
    'supported LiDAR device explains readiness without starting capture',
    (tester) async {
      await _open(tester, harness);
      await _reveal(
        tester,
        find.textContaining('LiDAR scanning is ready on this iPhone.'),
      );
      expect(harness.scanner.starts, isEmpty);
      final fallback = find.byKey(const ValueKey('bathroom-use-manual'));
      await _reveal(tester, fallback);
      await tester.tap(fallback);
      await tester.pumpAndSettle();
      expect(find.text('Open scan review'), findsOneWidget);
      expect(harness.scanner.starts, isEmpty);
    },
  );

  testWidgets(
    'iPhone blocked camera points to Settings without promising another prompt',
    (tester) async {
      harness.scanner.capability = const BathroomScanCapabilities(
        supported: true,
        source: 'roomplan',
        reason: 'permission_denied',
      );
      await _open(tester, harness);
      await _reveal(tester, find.textContaining('Camera access is blocked.'));
      expect(find.textContaining('iPhone Settings'), findsOneWidget);
      expect(find.text('Set up 3D scanning'), findsNothing);
      expect(harness.scanner.starts, isEmpty);
      final fallback = find.byKey(const ValueKey('bathroom-use-manual'));
      await _reveal(tester, fallback);
      await tester.tap(fallback);
      await tester.pumpAndSettle();
      expect(find.text('Open scan review'), findsOneWidget);
      expect(harness.scanner.starts, isEmpty);
    },
  );

  testWidgets(
    'unsupported phone can review its saved model and leave without erasing it',
    (tester) async {
      final original = BathroomScanReview(
        scene: fictionalScanScene(),
        reviewed: {'door-1'},
      );
      await tester.runAsync(() => harness.seed(original));
      harness.scanner.capability = const BathroomScanCapabilities(
        supported: false,
        source: 'arcore',
        reason: 'unsupported_device',
      );
      await _open(tester, harness);
      await _reveal(
        tester,
        find.textContaining('Your saved model is still available to review.'),
      );
      await _reveal(tester, find.byType(BathroomModelView));
      final fallback = find.byKey(const ValueKey('bathroom-use-manual'));
      await _reveal(tester, fallback);
      await tester.tap(fallback);
      await tester.pumpAndSettle();
      expect(find.text('Open scan review'), findsOneWidget);
      final bytes = await tester.runAsync(
        () => harness.store.readBytes(harness.session.key),
      );
      expect(jsonDecode(utf8.decode(bytes!)), original.toJson(_Harness.caseId));
      expect(harness.scanner.starts, isEmpty);
    },
  );

  testWidgets(
    'manual fallback requires explicit discard after an unsaved review change',
    (tester) async {
      final original = BathroomScanReview(scene: fictionalScanScene());
      await tester.runAsync(() => harness.seed(original));
      await _open(tester, harness);
      harness.store.failNextWrite = true;
      await _check(tester, harness, 'I checked this against the room');
      expect(harness.session.dirty, isTrue);
      expect(harness.session.review.reviewed, {'door-1'});

      final fallback = find.byKey(const ValueKey('bathroom-use-manual'));
      await _reveal(tester, fallback);
      await tester.tap(fallback);
      await tester.pumpAndSettle();
      expect(find.text('Device changes are not saved'), findsOneWidget);
      await _tapDialogAction(tester, 'Cancel');
      await tester.pumpAndSettle();
      expect(harness.session.dirty, isTrue);
      expect(harness.session.review.reviewed, {'door-1'});
      expect(find.text('Open scan review'), findsNothing);

      await _reveal(tester, fallback);
      await tester.tap(fallback);
      await tester.pumpAndSettle();
      await _tapDialogAction(tester, 'Discard unsaved changes');
      await _until(
        tester,
        () => find.text('Open scan review').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      final bytes = await tester.runAsync(
        () => harness.store.readBytes(harness.session.key),
      );
      expect(jsonDecode(utf8.decode(bytes!)), original.toJson(_Harness.caseId));
      expect(harness.scanner.starts, isEmpty);
    },
  );

  testWidgets(
    'a saved model can recheck pending ARCore availability without losing review',
    (tester) async {
      final scene = BathroomScanScene.fromJson(scanSceneJson());
      await tester.runAsync(
        () => harness.seed(
          BathroomScanReview(scene: scene, reviewed: {scene.elements.first.id}),
        ),
      );
      harness.scanner.capability = const BathroomScanCapabilities(
        supported: false,
        source: 'arcore',
        reason: 'checking',
      );
      await _open(tester, harness);
      final start = find.byKey(const ValueKey('bathroom-start-scan'));
      await _reveal(tester, start);
      expect(tester.widget<FilledButton>(start).onPressed, isNull);

      harness.scanner.capability = const BathroomScanCapabilities(
        supported: true,
        source: 'arcore',
        reason: 'available',
      );
      final recheck = find.text('Check device');
      await _reveal(tester, recheck);
      await tester.tap(recheck);
      await _idle(tester, harness);
      await _reveal(tester, start);
      expect(tester.widget<FilledButton>(start).onPressed, isNotNull);
      expect(harness.session.review.scene!.fingerprint, scene.fingerprint);
      expect(harness.session.review.reviewed, {scene.elements.first.id});
      expect(harness.scanner.starts, isEmpty);
      expect(harness.imports, isEmpty);
    },
  );
  testWidgets(
    'capture, resident review and explicit confirmation precede importing an observation',
    (tester) async {
      await _open(tester, harness);
      final start = find.byKey(const ValueKey('bathroom-start-scan'));
      await _reveal(tester, start);
      await tester.tap(start);
      await _idle(tester, harness);
      expect(harness.session.review.scene, isNotNull);
      expect(harness.imports, isEmpty);
      await _check(tester, harness, 'I checked this against the room');
      expect(harness.imports, isEmpty);
      await _check(tester, harness, ScanDifficulty.enteringBathroom.label);
      expect(harness.imports, isEmpty);
      final add = find.text('Review and add observation');
      await _reveal(tester, add);
      await tester.tap(add);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Confirm this observation?'), findsOneWidget);
      expect(harness.imports, isEmpty);
      await _tapDialogAction(tester, 'Cancel');
      await tester.pumpAndSettle();
      expect(harness.imports, isEmpty);
      await _reveal(tester, add);
      await tester.tap(add);
      await tester.pump(const Duration(milliseconds: 300));
      await _tapDialogAction(tester, 'Confirm and add');
      await _idle(tester, harness);
      expect(harness.imports, hasLength(1));
      expect(
        harness.imports.single.sceneFingerprint,
        harness.session.review.scene!.fingerprint,
      );
      expect(
        harness.imports.single.observation,
        contains('not a verified measurement'),
      );
      expect(
        find.text(
          'Previously added. Review its current status in the assessment.',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'unsupported simulator keeps manual assessment available and never starts native capture',
    (tester) async {
      harness.scanner.capability = const BathroomScanCapabilities(
        supported: false,
        source: 'roomplan',
        reason: 'simulator',
        depthSupported: false,
      );
      await _open(tester, harness);
      final start = find.byKey(const ValueKey('bathroom-start-scan'));
      await _reveal(tester, start);
      expect(tester.widget<FilledButton>(start).onPressed, isNull);
      await _reveal(
        tester,
        find.textContaining('The simulator cannot capture LiDAR.'),
      );
      expect(
        find.textContaining('The simulator cannot capture LiDAR.'),
        findsOneWidget,
      );
      expect(harness.scanner.starts, isEmpty);
      final fallback = find.byKey(const ValueKey('bathroom-use-manual'));
      await _reveal(tester, fallback);
      await tester.tap(fallback);
      await tester.pumpAndSettle();
      expect(find.text('Open scan review'), findsOneWidget);
      expect(harness.scanner.starts, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'scope change hides an existing model and cancels the exact pending replacement',
    (tester) async {
      await tester.runAsync(
        () => harness.seed(
          BathroomScanReview(scene: fictionalScanScene(), reviewed: {'door-1'}),
        ),
      );
      final entered = Completer<String>();
      final reply = Completer<BathroomScanScene>();
      harness.scanner.capture = (id) {
        entered.complete(id);
        return reply.future;
      };
      await _open(tester, harness);
      await _reveal(tester, find.byType(BathroomModelView));
      expect(find.byType(BathroomModelView), findsOneWidget);
      final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
      list.position.jumpTo(0);
      await tester.pump();
      await _reveal(tester, find.byKey(const ValueKey('bathroom-start-scan')));
      await tester.tap(find.byKey(const ValueKey('bathroom-start-scan')));
      await tester.pump(const Duration(milliseconds: 300));
      await _tapDialogAction(tester, 'Start new scan');
      await tester.pump();
      await _until(tester, () => entered.isCompleted);
      final id = harness.scanner.starts.single;
      harness.current.value = false;
      await tester.pump();
      expect(
        find.text(
          'This case or account has changed. Return to the assessment.',
        ),
        findsOneWidget,
      );
      expect(find.byType(BathroomModelView), findsNothing);
      expect(find.text('PARTIAL 3D MODEL'), findsNothing);
      expect(harness.scanner.cancellations, [id]);
      reply.complete(
        BathroomScanScene.fromJson(scanSceneJson()..['scanId'] = id),
      );
      await _until(tester, () => !harness.session.busy);
      await tester.pumpAndSettle();
      expect(harness.imports, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'scope expiry hides a pending observation confirmation on its first frame',
    (tester) async {
      final scene = fictionalScanScene();
      await tester.runAsync(
        () => harness.seed(
          BathroomScanReview(
            scene: scene,
            reviewed: {'door-1'},
            difficulties: {ScanDifficulty.enteringBathroom},
          ),
        ),
      );
      final observation = suggestBathroomImprovements(
        scene: scene,
        reviewedElementIds: {'door-1'},
        difficulties: {ScanDifficulty.enteringBathroom},
      ).single.observation;
      await _open(tester, harness);
      final add = find.text('Review and add observation');
      await _reveal(tester, add);
      await tester.tap(add);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Confirm this observation?'), findsOneWidget);
      expect(find.textContaining(observation), findsOneWidget);
      expect(harness.imports, isEmpty);
      harness.current.value = false;
      await tester.pump();
      expect(find.textContaining(observation), findsNothing);
      expect(find.text('Confirm this observation?'), findsNothing);
      expect(find.text('Confirm and add'), findsNothing);
      expect(find.byType(BathroomModelView), findsNothing);
      expect(harness.imports, isEmpty);
      await tester.pumpAndSettle();
      expect(harness.imports, isEmpty);
      expect(
        find.text(
          'This case or account has changed. Return to the assessment.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'changing a feature label withdraws its review and prior suggestions',
    (tester) async {
      await tester.runAsync(
        () => harness.seed(
          BathroomScanReview(
            scene: fictionalScanScene(),
            reviewed: {'door-1'},
            difficulties: {ScanDifficulty.enteringBathroom},
          ),
        ),
      );
      await _open(tester, harness);
      final dropdown = find.byKey(const ValueKey('door-1-door'));
      await _reveal(tester, dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Sink').last);
      await tester.tap(find.text('Sink').last);
      await _idle(tester, harness);
      expect(harness.session.review.labels['door-1'], ScanElementKind.sink);
      expect(harness.session.review.reviewed, isEmpty);
      expect(harness.imports, isEmpty);
      await _reveal(
        tester,
        find.textContaining(
          'Check a feature and tick a difficulty to see prompts.',
        ),
      );
      expect(find.text('Review and add observation'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  BathroomScanReview doorReview() => BathroomScanReview(
    scene: fictionalScanScene(),
    reviewed: {'door-1'},
    difficulties: {ScanDifficulty.enteringBathroom},
  );
  ScanSuggestion doorSuggestion() => suggestBathroomImprovements(
    scene: fictionalScanScene(),
    reviewedElementIds: {'door-1'},
    difficulties: {ScanDifficulty.enteringBathroom},
  ).single;
  final earlierNotice = find.textContaining(
    'Observations added from an earlier model review: 1.',
  );

  testWidgets(
    'correcting a label flags an earlier imported observation without editing it',
    (tester) async {
      await tester.runAsync(() => harness.seed(doorReview()));
      harness.imports.add(doorSuggestion());
      await _open(tester, harness);
      await _reveal(
        tester,
        find.text(
          'Previously added. Review its current status in the assessment.',
        ),
      );
      expect(earlierNotice, findsNothing);
      final dropdown = find.byKey(const ValueKey('door-1-door'));
      await _reveal(tester, dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Sink').last);
      await tester.tap(find.text('Sink').last);
      await _idle(tester, harness);
      await _reveal(tester, earlierNotice);
      expect(harness.imports, hasLength(1));
      expect(harness.imports.single.id, doorSuggestion().id);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'an import dismissed or removed in the assessment is not offered again',
    (tester) async {
      await tester.runAsync(() => harness.seed(doorReview()));
      harness.imports.add(doorSuggestion());
      harness.removed.add(doorSuggestion().id);
      await _open(tester, harness);
      await _reveal(
        tester,
        find.textContaining('Previously added, then dismissed or removed'),
      );
      expect(find.text('Review and add observation'), findsNothing);
      expect(earlierNotice, findsNothing);
      expect(harness.imports, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'removing the device model keeps earlier observations visible as stale',
    (tester) async {
      await tester.runAsync(() => harness.seed(doorReview()));
      harness.imports.add(doorSuggestion());
      await _open(tester, harness);
      final remove = find.text('Remove device model');
      await _reveal(tester, remove);
      await tester.tap(remove);
      await tester.pump(const Duration(milliseconds: 300));
      await _tapDialogAction(tester, 'Remove model');
      await _idle(tester, harness);
      expect(harness.session.review.scene, isNull);
      await _reveal(tester, earlierNotice);
      final bytes = await tester.runAsync(
        () => harness.store.readBytes(harness.session.key),
      );
      expect((jsonDecode(utf8.decode(bytes!)) as Map)['scene'], isNull);
      expect(harness.imports, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'model announces its selected feature and controls meet a11y guidelines',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.runAsync(() => harness.seed(doorReview()));
      await _open(tester, harness);
      await _reveal(tester, find.byType(BathroomModelView));
      final model = find.bySemanticsLabel(RegExp('^Partial bathroom model'));
      expect(model, findsOneWidget);
      final scene = fictionalScanScene();
      expect(
        tester.getSemantics(model).value,
        'Selected: 1. ${scene.elements.first.kind.label}',
      );
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await _reveal(tester, find.text('Review and add observation'));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    },
  );

  testWidgets(
    '320px viewport at 3.2x text keeps model controls and review content usable',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 812);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.runAsync(
        () => harness.seed(BathroomScanReview(scene: fictionalScanScene())),
      );
      await _open(tester, harness, textScale: 3.2);
      final fallback = find.byKey(const ValueKey('bathroom-use-manual'));
      await _reveal(tester, fallback);
      expect(tester.widget<OutlinedButton>(fallback).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await _reveal(tester, find.byTooltip('Rotate model right'));
      await tester.tap(find.byTooltip('Rotate model right'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await _check(tester, harness, 'I checked this against the room');
      await _check(tester, harness, ScanDifficulty.enteringBathroom.label);
      await _reveal(tester, find.text('Review and add observation'));
      await tester.tap(find.text('Review and add observation'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Confirm this observation?'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await Scrollable.ensureVisible(
        tester.element(find.text('Cancel')),
        alignment: .5,
      );
      await tester.pump();
      expect(
        const Rect.fromLTWH(
          0,
          0,
          320,
          812,
        ).contains(tester.getCenter(find.text('Cancel'))),
        true,
        reason:
            'The actual dialog cancellation action remains reachable at large text',
      );
      expect(tester.takeException(), isNull);
      await _tapDialogAction(tester, 'Cancel');
      await tester.pumpAndSettle();
      expect(harness.imports, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed interrupted-capture cleanup does not trap Back or erase the durable model',
    (tester) async {
      final original = BathroomScanReview(
        scene: fictionalScanScene(),
        pendingScanId: '6c01f530-a6b1-4221-9034-c2a3731dde4d',
      );
      await tester.runAsync(() => harness.seed(original));
      harness.store.failNextWrite = true;
      await _open(tester, harness, initialize: false);
      await _until(tester, () => harness.store.failureObserved.isCompleted);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('The private model could not be opened.'),
        findsOneWidget,
      );
      expect(harness.session.initialized, false);
      await tester.tap(find.text('Back to assessment'));
      await tester.pumpAndSettle();
      expect(find.text('Open scan review'), findsOneWidget);
      final bytes = await tester.runAsync(
        () => harness.store.readBytes(harness.session.key),
      );
      expect(jsonDecode(utf8.decode(bytes!)), original.toJson(_Harness.caseId));
      expect(harness.scanner.starts, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
