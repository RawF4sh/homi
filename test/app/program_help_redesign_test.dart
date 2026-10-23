import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/programs/live_programs_screen.dart';
import 'package:safe_at_home/features/programs/program_intake_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';

import '../services/case_evidence_api_client_test.dart' as http;
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;

Map<String, Object?> _manualProgram({bool sources = true}) => {
  'programId': 'fictional-program',
  'programName': 'Fictional manual-review program',
  'ruleVersion': 'fictional-rule-v2',
  'isDemo': true,
  'availability': 'unverified',
  'recheckAfter': null,
  'status': 'needs_confirmation',
  'checks': [
    for (var i = 0; i < 10; i++)
      {
        'id': 'check-$i',
        'status': 'unknown',
        'reasonCode': i == 5 ? 'EXCEPTION_UNRESOLVED' : 'MANUAL_REVIEW',
        'explanation': i == 5
            ? 'Fictional exception still needs program review; this is not a rejection.'
            : 'Fictional requirement $i remains unknown.',
        'missingFields': <String>[],
        'resolvedBy': i < 2
            ? 'resident'
            : i < 4
            ? 'professional'
            : i < 9
            ? 'program'
            : null,
        'sourceIds': [if (sources) 'fictional-source'],
      },
  ],
  'sources': [
    if (sources)
      {
        'id': 'fictional-source',
        'url': 'https://example.org/fictional-program',
        'title': 'Fictional official source',
        'reviewedOn': '2026-10-20',
        'effectiveFrom': null,
        'effectiveUntil': null,
      },
  ],
  'requiredDocuments': <String>[],
  'intake': sources
      ? 'Fictional contact instructions. Confirm intake with the program.'
      : null,
};

Map<String, Object?> _response(
  Map<String, Object?> request, {
  bool sources = true,
}) {
  final now = DateTime.now().toUtc().toIso8601String();
  return {
    'schemaVersion': '1',
    'caseId': request['caseId'],
    'caseRevision': request['expectedCaseRevision'],
    'evaluatedAt': now,
    'evaluationDate': now.substring(0, 10),
    'matches': [_manualProgram(sources: sources)],
  };
}

Future<AppServices> _app(FakeTransport transport) async {
  final app = services(MemoryPrivateStore(), transport);
  addTearDown(() {
    app.dispose();
    app.session.dispose();
  });
  await app.coordinator.createDraft();
  await app.coordinator.save();
  return app;
}

Widget _screen(AppServices app, {bool embedded = false, bool dark = false}) =>
    MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: dark ? SafeAtHomeTheme.dark() : SafeAtHomeTheme.light(),
      home: embedded
          ? Scaffold(
              body: LiveProgramsScreen(
                services: app,
                workspaceMode: true,
                embedded: true,
              ),
            )
          : LiveProgramsScreen(services: app),
    );

