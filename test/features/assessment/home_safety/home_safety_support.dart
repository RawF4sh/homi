import 'dart:convert';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/assessment/domain/home_safety/home_safety.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import '../../../app/case_coordinator_test.dart'
    show FakeSession, FakeTransport;
import '../../../app/live_workflows_test.dart' show MemoryPrivateStore;
import '../../../services/case_evidence_api_client_test.dart' as http;

class SafetyStore extends MemoryPrivateStore {
  bool fail = false;
  @override
  Future<void> writeJson(String key, Map<String, Object?> value) {
    if (fail && key.startsWith('home-safety.')) {
      throw StateError('Fictional full device');
    }
    return super.writeJson(key, value);
  }
}

class SafetyServer {
  SafetyServer(this.catalog);
  final HomeSafetyCatalog catalog;
  late CaseSnapshot snapshot;
  SafetyDocument document = SafetyDocument.empty();
  final history = <Map<String, Object?>>[];
  bool offline = false, loseNextSave = false;
  int saves = 0;
  Future<void> Function()? beforeRead;
  Map<String, Object?> state([String? ack]) => {
    'schemaVersion': '3',
    'case': snapshot.toJson(),
    'safety': {
      'schemaVersion': '3',
      'caseId': snapshot.caseId,
      'revision': history.length,
      'document': document.toJson(),
      'history': history,
    },
    'acknowledgedMutationId': ack,
  };
  void apply(SafetyMutation request) {
    final result = projectSafety(
      document,
      snapshot,
      request.operation,
      catalog,
    );
    document = result.document;
    snapshot = result.snapshot;
    history.add({
      'mutationId': request.id,
      'requestHash': safetyHash(request.toJson()),
      'revision': history.length + 1,
      'caseRevision': snapshot.revision,
      'recordedAt': '2026-10-24T18:00:00.000Z',
      'recordedBy': 'fictional-owner',
      'operation': request.operation,
    });
  }

  Future<MatchingHttpResponse> handle(MatchingHttpRequest request) async {
    final body = http.requestJson(request);
    switch (request.endpoint.path) {
      case '/v1/create-case':
        snapshot = parseCurrentCase({...body, 'revision': 1});
        return http.jsonResponse(snapshot.toJson());
      case '/v2/read-plan-name':
        return http.jsonResponse({
          'schemaVersion': '2',
          'caseId': body['caseId'],
          'name': null,
          'nameRevision': 0,
          'lastMutationId': null,
        });
      case '/v3/read-home-safety':
        await beforeRead?.call();
        if (offline) {
          throw const MatchingTransportException(
            MatchingTransportFailure.network,
          );
        }
        return http.jsonResponse(state());
      case '/v3/save-home-safety':
        if (offline) {
          throw const MatchingTransportException(
            MatchingTransportFailure.network,
          );
        }
        final op = SafetyMutation.fromJson(body, catalog);
        if (op.safetyRevision != history.length ||
            op.caseRevision != snapshot.revision) {
          throw StateError('Unexpected test mutation conflict');
        }
        saves++;
        apply(op);
        if (loseNextSave) {
          loseNextSave = false;
          throw const MatchingTransportException(
            MatchingTransportFailure.network,
          );
        }
        return http.jsonResponse(state(op.id));
      default:
        throw StateError('Unexpected test route ${request.endpoint.path}');
    }
  }
}

Future<
  ({
    AppServices services,
    SafetyStore store,
    SafetyServer server,
    FakeSession auth,
  })
>
safetyHarness() async {
  final catalog = await HomeSafetyCatalog.load(),
      store = SafetyStore(),
      server = SafetyServer(catalog),
      auth = FakeSession();
  final services = AppServices(
    config: LiveAppConfig(
      apiOrigin: Uri.parse('https://example.org'),
      supabaseUrl: Uri.parse('https://example.supabase.co'),
      publishableKey: 'fictional',
    ),
    session: auth,
    store: store,
    transport: FakeTransport(server.handle),
  );
  await services.coordinator.createDraft();
  await services.coordinator.save();
  return (services: services, store: store, server: server, auth: auth);
}

Map<String, Object?> addRoom(
  String id, {
  String type = 'bedroom',
  String? name,
}) => {
  'type': 'add_room',
  'room': {'id': id, 'type': type, 'name': name},
};
Map<String, Object?> answer(String id, String value) => {
  'type': 'answer',
  'roomId': id,
  'questionId': 'bedroom.path',
  'value': value,
};
Map<String, Object?> detached(Map<String, Object?> value) =>
    Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map);
