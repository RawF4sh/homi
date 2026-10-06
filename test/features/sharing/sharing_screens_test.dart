import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/sharing/sharing_screens.dart';
import 'package:safe_at_home/shared/models/sharing.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import '../../app/case_coordinator_test.dart' show FakeTransport;
import '../../app/live_workflows_test.dart' show MemoryPrivateStore, services;
import '../../services/case_evidence_api_client_test.dart' as http;
import 'sharing_contract_test.dart' show sharedFixture;

Map<String, Object?> _view({bool viewer = false}) {
  final v = sharedFixture(),
      member = Map<String, Object?>.from(v['membership']! as Map);
  if (viewer) {
    member['role'] = 'viewer';
    member['scope'] = {...(member['scope']! as Map), 'allowHelperNotes': false};
  }
  return {...v, 'membership': member};
}

Future<void> _mount(WidgetTester tester, AppServices app, Widget screen) async {
  addTearDown(() {
    app.dispose();
    app.session.dispose();
  });
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'viewer sees a selected online projection without editors, helper writes, or local storage',
    (tester) async {
      final view = _view(viewer: true), paths = <String>[];
      final store = MemoryPrivateStore();
      final app = services(
        store,
        FakeTransport((request) async {
          paths.add(request.endpoint.path);
          return http.jsonResponse(
            request.endpoint.path.endsWith('list-shared-cases')
                ? {
                    'schemaVersion': '3',
                    'memberships': [view['membership']],
                  }
                : view,
          );
        }),
      );
      await _mount(
        tester,
        app,
        SharedCaseScreen(
          services: app,
          membership: CaseMembership.fromJson(view['membership']),
        ),
      );
      expect(find.text('Fictional step to review'), findsOneWidget);
      expect(find.text('Add progress note'), findsNothing);
      expect(find.text('Edit profile'), findsNothing);
      expect(store.records, isEmpty);
      expect(paths.every((p) => p.startsWith('/v3/')), isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'revocation hides previously visible content when access is revalidated',
    (tester) async {
      final view = _view();
      var revoked = false;
      final app = services(
        MemoryPrivateStore(),
        FakeTransport((request) async {
          if (revoked) {
            return http.jsonResponse({
              'schemaVersion': '3',
              'error': {
                'code': 'SHARING_NOT_FOUND',
                'message': 'private server detail',
              },
            }, status: 404);
          }
          return http.jsonResponse(
            request.endpoint.path.endsWith('list-shared-cases')
                ? {
                    'schemaVersion': '3',
                    'memberships': [view['membership']],
                  }
                : view,
          );
        }),
      );
      await _mount(
        tester,
        app,
        SharedCaseScreen(
          services: app,
          membership: CaseMembership.fromJson(view['membership']),
        ),
      );
      expect(find.text('Fictional step to review'), findsOneWidget);
      revoked = true;
      await tester.tap(find.byTooltip('Refresh access'));
      await tester.pumpAndSettle();
      expect(find.text('Fictional step to review'), findsNothing);
      expect(find.text('Add progress note'), findsNothing);
      expect(find.textContaining('private server detail'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'backgrounding clears content and a signed-out late response cannot restore it',
    (tester) async {
      final view = _view();
      Completer<MatchingHttpResponse>? gate;
      final app = services(
        MemoryPrivateStore(),
        FakeTransport((request) async {
          if (gate != null) return gate.future;
          return http.jsonResponse(
            request.endpoint.path.endsWith('list-shared-cases')
                ? {
                    'schemaVersion': '3',
                    'memberships': [view['membership']],
                  }
                : view,
          );
        }),
      );
      await _mount(
        tester,
        app,
        SharedCaseScreen(
          services: app,
          membership: CaseMembership.fromJson(view['membership']),
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.text('Fictional step to review'), findsNothing);
      gate = Completer<MatchingHttpResponse>();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await app.session.signOut();
      gate.complete(
        http.jsonResponse({
          'schemaVersion': '3',
          'memberships': [view['membership']],
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('Fictional step to review'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'helper notes send only the granted membership revision and a mutation ID',
    (tester) async {
      final view = _view();
      Map<String, Object?>? saved;
      final app = services(
        MemoryPrivateStore(),
        FakeTransport((request) async {
          if (request.endpoint.path.endsWith('add-shared-note')) {
            saved = Map<String, Object?>.from(
              jsonDecode(utf8.decode(request.body)) as Map,
            );
          }
          return http.jsonResponse(
            request.endpoint.path.endsWith('list-shared-cases')
                ? {
                    'schemaVersion': '3',
                    'memberships': [view['membership']],
                  }
                : view,
          );
        }),
      );
      await _mount(
        tester,
        app,
        SharedCaseScreen(
          services: app,
          membership: CaseMembership.fromJson(view['membership']),
        ),
      );
      await tester.scrollUntilVisible(
        find.byType(TextField),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(find.byType(TextField), 'Fictional note');
      await tester.ensureVisible(find.text('Add progress note'));
      await tester.tap(find.text('Add progress note'));
      await tester.pumpAndSettle();
      expect(saved?['expectedPermissionRevision'], 2);
      expect(saved?['note'], 'Fictional note');
      expect(saved?.keys.toSet(), {
        'schemaVersion',
        'membershipId',
        'expectedPermissionRevision',
        'mutationId',
        'note',
      });
      expect(saved?['mutationId'], isNotEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'recipient reviews invitation permissions before an explicit accept',
    (tester) async {
      final view = _view();
      var accepted = false;
      final pending = {
        ...(view['membership']! as Map),
        'permissionRevision': 1,
        'state': 'pending',
      };
      final app = services(
        MemoryPrivateStore(),
        FakeTransport((request) async {
          if (request.endpoint.path.endsWith('review-invitation')) {
            return http.jsonResponse({
              'schemaVersion': '3',
              'membership': pending,
            });
          }
          if (request.endpoint.path.endsWith('accept-invitation')) {
            accepted = true;
            return http.jsonResponse({
              'schemaVersion': '3',
              'membership': view['membership'],
            });
          }
          return http.jsonResponse({
            'schemaVersion': '3',
            'memberships': accepted ? [view['membership']] : [],
          });
        }),
      );
      await _mount(tester, app, SharedWithMeScreen(services: app));
      expect(find.text('Accept invitation'), findsNothing);
      await tester.enterText(
        find.byType(TextField),
        List.filled(43, 'a').join(),
      );
      await tester.tap(find.text('Review invitation'));
      await tester.pumpAndSettle();
      expect(accepted, isFalse);
      expect(find.text('Progress notes allowed'), findsOneWidget);
      await tester.ensureVisible(find.text('Accept invitation'));
      await tester.tap(find.text('Accept invitation'));
      await tester.pumpAndSettle();
      expect(accepted, isTrue);
      expect(find.text('Shared home safety plan'), findsOneWidget);
    },
  );
  testWidgets(
    'owner previews an explicit selection before creating a recipient-bound code',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      Map<String, Object?>? snapshot, created;
      Map<String, Object?>? selected;
      final app = services(
        MemoryPrivateStore(),
        FakeTransport((request) async {
          final body = Map<String, Object?>.from(
            jsonDecode(utf8.decode(request.body)) as Map,
          );
          switch (request.endpoint.path) {
            case '/v1/create-case':
              snapshot = {...body, 'revision': 1};
              return http.jsonResponse(snapshot);
            case '/v3/list-sharing':
              return http.jsonResponse({
                'schemaVersion': '3',
                'shares': [],
                'availableProgramIds': [],
              });
            case '/v3/preview-sharing':
              selected = body;
              return http.jsonResponse({
                'schemaVersion': '3',
                'projection': {
                  'schemaVersion': '3',
                  'caseId': snapshot!['caseId'],
                  'sourceRevision': 1,
                  'publishedAt': '2026-10-24T00:00:00.000Z',
                  'stale': false,
                  'summary': 'Selected home safety information',
                  'findings':
                      ((snapshot!['findings'] as List).cast<Map>().where(
                            (f) => (body['scope'] as Map)['findingIds']
                                .contains(f['id']),
                          ))
                          .map(
                            (f) => {
                              'id': f['id'],
                              'room': f['room'],
                              'observation': f['observation'],
                              'reviewState': f['reviewState'],
                            },
                          )
                          .toList(),
                  'programs': [],
                },
              });
            case '/v3/create-invitation':
              created = body;
              return http.jsonResponse({
                'schemaVersion': '3',
                'created': true,
                'invitationCode': List.filled(43, 'a').join(),
                'membership': {
                  'membershipId': body['invitationId'],
                  'caseId': body['caseId'],
                  'recipientId': body['recipientId'],
                  'grantorId': 'fictional-owner',
                  'role': body['role'],
                  'scope': body['scope'],
                  'permissionRevision': 1,
                  'state': 'pending',
                  'expiresAt': body['expiresAt'],
                  'invitationExpiresAt': '2026-10-31T00:00:00.000Z',
                },
              });
            default:
              throw StateError('Unexpected request');
          }
        }),
      );
      await app.coordinator.createDraft();
      await app.coordinator.updateDraft(
        CaseDraft.fromJson({
          ...app.coordinator.draft!.toJson(),
          'findings': [
            {
              'id': 'selected',
              'room': 'bathroom',
              'observation': 'Selected observation',
              'reviewState': 'confirmed',
              'measurements': [],
              'evidenceIds': [],
            },
            {
              'id': 'excluded',
              'room': 'entrance',
              'observation': 'Excluded observation',
              'reviewState': 'needs_review',
              'measurements': [],
              'evidenceIds': [],
            },
          ],
        }),
      );
      await app.coordinator.save();
      await _mount(tester, app, PeopleWithAccessScreen(services: app));
      expect(find.text('Create invitation code'), findsNothing);
      await tester.enterText(
        find.byType(TextField),
        '22222222-2222-4222-8222-222222222222',
      );
      await tester.tap(find.text('Selected observation'));
      await tester.ensureVisible(find.text('Preview selected information'));
      await tester.tap(find.text('Preview selected information'));
      await tester.pumpAndSettle();
      expect((selected!['scope'] as Map)['findingIds'], ['selected']);
      expect(created, isNull);
      await tester.ensureVisible(find.text('Create invitation code'));
      await tester.tap(find.text('Create invitation code'));
      await tester.pumpAndSettle();
      expect(created!['recipientId'], '22222222-2222-4222-8222-222222222222');
      expect((created!['scope'] as Map)['findingIds'], ['selected']);
      expect((created!['scope'] as Map)['allowHelperNotes'], false);
      expect(find.byKey(const ValueKey('invitation-code')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