Future<void> _tap(WidgetTester tester, Finder target) async {
  await Scrollable.ensureVisible(tester.element(target), alignment: .5);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'manual-review Help explains responsibility and preserves draft routes (${dark ? 'dark' : 'light'})',
      (tester) async {
        final transport = FakeTransport((request) async {
          final body = http.requestJson(request);
          if (request.endpoint.path == '/v1/create-case') {
            return http.jsonResponse({...body, 'revision': 1});
          }
          if (request.endpoint.path == '/v1/match-case') {
            return http.jsonResponse(_response(body));
          }
          throw StateError('Only fictional matching is configured');
        });
        final app = await _app(transport);
        await tester.pumpWidget(_screen(app, embedded: true, dark: dark));
        await tester.pumpAndSettle();
        expect(find.byType(Scaffold), findsOneWidget);
        expect(find.byType(AppBar), findsNothing);
        expect(
          find.text('Possible help: review the program’s service scope.'),
          findsOneWidget,
        );
        expect(
          find.text('Service area: confirm your address with the program.'),
          findsOneWidget,
        );
        expect(
          find.text(
            'Current availability is unverified. Confirm it with the program.',
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            'Preparation only. Nothing has been submitted by this app.',
          ),
          findsOneWidget,
        );
        expect(
          find.text('0 met · 0 not met · 10 need confirmation'),
          findsNothing,
        );
        expect(find.text('Prepare a draft'), findsNothing);
        await _tap(
          tester,
          find.byKey(const ValueKey('program-fictional-program-review')),
        );
        expect(
          find.text('0 met · 0 not met · 10 need confirmation'),
          findsOneWidget,
        );
        for (final label in [
          'You can answer',
          'Ask the program',
          'Professional review',
          'Reviewer not specified',
        ]) {
          expect(find.text(label), findsOneWidget);
        }
        expect(
          find.text(
            'Fictional exception still needs program review; this is not a rejection.',
          ),
          findsOneWidget,
        );
        expect(
          find.byWidgetPredicate(
            (w) => w is ListTile && w.key.toString().contains('-check-check-'),
          ),
          findsNWidgets(10),
        );
        expect(find.text('Rule version: fictional-rule-v2'), findsOneWidget);
        expect(find.text('Fictional official source'), findsOneWidget);
        for (final action in ['intake', 'answers', 'export', 'history']) {
          expect(
            tester
                .widget<TextButton>(
                  find.byKey(ValueKey('program-fictional-program-$action')),
                )
                .onPressed,
            isNotNull,
          );
        }
        await _tap(
          tester,
          find.byKey(const ValueKey('program-fictional-program-contact')),
        );
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          find.text(
            'Fictional contact instructions. Confirm intake with the program.',
          ),
          findsWidgets,
        );
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        await _tap(
          tester,
          find.byKey(
            const ValueKey('program-fictional-program-missing-answers'),
          ),
        );
        expect(find.byType(ProgramIntakeScreen), findsOneWidget);
        expect(
          transport.requests.where(
            (r) => r.endpoint.path.contains('save-program-intake'),
          ),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'stale answers disable draft writes and clearing the plan removes prior results',
    (tester) async {
      final transport = FakeTransport((request) async {
        final body = http.requestJson(request);
        if (request.endpoint.path == '/v1/create-case') {
          return http.jsonResponse({...body, 'revision': 1});
        }
        return http.jsonResponse(_response(body, sources: false));
      });
      final app = await _app(transport);
      await tester.pumpWidget(_screen(app));
      await tester.pumpAndSettle();
      await _tap(
        tester,
        find.byKey(const ValueKey('program-fictional-program-review')),
      );
      expect(
        find.text('No verified source references are supplied for this route.'),
        findsOneWidget,
      );
      final before = app.coordinator.draft!.toJson();
      await app.coordinator.updateDraft(
        CaseDraft.fromJson({
          ...before,
          'profile': {
            ...before['profile'] as Map,
            'city': 'Fictional changed city',
          },
        }),
      );
      await tester.pumpAndSettle();
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        find.text('These results update once the case changes are saved.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('program-fictional-program-start')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(
              find.byKey(
                const ValueKey('program-fictional-program-missing-answers'),
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('program-fictional-program-contact')),
            )
            .onPressed,
        isNotNull,
      );
      await app.coordinator.clearSelected();
      await tester.pumpAndSettle();
      expect(find.text('Fictional manual-review program'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('late matching response cannot restore a closed plan', (
    tester,
  ) async {
    final pending = Completer<MatchingHttpResponse>();
    Map<String, Object?>? matched;
    final transport = FakeTransport((request) async {
      final body = http.requestJson(request);
      if (request.endpoint.path == '/v1/create-case') {
        return http.jsonResponse({...body, 'revision': 1});
      }
      matched = body;
      return pending.future;
    });
    final app = await _app(transport);
    await tester.pumpWidget(_screen(app));
    await tester.pump();
    await app.coordinator.clearSelected();
    pending.complete(http.jsonResponse(_response(matched!)));
    await tester.pumpAndSettle();
    expect(find.text('Fictional manual-review program'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
