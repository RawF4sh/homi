import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/programs/program_intake_screen.dart';
import 'package:safe_at_home/features/requests/form_review_screen.dart';
import 'package:safe_at_home/features/requests/private_export_screen.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'app_design_test.dart' show narrowLargeText;
import 'case_coordinator_test.dart' show FakeTransport, FakeSession;
import 'live_workflows_test.dart' show MemoryPrivateStore, program, input;
import '../contracts/form_answers_test.dart' as fixture;
import '../services/case_evidence_api_client_test.dart' as http;

class _Server {
  bool offline = false;
  bool omitBirthDate = false;
  Map<String, Object?>? intakeOverride;
  late Map<String, Object?> currentCase;
  Map<String, Object?>? saved;
  int saves = 0;
  final pdf = utf8.encode('%PDF-1.7\nFictional draft\n%%EOF');
  final now = DateTime.now().toUtc();
  Map<String, Object?> get answers => {
    ...fixture.responseJson(),
    'schemaVersion': '2',
    'caseId': currentCase['caseId'],
    'caseRevision': currentCase['revision'],
    'context': {
      ...fixture.contextJson(),
      if (omitBirthDate) ...{
        'formVersion': 'fictional-revised-form-version',
        'formContextId': 'b' * 64,
      },
    },
    'saved': saved,
    'isCurrent': saved != null,
    'fieldDefinitions': [
      for (final field in [
        ('memberFirstName', 'Given name', 'text', 160),
        ('memberBirthDate', 'Birth date', 'date', 10),
        ('referralDate', 'Referral date', 'date', 10),
        ('referrerEmail', 'Contact email', 'email', 254),
      ])
        if (!omitBirthDate || field.$1 != 'memberBirthDate')
          {
            'key': field.$1,
            'label': field.$2,
            'kind': field.$3,
            'maxLength': field.$4,
          },
    ],
    'artifactKind': 'official_form_draft',
  };
  late final transport = FakeTransport((request) async {
    final body = http.requestJson(request);
    if (offline) {
      throw const MatchingTransportException(MatchingTransportFailure.network);
    }
    switch (request.endpoint.path) {
      case '/v1/create-case':
        currentCase = {...body, 'revision': 1};
        return http.jsonResponse(currentCase);
      case '/v1/read-case':
        return http.jsonResponse(currentCase);
      case '/v2/read-form-answers':
        return http.jsonResponse(answers);
      case '/v2/save-form-answers':
        saves++;
        currentCase['revision'] = (currentCase['revision'] as int) + 1;
        saved = {
          ...fixture.savedJson(),
          'caseId': currentCase['caseId'],
          'caseRevision': currentCase['revision'],
          'answerRevision': saves,
          'answers': [
            for (final answer in body['answers'] as List)
              {
                ...Map<String, Object?>.from(answer as Map),
                'reviewedAt': answer['reviewState'] == 'reviewed'
                    ? fixture.stamp
                    : null,
                'reviewedBy': answer['reviewState'] == 'reviewed'
                    ? 'fictional-user'
                    : null,
              },
          ],
        };
        return http.jsonResponse(answers);
      case '/v2/read-program-intake':
        return http.jsonResponse(
          intakeOverride ??
              {
                'schemaVersion': '2',
                'caseId': currentCase['caseId'],
                'caseRevision': currentCase['revision'],
                'definition': {
                  'programId': 'scfhp-eaa',
                  'questionnaireVersion': fixture.digest,
                  'questions': [
                    {
                      'key': 'cost',
                      'label': 'Estimated cost',
                      'kind': 'money',
                      'maxLength': null,
                      'description': 'Unknown is different from zero.',
                    },
                    {
                      'key': 'permission',
                      'label': 'Permission reported?',
                      'kind': 'boolean',
                      'maxLength': null,
                      'description': 'Reported permission only.',
                    },
                  ],
                },
                'saved': null,
                'isCurrent': false,
              },
        );
      case '/v1/list-evidence':
        return http.jsonResponse({
          'schemaVersion': '1',
          'caseId': currentCase['caseId'],
          'caseRevision': currentCase['revision'],
          'catalogRevision': 0,
          'evidence': <Object>[],
        });
      case '/v2/create-draft-export':
        return http.jsonResponse({
          'schemaVersion': '2',
          'artifactId': 'fictional-artifact',
          'caseId': currentCase['caseId'],
          'caseRevision': currentCase['revision'],
          ...fixture.contextJson(),
          'ruleVersion': 'fictional-rule',
          'answerRevision': 0,
          'evidenceCatalogRevision': 0,
          'exportContextId': fixture.digest,
          'generatedAt': now.toIso8601String(),
          'expiresAt': now.add(const Duration(minutes: 10)).toIso8601String(),
          'recheckAfter': null,
          'status': 'draft',
          'isDemo': false,
          'mediaType': 'application/pdf',
          'byteLength': pdf.length,
          'sha256': sha256.convert(pdf).toString(),
          'pageCount': 1,
          'renderingVersion': 'draft-export-annotations-v2',
          'selectedEvidence': <Object>[],
          'missingItems': <Object>[],
          'warnings': [
            'INCOMPLETE_DRAFT',
            'NOT_SUBMITTED',
            'POLICY_CURRENTNESS_UNKNOWN',
          ],
        });
      case '/v2/download-draft-export':
        return MatchingHttpResponse(
          statusCode: 200,
          contentType: 'application/pdf',
          body: pdf,
        );
      default:
        throw StateError(
          'Unexpected fictional request ${request.endpoint.path}',
        );
    }
  });
}

