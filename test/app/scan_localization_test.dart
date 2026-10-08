import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_adapter.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_session.dart';
import 'package:safe_at_home/features/assessment/domain/scan/bathroom_scan_scene.dart';
import 'package:safe_at_home/features/assessment/domain/scan/scan_suggestions.dart';
import 'package:safe_at_home/features/assessment/presentation/bathroom_model_view.dart';
import 'package:safe_at_home/features/assessment/presentation/bathroom_scan_screen.dart';

import '../features/assessment/domain/scan/scan_test_fixtures.dart';
import 'app_design_test.dart' show narrowLargeText, reveal;
import 'core_localization_test.dart' show localized;
import 'live_workflows_test.dart' show MemoryPrivateStore;

class _ScanStore extends MemoryPrivateStore {
  final bytes = <String, Uint8List>{};
  @override
  Future<Uint8List?> readBytes(String key) async =>
      bytes[key] == null ? null : Uint8List.fromList(bytes[key]!);
  @override
  Future<void> writeBytes(String key, Uint8List value) async {
    bytes[key] = Uint8List.fromList(value);
  }
}

class _Scanner implements BathroomScanAdapter {
  @override
  Future<BathroomScanCapabilities> capabilities() async =>
      const BathroomScanCapabilities(
        supported: true,
        source: 'roomplan',
        reason: 'available',
        depthSupported: true,
      );
  @override
  Future<BathroomScanScene> start(String scanId) =>
      throw StateError('Translation review must not open native capture');
  @override
  Future<void> cancel(String scanId) async {}
}

void main() {
  for (final locale in [
    const Locale('es'),
    const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
  ]) {
    final words = AppLocalizations(locale);
    testWidgets(
      '$locale suggestion display preserves canonical imported observation and scene identity',
      (tester) async {
        final scene = fictionalScanScene(
          elements: [
            scanElementJson(
              id: 'toilet-1',
              kind: 'toilet',
              dimensions: [0.5, 0.7, 0.7],
            ),
          ],
        );
        final originalScene = jsonEncode(scene.toJson());
        final store = _ScanStore();
        const caseId = 'f4b1b823-f3e5-4a77-825c-9b1696f21fe6';
        final session = BathroomScanSession(
          store: store,
          caseId: caseId,
          isCurrent: () => true,
          adapter: _Scanner(),
        );
        await store.writeBytes(
          session.key,
          Uint8List.fromList(
            utf8.encode(
              jsonEncode(
                BathroomScanReview(
                  scene: scene,
                  difficulties: {ScanDifficulty.toiletTransfer},
                ).toJson(caseId),
              ),
            ),
          ),
        );
        final expected = suggestBathroomImprovements(
          scene: scene,
          reviewedElementIds: {'toilet-1'},
          difficulties: {ScanDifficulty.toiletTransfer},
        ).single;
        ScanSuggestion? imported;
        await tester.pumpWidget(
          localized(
            locale,
            BathroomScanScreen(
              session: session,
              importedFinding: (_) =>
                  imported == null ? null : 'fictional-finding',
              onImport: (suggestion) async {
                imported = suggestion;
                return 'fictional-finding';
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        await revealPastModel(
          tester,
          find.text(words.text('Explore support for sitting and standing')),
        );
        expect(find.text(expected.title), findsNothing);
        final idea = find.ancestor(
          of: find.text(words.text('Explore support for sitting and standing')),
          matching: find.byType(CheckboxListTile),
        );
        await revealPastModel(tester, idea);
        await tester.tap(idea);
        await tester.pumpAndSettle();
        expect(imported, isNotNull);
        expect(imported!.detail, expected.detail);
        expect(imported!.observation, expected.observation);
        expect(imported!.id, expected.id);
        expect(jsonEncode(session.review.scene!.toJson()), originalScene);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$locale long translated feature labels remain fully visible in large-text correction fields',
      (tester) async {
        narrowLargeText(tester, scale: 3.2);
        final scene = fictionalScanScene(
          elements: [scanElementJson(id: 'surface-1', kind: 'unknown')],
        );
        final store = _ScanStore();
        const caseId = 'f4b1b823-f3e5-4a77-825c-9b1696f21fe6';
        final session = BathroomScanSession(
          store: store,
          caseId: caseId,
          isCurrent: () => true,
          adapter: _Scanner(),
        );
        await store.writeBytes(
          session.key,
          Uint8List.fromList(
            utf8.encode(
              jsonEncode(BathroomScanReview(scene: scene).toJson(caseId)),
            ),
          ),
        );
        await tester.pumpWidget(
          localized(
            locale,
            BathroomScanScreen(
              session: session,
              importedFinding: (_) => null,
              onImport: (_) async => throw StateError('Review must not import'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(accessibleNavigation: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await tester.pumpAndSettle();
        final list = find.byKey(const ValueKey('scan-selection-surface-1'));
        await revealPastModel(tester, list);
        await tester.tap(list);
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .byWidgetPredicate(
                (w) => w is DropdownMenuItem<String> && w.value == 'surface-1',
              )
              .last,
        );
        await tester.pumpAndSettle();
        final selector = find.byKey(const ValueKey('surface-1-unknown'));
        for (var i = 0; i < 100 && selector.evaluate().isEmpty; i++) {
          await tester.dragFrom(const Offset(8, 350), const Offset(0, -250));
          await tester.pumpAndSettle();
        }
        await tester.ensureVisible(selector);
        await tester.pumpAndSettle();
        final label = find.descendant(
          of: selector,
          matching: find.text(words.text('Unidentified surface')),
        );
        expect(label, findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(label);
        expect(paragraph.maxLines, isNull);
        expect(paragraph.didExceedMaxLines, false);
        expect(paragraph.size.height, greaterThan(80));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final entry in <Locale, String>{
    const Locale('es'): 'Girar modelo a la izquierda',
    const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'): '向左旋转模型',
    const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'): '向左旋轉模型',
    const Locale('vi'): 'Xoay mô hình sang trái',
    const Locale('fil'): 'Iikot ang modelo pakaliwa',
  }.entries) {
    testWidgets(
      '${entry.key} 3D controls remain reachable at 320px and large text',
      (tester) async {
        narrowLargeText(tester, scale: 3.2);
        final scene = fictionalScanScene();
        await tester.pumpWidget(
          localized(
            entry.key,
            Scaffold(
              body: SingleChildScrollView(
                child: BathroomModelView(
                  scene: scene,
                  selectedId: scene.elements.first.id,
                  selectedLabel: 'fixture label {count}',
                  onSelect: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await reveal(tester, find.byTooltip(entry.value));
        await tester.tap(find.byTooltip(entry.value));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final semantics = tester
            .widgetList<Semantics>(find.byType(Semantics))
            .where(
              (widget) =>
                  widget.properties.value?.contains('fixture label {count}') ==
                  true,
            );
        expect(semantics.length, 1);
      },
    );
  }
}

Future<void> revealPastModel(WidgetTester tester, Finder finder) async {
  await tester.pumpAndSettle();
  for (var i = 0; i < 100 && finder.hitTestable().evaluate().isEmpty; i++) {
    if (finder.evaluate().isNotEmpty) {
      await Scrollable.ensureVisible(
        tester.element(finder.first),
        alignment: .5,
      );
    } else {
      final list = tester.getRect(find.byType(Scrollable).first);
      await tester.dragFrom(
        Offset(list.left + 4, list.center.dy),
        const Offset(0, -250),
      );
    }
    await tester.pumpAndSettle();
  }
  expect(finder.hitTestable(), findsWidgets);
}
