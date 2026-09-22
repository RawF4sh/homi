import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/assessment/application/live_assessment_session.dart';
import 'package:safe_at_home/features/assessment/application/assessment_sync.dart';
import 'package:safe_at_home/features/assessment/application/local_evidence_index.dart';
import 'package:safe_at_home/features/assessment/domain/image/image_validator.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import '../../../app/case_coordinator_test.dart'
    show FakeSession, FakeTransport;
import '../../../app/local_private_store_test.dart' show MemorySecrets;
import '../../../contracts/draft_export_test.dart' as fixture;

Object? sorted(Object? value) {
  if (value is Map) {
    return SplayTreeMap<String, Object?>.from({
      for (final e in value.entries) e.key as String: sorted(e.value),
    });
  }
  if (value is List) return value.map(sorted).toList();
  return value;
}

String hash(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(sorted(value)))).toString();
MatchingHttpResponse response(Object? json) => MatchingHttpResponse(
  statusCode: 200,
  contentType: 'application/json',
  body: utf8.encode(jsonEncode(json)),
);
void main() {
  late Directory directory;
  late AppServices services;
  late FakeTransport transport;
  late Map<String, Object?> saved;
  late Map<String, Object?> metadata;
  late List<Map<String, Object?>> history;
  LiveAssessmentSession? active;
  var offline = false;
  Future<void> Function()? beforeRead;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'sah-live-assessment-test-',
    );
    saved = fixture.snapshot().toJson()..['findings'] = <Object>[];
    metadata = {'measurements': <Object>[], 'reviews': <Object>[]};
    history = [];
    offline = false;
    beforeRead = null;
    Map<String, Object?> state() => {
      'schemaVersion': '2',
      'case': saved,
      'caseFingerprint': hash(saved),
      'catalogRevision': 0,
      'assessment': {
        'schemaVersion': '2',
        'caseId': saved['caseId'],
        'caseRevision': history.isEmpty
            ? saved['revision']
            : history.last['caseRevision'],
        'assessmentRevision': history.length,
        'metadata': metadata,
        'history': history,
      },
      'acknowledgedMutationId': null,
    };
    transport = FakeTransport((request) async {
      if (offline) {
        throw const MatchingTransportException(
          MatchingTransportFailure.network,
        );
      }
      final body =
          jsonDecode(utf8.decode(request.body)) as Map<String, dynamic>;
      switch (request.endpoint.path) {
        case '/v2/read-assessment':
          final hook = beforeRead;
          beforeRead = null;
          await hook?.call();
          return response(state());
        case '/v1/list-evidence':
          return response({
            'schemaVersion': '1',
            'caseId': saved['caseId'],
            'caseRevision': saved['revision'],
            'catalogRevision': 0,
            'evidence': <Object>[],
          });
        case '/v2/save-assessment':
          saved = {
            ...body['draft'] as Map<String, dynamic>,
            'revision': (saved['revision'] as int) + 1,
          };
          metadata = Map<String, Object?>.from(body['metadata'] as Map);
          history.add({
            'mutationId': body['mutationId'],
            'requestHash': hash(body),
            'caseRevision': saved['revision'],
            'assessmentRevision': history.length + 1,
            'recordedAt': '2026-10-22T20:00:00.000Z',
            'recordedBy': 'fictional-owner',
            'changes': <Object>[],
          });
          throw const MatchingTransportException(
            MatchingTransportFailure.network,
          );
        default:
          throw StateError('Unexpected test route');
      }
    });
    final session = FakeSession();
    services = AppServices(
      config: LiveAppConfig(
        apiOrigin: Uri.parse('https://example.org'),
        supabaseUrl: Uri.parse('https://project.supabase.co'),
        publishableKey: 'fictional',
      ),
      session: session,
      store: LocalPrivateStore(
        directory: directory,
        accountId: session.userId!,
        secrets: MemorySecrets(),
      ),
      transport: transport,
    );
    services.coordinator.snapshot = CaseSnapshot.fromJson(saved);
    services.coordinator.draft = CaseDraft.fromSnapshot(
      services.coordinator.snapshot!,
    );
  });
  tearDown(() async {
    active?.dispose();
    services.dispose();
    services.session.dispose();
    await directory.delete(recursive: true);
  });
  LiveAssessmentSession make() => active = LiveAssessmentSession(
    services: services,
    context: () => throw UnimplementedError(),
    transport: transport,
  );

  test(
    'restart recognizes exact atomic mutation receipt without duplicate write',
    () async {
      final first = make();
      await first.initialize();
      final id = first.controller.startFinding(AssessmentArea.entrance);
      first.controller.setObservation(id, 'Fictional threshold');
      await first.save();
      expect(first.sync.phase, SyncPhase.uncertain);
      expect(first.pendingRequest, isNotNull);
      await first.flush();
      first.dispose();
      active = null;
      final restored = make();
      await restored.initialize();
      expect(restored.localConflict, false);
      expect(restored.pendingRequest, isNull);
      expect(restored.sync.phase, SyncPhase.idle);
      expect(restored.sync.savedCase.revision, 3);
      expect(
        transport.requests.where(
          (r) => r.endpoint.path == '/v2/save-assessment',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'a separate writer on restart requires explicit local-cloud choice',
    () async {
      final first = make();
      await first.initialize();
      final id = first.controller.startFinding(AssessmentArea.bathroom);
      first.controller.setObservation(id, 'Unsaved local observation');
      await first.flush();
      first.dispose();
      active = null;
      saved = {...saved, 'revision': 3};
      final restored = make();
      await restored.initialize();
      expect(restored.localConflict, true);
      expect(
        restored.controller.findings.single.observation,
        'Unsaved local observation',
      );
      await expectLater(restored.save(), throwsStateError);
      expect(
        transport.requests.where(
          (r) => r.endpoint.path == '/v2/save-assessment',
        ),
        isEmpty,
      );
    },
  );

  Future<void> editProfile(String city) => services.coordinator.updateDraft(
    CaseDraft.fromJson({
      ...services.coordinator.currentDraft().toJson(),
      'profile': {
        ...services.coordinator.currentDraft().profile.toJson(),
        'city': city,
      },
    }),
  );

  test(
    'offline first assessment preserves profile edits and staged photos across restart',
    () async {
      await editProfile('Fictional offline city');
      offline = true;
      final first = make();
      await first.initialize();
      expect(first.state, isNull);
      expect(first.caseWriteBlocked, true);
      final id = first.controller.startFinding(AssessmentArea.entrance);
      first.controller.setObservation(id, 'Offline threshold note');
      final bytes = Uint8List.fromList(
        utf8.encode('fictional normalized photo bytes'),
      );
      final staged = await first.staging.put(
        bytes,
        ImageAccepted(
          format: SupportedImageFormat.jpeg,
          width: 20,
          height: 20,
          byteLength: bytes.length,
        ),
        capturedAt: '2026-10-22T20:00:00.000Z',
        orientationNormalized: true,
      );
      final evidenceId = first.controller.addEvidence(
        id,
        version: localEvidenceVersion(staged.key),
      );
      first.evidence.put(evidenceId, staged);
      await first.flush();
      await expectLater(first.save(), throwsStateError);
      first.dispose();
      active = null;
      final restored = make();
      await restored.initialize();
      expect(
        restored.controller.findings.single.observation,
        'Offline threshold note',
      );
      expect(
        await restored.staging.read(restored.evidence[evidenceId]!.key),
        bytes,
      );
      expect(
        services.coordinator.currentDraft().profile.city,
        'Fictional offline city',
      );
      expect(restored.caseWriteBlocked, true);
      expect(
        transport.requests.where(
          (r) => r.endpoint.path != '/v2/read-assessment',
        ),
        isEmpty,
      );
      await restored.flush();
    },
  );

  test(
    'profile edits arriving during assessment preflight prevent every remote mutation',
    () async {
      final current = make();
      await current.initialize();
      final id = current.controller.startFinding(AssessmentArea.bathroom);
      current.controller.setObservation(id, 'Keep this finding locally');
      beforeRead = () => editProfile('Concurrent profile edit');
      await expectLater(current.save(), throwsStateError);
      expect(current.caseWriteBlocked, true);
      expect(
        services.coordinator.currentDraft().profile.city,
        'Concurrent profile edit',
      );
      expect(
        current.controller.findings.single.observation,
        'Keep this finding locally',
      );
      expect(
        transport.requests.where(
          (r) =>
              r.endpoint.path.contains('save-') ||
              r.endpoint.path.contains('upload-') ||
              r.endpoint.path.contains('delete-'),
        ),
        isEmpty,
      );
      await current.flush();
    },
  );

  test(
    'unsaved profile blocks assessment reconciliation until the profile choice is explicit',
    () async {
      final current = make();
      await current.initialize();
      final id = current.controller.startFinding(AssessmentArea.entrance);
      current.controller.setObservation(id, 'Retained offline finding');
      await editProfile('Pending profile');
      await expectLater(
        current.resolveLocalConflict(keepLocal: true),
        throwsStateError,
      );
      await expectLater(current.recover(), throwsStateError);
      expect(
        services.coordinator.currentDraft().profile.city,
        'Pending profile',
      );
      expect(
        current.controller.findings.single.observation,
        'Retained offline finding',
      );
      await current.flush();
    },
  );

  test(
    'first offline opening preserves remote original units for untouched measurements on reconnect',
    () async {
      saved['findings'] = [
        {
          'id': 'finding-from-device-a',
          'room': 'entrance',
          'observation': 'Threshold',
          'reviewState': 'needs_review',
          'evidenceIds': <Object>[],
          'measurements': [
            {
              'type': 'thresholdHeight',
              'value': 15,
              'unit': 'mm',
              'method': 'manual',
              'confirmed': false,
            },
          ],
        },
      ];
      metadata = {
        'measurements': [
          {
            'findingId': 'finding-from-device-a',
            'type': 'thresholdHeight',
            'originalText': '1,5',
            'originalUnit': 'cm',
            'decimalSeparator': 'comma',
            'source': 'manual',
            'recorder': 'helper',
            'recordedAt': '2026-10-22T18:00:00.000Z',
          },
        ],
        'reviews': [
          {
            'findingId': 'finding-from-device-a',
            'state': 'needs_review',
            'note': 'Check the height again',
          },
        ],
      };
      services.coordinator.snapshot = CaseSnapshot.fromJson(saved);
      services.coordinator.draft = CaseDraft.fromSnapshot(
        services.coordinator.snapshot!,
      );
      offline = true;
      final current = make();
      await current.initialize();
      expect(
        current.controller
            .draftOf('finding-from-device-a')!
            .measurementOf('thresholdHeight')!
            .originalInputKnown,
        false,
      );
      final id = current.controller.startFinding(AssessmentArea.bathroom);
      current.controller.setObservation(id, 'A new offline finding');
      offline = false;
      await current.save();
      final request = transport.requests.singleWhere(
        (r) => r.endpoint.path == '/v2/save-assessment',
      );
      final body = jsonDecode(utf8.decode(request.body)) as Map;
      final original = (body['metadata']['measurements'] as List).single;
      expect(original['originalText'], '1,5');
      expect(original['originalUnit'], 'cm');
      expect(original['recorder'], 'helper');
      final oldReview = (body['metadata']['reviews'] as List).singleWhere(
        (r) => r['findingId'] == 'finding-from-device-a',
      );
      expect(oldReview['note'], 'Check the height again');
      await current.flush();
    },
  );

  test(
    'explicit reconciliation saves retained findings using the newly saved profile',
    () async {
      final first = make();
      await first.initialize();
      final id = first.controller.startFinding(AssessmentArea.entrance);
      first.controller.setObservation(id, 'Retain this local finding');
      await editProfile('Profile chosen by resident');
      await first.flush();
      first.dispose();
      active = null;
      saved = {
        ...services.coordinator.currentDraft().toJson(),
        'revision': (saved['revision'] as int) + 1,
      };
      services.coordinator.snapshot = CaseSnapshot.fromJson(saved);
      services.coordinator.draft = CaseDraft.fromSnapshot(
        services.coordinator.snapshot!,
      );
      final restored = make();
      await restored.initialize();
      expect(restored.localConflict, true);
      expect(restored.caseWriteBlocked, false);
      await restored.resolveLocalConflict(keepLocal: true);
      expect(restored.localConflict, false);
      await restored.save();
      final request = transport.requests.singleWhere(
        (r) => r.endpoint.path == '/v2/save-assessment',
      );
      final body = jsonDecode(utf8.decode(request.body)) as Map;
      expect(body['draft']['profile']['city'], 'Profile chosen by resident');
      expect(
        (body['draft']['findings'] as List).single['observation'],
        'Retain this local finding',
      );
      expect(body['expectedCaseRevision'], 3);
      await restored.flush();
    },
  );

  test(
    'an exact lost-save receipt cannot authorize overwriting a later writer',
    () async {
      final first = make();
      await first.initialize();
      final id = first.controller.startFinding(AssessmentArea.entrance);
      first.controller.setObservation(id, 'Earlier local observation');
      await first.save();
      expect(first.pendingRequest, isNotNull);
      await first.flush();
      first.dispose();
      active = null;
      saved = {
        ...saved,
        'revision': 4,
        'findings': [
          for (final raw in saved['findings'] as List)
            {
              ...raw as Map,
              'observation': 'Later observation from another device',
            },
        ],
      };
      final restored = make();
      await restored.initialize();
      expect(restored.localConflict, true);
      expect(restored.pendingRequest, isNotNull);
      expect(
        restored.controller.findings.single.observation,
        'Earlier local observation',
      );
      await expectLater(restored.save(), throwsStateError);
      expect(
        transport.requests.where(
          (r) => r.endpoint.path == '/v2/save-assessment',
        ),
        hasLength(1),
      );
      await restored.flush();
    },
  );
}