Future<AppServices> _app(_Server server, MemoryPrivateStore store) async {
  final app = AppServices(
    config: LiveAppConfig(
      apiOrigin: Uri.parse('https://example.org'),
      supabaseUrl: Uri.parse('https://example.supabase.co'),
      publishableKey: 'fictional',
    ),
    session: FakeSession(),
    store: store,
    transport: server.transport,
    pdfPreviewBuilder: (_) =>
        const SizedBox(key: ValueKey('fictional-pdf'), height: 200),
  );
  addTearDown(() {
    app.dispose();
    app.session.dispose();
  });
  await app.coordinator.createDraft();
  await app.coordinator.save();
  return app;
}

Widget _screen(AppServices app, {bool intake = false, bool export = false}) =>
    MaterialApp(
      theme: SafeAtHomeTheme.light(),
      home: export
          ? PrivateExportScreen(
              services: app,
              program: program(programId: 'scfhp-eaa'),
            )
          : intake
          ? ProgramIntakeScreen(
              services: app,
              program: program(programId: 'scfhp-eaa'),
            )
          : FormReviewScreen(
              services: app,
              program: program(programId: 'scfhp-eaa'),
            ),
    );
Future<void> _tap(WidgetTester tester, Finder target) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String label, String value) async {
  await tester.ensureVisible(input(label));
  await tester.pumpAndSettle();
  await tester.enterText(input(label), value);
  await tester.pumpAndSettle();
}

