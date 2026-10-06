import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/tracking/program_progress_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/l10n/catalogs/tracking.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import '../../app/case_coordinator_test.dart' show FakeSession, FakeTransport;
import '../../app/live_workflows_test.dart' show MemoryPrivateStore;
import '../../services/case_evidence_api_client_test.dart' as http;
import 'device_reminders_test.dart' show FakeNotificationDevice, task;

const _caseId = '11111111-0000-4000-8000-000000000001';

Future<AppServices> app() async {
  final store = MemoryPrivateStore(),
      tasks = [task('one').data, task('two').data]
          .map(
            (t) => <String, Object?>{...t, 'title': '${t['title']} ${t['id']}'},
          )
          .toList();
  var revision = 0;
  final transport = FakeTransport((request) async {
    final body = jsonDecode(utf8.decode(request.body)) as Map;
    String? ack;
    if (request.endpoint.path == '/v3/save-progress') {
      expect(store.records['progress-pending.$_caseId'], isNotNull);
      final operation = body['operation'] as Map,
          incoming = Map<String, Object?>.from(operation['task'] as Map);
      final index = tasks.indexWhere((t) => t['id'] == incoming['id']);
      incoming['needsReview'] = false;
      if (index < 0) {
        tasks.add(incoming);
      } else {
        tasks[index] = incoming;
      }
      revision++;
      ack = body['mutationId'] as String;
    }
    return http.jsonResponse({
      'schemaVersion': '3',
      'caseId': _caseId,
      'caseRevision': 1,
      'revision': revision,
      'programs': <Object>[],
      'tasks': tasks,
      'nextOffset': null,
      'acknowledgedMutationId': ack,
      'historyVersion': 'f' * 64,
    });
  });
  final services = AppServices(
    config: LiveAppConfig(
      apiOrigin: Uri.parse('https://example.org'),
      supabaseUrl: Uri.parse('https://fictional.supabase.co'),
      publishableKey: 'fictional',
      trackingEnabled: true,
    ),
    session: FakeSession(),
    store: store,
    transport: transport,
    notificationDevice: FakeNotificationDevice(),
  );
  await services.progressReady;
  final draft = CaseDraft.fromJson({
    'schemaVersion': '1',
    'caseId': _caseId,
    'profile': {
      'city': null,
      'county': null,
      'healthPlan': null,
      'tenure': null,
      'ageYears': null,
      'householdSize': null,
      'annualIncomeUsd': null,
      'ownerConsentReported': null,
    },
    'unresolvedFields': <Object>[],
    'findings': <Object>[],
  });
  await store.writeJson('case.$_caseId', {
    'version': 1,
    'draft': draft.toJson(),
    'snapshot': draft.atRevision(1).toJson(),
    'uncertain': false,
    'conflict': false,
  });
  await services.coordinator.restoreLocal(_caseId);
  return services;
}

void main() {
  testWidgets(
    'dashboard completes one task, creates another with a journal, and retains the others',
    (tester) async {
      final services = await app();
      addTearDown(() {
        services.dispose();
        services.session.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: ProgramProgressScreen(services: services, tasksFirst: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Pending'), findsNWidgets(2));
      await tester.ensureVisible(find.text('Complete task').first);
      await tester.tap(find.text('Complete task').first);
      await tester.pumpAndSettle();
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Pending'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Add next step'),
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Add next step'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Next step'),
        'Fictional provider call',
      );
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Save task'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save task'));
      await tester.pumpAndSettle();
      expect(services.progress!.cached[_caseId]!.tasks.length, 3);
      expect(
        services.progress!.cached[_caseId]!.tasks.where((t) => t.open).length,
        2,
      );
      expect(services.progress!.pending, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Spanish large-text dashboard preserves resident content and exposes task actions',
    (tester) async {
      final services = await app();
      addTearDown(() {
        services.dispose();
        services.session.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          locale: const Locale('es'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: ProgramProgressScreen(services: services, tasksFirst: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Mis próximos pasos'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Fictional private health paperwork one'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Fictional private health paperwork one'), findsWidgets);
      expect(services.progress!.cached[_caseId]!.tasks.length, 2);
      expect(find.text('Pendiente'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
  test('all new catalogs preserve placeholders in all five translations', () {
    final placeholders = RegExp(r'\{[a-zA-Z]+\}');
    for (final entry in trackingTranslations.entries) {
      expect(entry.value.keys.toSet(), {
        'es',
        'zh-Hans',
        'zh-Hant',
        'vi',
        'fil',
      }, reason: entry.key);
      final original = placeholders
          .allMatches(entry.key)
          .map((m) => m[0])
          .toSet();
      for (final translated in entry.value.values) {
        expect(
          placeholders.allMatches(translated).map((m) => m[0]).toSet(),
          original,
          reason: entry.key,
        );
      }
    }
  });
}