Future<void> _reopen(
  WidgetTester tester,
  AppServices app, {
  bool intake = false,
}) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.pumpWidget(_screen(app, intake: intake));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'changed intake questions retain new server answers and archive incompatible draft values',
    (tester) async {
      final server = _Server(), store = MemoryPrivateStore();
      final app = await _app(server, store);
      await tester.pumpWidget(_screen(app, intake: true));
      await tester.pumpAndSettle();
      await _enter(tester, 'Estimated cost', '0');
      await _tap(tester, find.byType(DropdownButtonFormField<String>));
      await _tap(tester, find.text('No').last);
      final nextVersion = 'c' * 64;
      server.intakeOverride = {
        'schemaVersion': '2',
        'caseId': server.currentCase['caseId'],
        'caseRevision': server.currentCase['revision'],
        'definition': {
          'programId': 'scfhp-eaa',
          'questionnaireVersion': nextVersion,
          'questions': [
            {
              'key': 'cost',
              'label': 'Cost confirmed?',
              'kind': 'boolean',
              'maxLength': null,
              'description': 'Changed fictional question.',
            },
            {
              'key': 'permission',
              'label': 'Permission details',
              'kind': 'text',
              'maxLength': 160,
              'description': 'Changed fictional question.',
            },
            {
              'key': 'added',
              'label': 'Added details',
              'kind': 'text',
              'maxLength': 160,
              'description': 'New fictional question.',
            },
          ],
        },
        'saved': {
          'schemaVersion': '2',
          'caseId': server.currentCase['caseId'],
          'caseRevision': server.currentCase['revision'],
          'programId': 'scfhp-eaa',
          'questionnaireVersion': nextVersion,
          'intakeRevision': 1,
          'updatedAt': fixture.stamp,
          'updatedBy': 'fictional-user',
          'answers': [
            {'key': 'cost', 'value': false, 'reviewState': 'reported'},
            {
              'key': 'permission',
              'value': 'Fresh permission details',
              'reviewState': 'reported',
            },
            {
              'key': 'added',
              'value': 'Fresh added details',
              'reviewState': 'reported',
            },
          ],
        },
        'isCurrent': true,
      };
      await _reopen(tester, app, intake: true);
      expect(tester.takeException(), isNull);
      expect(
        tester
            .state<FormFieldState<String>>(
              find.byType(DropdownButtonFormField<String>),
            )
            .value,
        'false',
      );
      expect(
        tester.widget<TextField>(input('Permission details')).controller!.text,
        'Fresh permission details',
      );
      expect(
        tester.widget<TextField>(input('Added details')).controller!.text,
        'Fresh added details',
      );
      final retained =
          store.records['intake.${app.coordinator.snapshot!.caseId}.scfhp-eaa']!['unmappedAnswers']
              as Map;
      expect((retained['${fixture.digest}:cost'] as Map)['value'], '0');
      expect((retained['${fixture.digest}:permission'] as Map)['value'], false);
      expect(server.saves, 0);
      server.offline = true;
      await _reopen(tester, app, intake: true);
      expect(
        tester.widget<TextField>(input('Added details')).controller!.text,
        'Fresh added details',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'form refresh drops obsolete validation fields while preserving unfinished values',
    (tester) async {
      final server = _Server(), store = MemoryPrivateStore();
      final app = await _app(server, store);
      await tester.pumpWidget(_screen(app));
      await tester.pumpAndSettle();
      await _enter(tester, 'Given name', 'Fictional retained value');
      await _enter(tester, 'Birth date', '2026-99-99');
      await _tap(tester, find.byKey(const ValueKey('form-save')));
      expect(
        find.byKey(const ValueKey('form-validation-feedback')),
        findsOneWidget,
      );
      expect(server.saves, 0);
      server.omitBirthDate = true;
      await _tap(tester, find.byKey(const ValueKey('form-reconcile')));
      expect(tester.takeException(), isNull);
      expect(input('Birth date'), findsNothing);
      expect(
        find.byKey(const ValueKey('form-validation-feedback')),
        findsNothing,
      );
      expect(
        tester.widget<TextField>(input('Given name')).controller!.text,
        'Fictional retained value',
      );
      final values =
          store.records['form.${app.coordinator.snapshot!.caseId}.scfhp-eaa']!['values']
              as Map;
      expect(values['memberBirthDate'], '2026-99-99');
      expect(values['memberFirstName'], 'Fictional retained value');
      expect(server.saves, 0);
    },
  );
  for (final intake in [false, true]) {
    testWidgets(
      'initial ${intake ? 'intake' : 'form'} context resumes offline without typing',
      (tester) async {
        final server = _Server(), store = MemoryPrivateStore();
        final app = await _app(server, store);
        if (!intake) {
          server.saved = {
            ...fixture.savedJson(),
            'caseId': server.currentCase['caseId'],
            'caseRevision': server.currentCase['revision'],
          };
        }
        await tester.pumpWidget(_screen(app, intake: intake));
        await tester.pumpAndSettle();
        server.offline = true;
        await _reopen(tester, app, intake: intake);
        expect(
          find.byKey(
            ValueKey(
              intake ? 'intake-offline-context' : 'form-offline-context',
            ),
          ),
          findsOneWidget,
        );
        expect(input(intake ? 'Estimated cost' : 'Given name'), findsOneWidget);
        if (!intake) {
          expect(
            tester.widget<TextField>(input('Given name')).controller!.text,
            'Fictional',
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'empty form starts with honest guidance, without a stale saved-answer warning',
    (tester) async {
      final app = await _app(_Server(), MemoryPrivateStore());
      await tester.pumpWidget(_screen(app));
      await tester.pumpAndSettle();
      expect(
        find.text('Saved answers need review for the current case and form.'),
        findsNothing,
      );
      expect(find.text('0 of 0 checked'), findsNothing);
      expect(
        find.text(
          'Enter what you know. Leave unknown answers blank, then review each value you enter.',
        ),
        findsOneWidget,
      );
    },
  );
  for (final invalid in [
    (
      'Birth date',
      '2026-99-99',
      'Enter a valid date as YYYY-MM-DD, or leave blank.',
    ),
    (
      'Contact email',
      'invalid email',
      'Enter a valid email address, or leave blank.',
    ),
    ('Birth date', '2999-01-01', 'Enter a date on or before today.'),
    (
      'Birth date',
      '2001-01-01',
      'Birth date must be on or before the referral date.',
    ),
  ]) {
    testWidgets(
      'form identifies ${invalid.$2}, focuses the field, and never starts an uncertain save',
      (tester) async {
        narrowLargeText(tester, scale: 3.2);
        final server = _Server(), store = MemoryPrivateStore();
        final app = await _app(server, store);
        await tester.pumpWidget(_screen(app));
        await tester.pumpAndSettle();
        if (invalid.$2 == '2001-01-01') {
          await _enter(tester, 'Referral date', '2000-01-01');
        }
        await _enter(tester, invalid.$1, invalid.$2);
        await _tap(tester, find.byKey(const ValueKey('form-save')));
        final field = tester.widget<TextField>(input(invalid.$1));
        expect(field.focusNode!.hasFocus, true);
        expect((field.decoration!.error as Text).data, invalid.$3);
        expect(
          tester.getTopLeft(input(invalid.$1)).dy,
          inInclusiveRange(0, 650),
        );
        expect(server.saves, 0);
        expect(find.text('Check the last save'), findsNothing);
        expect(
          store
              .records['form.${app.coordinator.snapshot!.caseId}.scfhp-eaa']!['uncertain'],
          false,
        );
        await _enter(tester, invalid.$1, '');
        await _tap(tester, find.byKey(const ValueKey('form-save')));
        expect(server.saves, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'form journal reopens offline, keeps local edits, and requires reload before online save',
    (tester) async {
      final server = _Server(), store = MemoryPrivateStore();
      final app = await _app(server, store);
      await tester.pumpWidget(_screen(app));
      await tester.pumpAndSettle();
      await _enter(tester, 'Given name', 'Fictional offline name');
      server.offline = true;
      await _reopen(tester, app);
      expect(
        find.byKey(const ValueKey('form-offline-context')),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(input('Given name')).controller!.text,
        'Fictional offline name',
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('form-save')))
            .onPressed,
        isNull,
      );
      await _enter(tester, 'Given name', 'Fictional updated offline');
      await _tap(tester, find.byKey(const ValueKey('form-reconcile')));
      expect(
        tester.widget<TextField>(input('Given name')).controller!.text,
        'Fictional updated offline',
      );
      await _reopen(tester, app);
      expect(
        tester.widget<TextField>(input('Given name')).controller!.text,
        'Fictional updated offline',
      );
      server.offline = false;
      await _tap(tester, find.byKey(const ValueKey('form-reconcile')));
      expect(find.byKey(const ValueKey('form-offline-context')), findsNothing);
      expect(
        tester.widget<TextField>(input('Given name')).controller!.text,
        'Fictional updated offline',
      );
      await _tap(tester, find.byKey(const ValueKey('form-save')));
      expect(server.saves, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'intake journal keeps zero and explicit no through offline reopen and reconnect',
    (tester) async {
      final server = _Server(), store = MemoryPrivateStore();
      final app = await _app(server, store);
      await tester.pumpWidget(_screen(app, intake: true));
      await tester.pumpAndSettle();
      await _enter(tester, 'Estimated cost', '0');
      final dropdown = find.byType(DropdownButtonFormField<String>);
      await _tap(tester, dropdown);
      await _tap(tester, find.text('No').last);
      server.offline = true;
      await _reopen(tester, app, intake: true);
      expect(
        find.byKey(const ValueKey('intake-offline-context')),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(input('Estimated cost')).controller!.text,
        '0',
      );
      expect(tester.state<FormFieldState<String>>(dropdown).value, 'false');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('intake-save')))
            .onPressed,
        isNull,
      );
      await _enter(tester, 'Estimated cost', '12.34');
      await _tap(tester, find.byKey(const ValueKey('intake-reconcile')));
      expect(
        tester.widget<TextField>(input('Estimated cost')).controller!.text,
        '12.34',
      );
      await _reopen(tester, app, intake: true);
      expect(
        tester.widget<TextField>(input('Estimated cost')).controller!.text,
        '12.34',
      );
      server.offline = false;
      await _tap(tester, find.byKey(const ValueKey('intake-reconcile')));
      expect(
        find.byKey(const ValueKey('intake-offline-context')),
        findsNothing,
      );
      expect(
        tester.widget<TextField>(input('Estimated cost')).controller!.text,
        '12.34',
      );
      expect(tester.state<FormFieldState<String>>(dropdown).value, 'false');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('intake-save')))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unsaved local changes invalidate an already prepared PDF and its share action',
    (tester) async {
      final server = _Server();
      final app = await _app(server, MemoryPrivateStore());
      await tester.pumpWidget(_screen(app, export: true));
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Prepare or recover this draft'));
      expect(
        server.transport.requests.where(
          (request) => request.endpoint.path == '/v2/download-draft-export',
        ),
        hasLength(1),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('fictional-pdf')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fictional-pdf')), findsOneWidget);
      expect(find.text('Share or save draft'), findsOneWidget);
      final draft = app.coordinator.currentDraft();
      await app.coordinator.updateDraft(
        CaseDraft.fromJson({
          ...draft.toJson(),
          'profile': {
            ...draft.profile.toJson(),
            'city': 'Fictional local change',
          },
        }),
      );
      await tester.pumpAndSettle();
      expect(app.coordinator.hasUnsavedChanges, true);
      expect(find.byKey(const ValueKey('fictional-pdf')), findsNothing);
      expect(find.text('Share or save draft'), findsNothing);
      final prepare = find.widgetWithText(
        FilledButton,
        'Prepare or recover this draft',
      );
      expect(tester.widget<FilledButton>(prepare).onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
