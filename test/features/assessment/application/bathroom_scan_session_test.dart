import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_adapter.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_session.dart';
import 'package:safe_at_home/features/assessment/domain/scan/bathroom_scan_scene.dart';
import 'package:safe_at_home/features/assessment/domain/scan/scan_suggestions.dart';
import 'package:safe_at_home/shared/services/case_coordinator.dart';
import 'package:safe_at_home/shared/services/case_discovery_api_client.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';

import '../../../app/case_coordinator_test.dart'
    show FakeSession, FakeTransport;
import '../../../app/local_private_store_test.dart' show MemorySecrets;
import '../../../services/case_evidence_api_client_test.dart' as http;
import '../domain/scan/scan_test_fixtures.dart';

class _ScanStore extends LocalPrivateStore {
  _ScanStore({
    required super.directory,
    required super.accountId,
    required super.secrets,
    super.maxTotalBytes,
  });
  bool failNextWrite = false, loseNextWriteResponse = false;
  Completer<void>? writeEntered, releaseWrite;

  @override
  Future<void> writeBytes(String key, Uint8List bytes) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw const FileSystemException('Fictional device write failure');
    }
    final entered = writeEntered;
    if (entered != null) {
      writeEntered = null;
      entered.complete();
      await releaseWrite!.future;
    }
    await super.writeBytes(key, bytes);
    if (loseNextWriteResponse) {
      loseNextWriteResponse = false;
      throw const FileSystemException(
        'Fictional lost device write acknowledgement',
      );
    }
  }
}

class _Scanner implements BathroomScanAdapter {
  final starts = <String>[];
  final cancellations = <String>[];
  Future<BathroomScanScene> Function(String)? onStart;
  Future<void> Function(String)? onCancel;
  Future<BathroomScanCapabilities> Function()? onCapabilities;

  @override
  Future<BathroomScanCapabilities> capabilities() async =>
      onCapabilities == null
      ? const BathroomScanCapabilities(
          supported: true,
          source: 'roomplan',
          reason: 'available',
          depthSupported: true,
        )
      : await onCapabilities!();
  @override
  Future<BathroomScanScene> start(String id) async {
    starts.add(id);
    return onStart == null ? _scene(id) : await onStart!(id);
  }

  @override
  Future<void> cancel(String id) async {
    cancellations.add(id);
    await onCancel?.call(id);
  }
}

BathroomScanScene _scene(String id) =>
    BathroomScanScene.fromJson(scanSceneJson()..['scanId'] = id);

void main() {
  const caseId = '744fda0d-9d30-4a92-a430-8afca68e35d4';
  const otherCaseId = '39bd7ca8-5518-496e-b876-dd007c79bf5f';
  const interruptedId = '69ae6f49-c8a4-40f4-89e9-25a19e9de97e';
  late Directory directory;
  late MemorySecrets secrets;
  late _ScanStore store;
  late _Scanner scanner;
  var current = true;
  final sessions = <BathroomScanSession>{};

  BathroomScanSession make({LocalPrivateStore? storage, String id = caseId}) {
    final value = BathroomScanSession(
      store: storage ?? store,
      caseId: id,
      isCurrent: () => current,
      adapter: scanner,
    );
    sessions.add(value);
    return value;
  }

  void disposeSession(BathroomScanSession value) {
    sessions.remove(value);
    value.dispose();
  }

  Future<void> seed(BathroomScanReview review, {String id = caseId}) =>
      store.writeBytes(
        'assessment:$id:bathroom-scan',
        Uint8List.fromList(utf8.encode(jsonEncode(review.toJson(id)))),
      );

  Future<BathroomScanReview> persisted({String id = caseId}) async {
    final bytes = await store.readBytes('assessment:$id:bathroom-scan');
    expect(bytes, isNotNull);
    return BathroomScanReview.fromJson(jsonDecode(utf8.decode(bytes!)), id);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sah-scan-session-test-');
    secrets = MemorySecrets();
    store = _ScanStore(
      directory: directory,
      accountId: 'fictional-owner',
      secrets: secrets,
    );
    scanner = _Scanner();
    current = true;
  });
  tearDown(() async {
    for (final session in sessions) {
      session.dispose();
    }
    sessions.clear();
    await store.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'geometry and review survive encrypted account-scoped restart without plaintext',
    () async {
      final session = make();
      await session.initialize();
      await session.capture();
      await session.reviewElement(
        'door-1',
        confirmed: true,
        label: ScanElementKind.door,
      );
      await session.setDifficulty(ScanDifficulty.enteringBathroom, true);
      await session.dismiss('fictional-suggestion');
      final saved = session.review.toJson(caseId);
      final files = (await directory.list().toList())
          .whereType<File>()
          .toList();
      expect(files, hasLength(1));
      final cipher = await files.single.readAsString();
      for (final sensitive in [
        caseId,
        session.review.scene!.scanId,
        'door-1',
        'RoomPlan test fixture',
      ]) {
        expect(cipher, isNot(contains(sensitive)));
        expect(files.single.path, isNot(contains(sensitive)));
      }
      disposeSession(session);
      final reopened = make(
        storage: LocalPrivateStore(
          directory: directory,
          accountId: 'fictional-owner',
          secrets: secrets,
        ),
      );
      await reopened.initialize();
      expect(reopened.review.toJson(caseId), saved);
      expect(reopened.dirty, false);
      expect(await store.keys(), ['assessment:$caseId:bathroom-scan']);
    },
  );

  test(
    'capture intent is durable before the native camera can start',
    () async {
      final old = fictionalScanScene();
      await seed(BathroomScanReview(scene: old));
      scanner.onStart = (id) async {
        final saved = await persisted();
        expect(saved.pendingScanId, id);
        expect(saved.scene!.fingerprint, old.fingerprint);
        return _scene(id);
      };
      final session = make();
      await session.initialize();
      await session.capture();
      expect((await persisted()).pendingScanId, isNull);
      expect(session.review.scene!.scanId, scanner.starts.single);
    },
  );

  test('cancelled capture preserves the preceding model and review', () async {
    final original = BathroomScanReview(
      scene: fictionalScanScene(),
      reviewed: {'door-1'},
      difficulties: {ScanDifficulty.enteringBathroom},
      dismissed: {'fictional-suggestion'},
    );
    await seed(original);
    scanner.onStart = (_) async =>
        throw PlatformException(code: 'scan_cancelled');
    final session = make();
    await session.initialize();
    await session.capture();
    expect(session.review.toJson(caseId), original.toJson(caseId));
    expect((await persisted()).toJson(caseId), original.toJson(caseId));
    expect(session.notice, contains('cancelled'));
    expect(session.dirty, false);
  });

  test(
    'cancel during intent persistence never opens the native camera',
    () async {
      final original = BathroomScanReview(
        scene: fictionalScanScene(),
        reviewed: {'door-1'},
        labels: {'door-1': ScanElementKind.opening},
        difficulties: {ScanDifficulty.enteringBathroom},
      );
      await seed(original);
      final session = make();
      await session.initialize();
      final entered = Completer<void>();
      store.writeEntered = entered;
      store.releaseWrite = Completer<void>();
      final capture = session.capture();
      await entered.future;
      expect(session.canCancelCapture, true);
      await session.cancelCapture();
      store.releaseWrite!.complete();
      await capture;
      expect(scanner.starts, isEmpty);
      expect(scanner.cancellations, isEmpty);
      expect(session.review.toJson(caseId), original.toJson(caseId));
      expect((await persisted()).toJson(caseId), original.toJson(caseId));
      expect(session.canCancelCapture, false);
      expect(session.dirty, false);
      expect(session.notice, contains('cancelled'));
    },
  );

  test(
    'manual cancellation rejects a late successful native response',
    () async {
      final original = BathroomScanReview(
        scene: fictionalScanScene(),
        reviewed: {'door-1'},
        labels: {'door-1': ScanElementKind.opening},
        dismissed: {'fictional-suggestion'},
      );
      await seed(original);
      final entered = Completer<String>();
      final result = Completer<BathroomScanScene>();
      scanner.onStart = (id) {
        entered.complete(id);
        return result.future;
      };
      final session = make();
      await session.initialize();
      final capture = session.capture();
      final id = await entered.future;
      await session.cancelCapture();
      expect(scanner.cancellations, [id]);
      result.complete(_scene(id));
      await capture;
      expect(session.review.toJson(caseId), original.toJson(caseId));
      expect((await persisted()).toJson(caseId), original.toJson(caseId));
      expect(session.notice, contains('cancelled'));
    },
  );

  test(
    'failed cancellation cleanup retries the original review without recapture',
    () async {
      final original = BathroomScanReview(
        scene: fictionalScanScene(),
        reviewed: {'door-1'},
      );
      await seed(original);
      final entered = Completer<String>();
      final result = Completer<BathroomScanScene>();
      scanner.onStart = (id) {
        entered.complete(id);
        return result.future;
      };
      scanner.onCancel = (_) async {
        store.failNextWrite = true;
      };
      final session = make();
      await session.initialize();
      final capture = session.capture();
      final failed = expectLater(capture, throwsA(isA<FileSystemException>()));
      final id = await entered.future;
      await session.cancelCapture();
      result.complete(_scene(id));
      await failed;
      expect(session.dirty, true);
      expect(session.review.toJson(caseId), original.toJson(caseId));
      expect((await persisted()).pendingScanId, id);
      await session.retrySave();
      expect((await persisted()).toJson(caseId), original.toJson(caseId));
      expect(scanner.starts, [id]);
      expect(session.dirty, false);
    },
  );

  test(
    'cancelled preparation with a lost write acknowledgement retries clearing its intent',
    () async {
      final original = BathroomScanReview(scene: fictionalScanScene());
      await seed(original);
      final session = make();
      await session.initialize();
      final entered = Completer<void>();
      store.writeEntered = entered;
      store.releaseWrite = Completer<void>();
      store.loseNextWriteResponse = true;
      final capture = session.capture();
      final failed = expectLater(capture, throwsA(isA<FileSystemException>()));
      await entered.future;
      await session.cancelCapture();
      store.releaseWrite!.complete();
      await failed;
      expect(session.dirty, true);
      expect(session.review.toJson(caseId), original.toJson(caseId));
      expect((await persisted()).pendingScanId, isNotNull);
      await session.retrySave();
      expect((await persisted()).toJson(caseId), original.toJson(caseId));
      expect(scanner.starts, isEmpty);
      expect(session.dirty, false);
    },
  );

  test(
    'accepted geometry write stops offering cancellation and remains retryable',
    () async {
      final entered = Completer<void>();
      scanner.onStart = (id) async {
        store.writeEntered = entered;
        store.releaseWrite = Completer<void>();
        return _scene(id);
      };
      final session = make();
      await session.initialize();
      final capture = session.capture();
      await entered.future;
      expect(session.canCancelCapture, false);
      await session.cancelCapture();
      expect(scanner.cancellations, isEmpty);
      store.releaseWrite!.complete();
      await capture;
      expect((await persisted()).scene!.scanId, scanner.starts.single);
      expect(session.dirty, false);
    },
  );

  test(
    'native cancel failure still invalidates a later result from that capture',
    () async {
      final original = BathroomScanReview(scene: fictionalScanScene());
      await seed(original);
      final entered = Completer<String>();
      final result = Completer<BathroomScanScene>();
      scanner.onStart = (id) {
        entered.complete(id);
        return result.future;
      };
      scanner.onCancel = (_) async =>
          throw PlatformException(code: 'scan_failed');
      final session = make();
      await session.initialize();
      final capture = session.capture();
      final id = await entered.future;
      await session.cancelCapture();
      expect(session.notice, contains('Cancellation was requested'));
      result.complete(_scene(id));
      await capture;
      expect((await persisted()).toJson(caseId), original.toJson(caseId));
    },
  );

  test(
    'restart clears abandoned intent but retains previous confirmed geometry',
    () async {
      final old = fictionalScanScene();
      await seed(
        BathroomScanReview(
          scene: old,
          pendingScanId: interruptedId,
          reviewed: {'door-1'},
        ),
      );
      final session = make();
      await session.initialize();
      expect(session.review.pendingScanId, isNull);
      expect(session.review.scene!.fingerprint, old.fingerprint);
      expect(session.review.reviewed, {'door-1'});
      expect(session.notice, contains('interrupted'));
      expect(scanner.starts, isEmpty);
      expect((await persisted()).pendingScanId, isNull);
    },
  );

  test(
    'resume cleanup keeps actions locked until its durable write settles',
    () async {
      await seed(
        BathroomScanReview(
          scene: fictionalScanScene(),
          pendingScanId: interruptedId,
        ),
      );
      final entered = Completer<void>();
      store.writeEntered = entered;
      store.releaseWrite = Completer<void>();
      final session = make();
      final initialization = session.initialize();
      await entered.future;
      expect(session.initialized, false);
      await expectLater(
        session.reviewElement('door-1', confirmed: true),
        throwsStateError,
      );
      await expectLater(session.capture(), throwsStateError);
      store.releaseWrite!.complete();
      await initialization;
      expect(session.initialized, true);
      expect(session.dirty, false);
      expect(scanner.starts, isEmpty);
    },
  );

  test('failed intent persistence prevents camera presentation', () async {
    final session = make();
    await session.initialize();
    store.failNextWrite = true;
    await expectLater(session.capture(), throwsA(isA<FileSystemException>()));
    expect(scanner.starts, isEmpty);
    expect(session.dirty, true);
    expect(await store.readBytes(session.key), isNull);
    await session.retrySave();
    expect((await persisted()).pendingScanId, isNotNull);
    expect(session.dirty, false);
  });

  test(
    'new geometry failed write retains old disk model and retries exact result',
    () async {
      final old = fictionalScanScene();
      await seed(BathroomScanReview(scene: old));
      scanner.onStart = (id) async {
        store.failNextWrite = true;
        return _scene(id);
      };
      final session = make();
      await session.initialize();
      await expectLater(session.capture(), throwsA(isA<FileSystemException>()));
      final captured = session.review.scene!;
      expect(captured.scanId, scanner.starts.single);
      expect((await persisted()).scene!.fingerprint, old.fingerprint);
      expect(session.dirty, true);
      await expectLater(session.capture(), throwsStateError);
      await session.retrySave();
      expect((await persisted()).scene!.fingerprint, captured.fingerprint);
      expect((await persisted()).pendingScanId, isNull);
      expect(scanner.starts, hasLength(1));
      expect(session.dirty, false);
    },
  );

  test(
    'lost successful write acknowledgement retries without recapturing geometry',
    () async {
      scanner.onStart = (id) async {
        store.loseNextWriteResponse = true;
        return _scene(id);
      };
      final session = make();
      await session.initialize();
      await expectLater(session.capture(), throwsA(isA<FileSystemException>()));
      final fingerprint = session.review.scene!.fingerprint;
      expect((await persisted()).scene!.fingerprint, fingerprint);
      expect(session.dirty, true);
      await session.retrySave();
      expect((await persisted()).scene!.fingerprint, fingerprint);
      expect(scanner.starts, hasLength(1));
      expect(session.dirty, false);
    },
  );

  test(
    'explicit discard restores durable geometry after a failed replacement',
    () async {
      final old = fictionalScanScene();
      await seed(BathroomScanReview(scene: old, reviewed: {'door-1'}));
      scanner.onStart = (id) async {
        store.failNextWrite = true;
        return _scene(id);
      };
      final session = make();
      await session.initialize();
      await expectLater(session.capture(), throwsA(isA<FileSystemException>()));
      await session.discardUnsaved();
      expect(session.review.scene!.fingerprint, old.fingerprint);
      expect(session.review.reviewed, {'door-1'});
      expect(session.dirty, false);
    },
  );

  test(
    'scope change rejects delayed geometry and leaves only its old-account intent',
    () async {
      final old = fictionalScanScene();
      await seed(BathroomScanReview(scene: old));
      final entered = Completer<String>();
      final result = Completer<BathroomScanScene>();
      scanner.onStart = (id) {
        entered.complete(id);
        return result.future;
      };
      final session = make();
      await session.initialize();
      final capture = session.capture();
      final rejected = expectLater(capture, throwsA(isA<ScanScopeExpired>()));
      final id = await entered.future;
      current = false;
      result.complete(_scene(id));
      await rejected;
      expect(session.review.scene!.fingerprint, old.fingerprint);
      expect((await persisted()).scene!.fingerprint, old.fingerprint);
      expect((await persisted()).pendingScanId, id);
    },
  );

  test(
    'disposing the screen cancels exactly its active scan and rejects a late result',
    () async {
      final entered = Completer<String>();
      final result = Completer<BathroomScanScene>();
      scanner.onStart = (id) {
        entered.complete(id);
        return result.future;
      };
      final session = make();
      await session.initialize();
      final capture = session.capture();
      final rejected = expectLater(capture, throwsA(isA<ScanScopeExpired>()));
      final id = await entered.future;
      disposeSession(session);
      expect(scanner.cancellations, [id]);
      result.complete(_scene(id));
      await rejected;
      expect((await persisted()).scene, isNull);
      expect((await persisted()).pendingScanId, id);
    },
  );

  test(
    'another review action cannot overtake an active camera operation',
    () async {
      await seed(BathroomScanReview(scene: fictionalScanScene()));
      final entered = Completer<void>();
      final result = Completer<BathroomScanScene>();
      scanner.onStart = (_) {
        entered.complete();
        return result.future;
      };
      final session = make();
      await session.initialize();
      final capture = session.capture();
      await entered.future;
      await expectLater(
        session.reviewElement('door-1', confirmed: true),
        throwsStateError,
      );
      result.completeError(PlatformException(code: 'scan_cancelled'));
      await capture;
      expect(session.review.reviewed, isEmpty);
    },
  );

  test(
    'actual encrypted-store quota stops capture before opening the camera',
    () async {
      final limited = _ScanStore(
        directory: directory,
        accountId: 'fictional-owner',
        secrets: secrets,
        maxTotalBytes: 1,
      );
      final session = make(storage: limited);
      await session.initialize();
      await expectLater(session.capture(), throwsStateError);
      expect(scanner.starts, isEmpty);
      expect(session.dirty, true);
      expect(await limited.keys(), isEmpty);
      await limited.close();
    },
  );

  test(
    'case coordinator deletion removes its scan while retaining another case',
    () async {
      final account = FakeSession();
      final transport = FakeTransport(
        (_) async => throw StateError('No network expected'),
      );
      final coordinator = CaseCoordinator(
        session: account,
        store: store,
        cases: http.clientFor(transport),
        discovery: CaseDiscoveryApiClient(
          listCasesEndpoint: Uri.parse('https://example.org/v1/list-cases'),
          caseEndpoint: Uri.parse('https://example.org/v1/read-case'),
          tokenProvider: account.accessToken,
          transport: transport,
        ),
      );
      addTearDown(coordinator.dispose);
      addTearDown(account.dispose);
      await coordinator.createDraft();
      final selected = coordinator.draft!.caseId;
      final session = make(id: selected);
      await session.initialize();
      await session.capture();
      await seed(
        BathroomScanReview(scene: fictionalScanScene()),
        id: otherCaseId,
      );
      disposeSession(session);
      await coordinator.clearSelected();
      expect(
        await store.readBytes('assessment:$selected:bathroom-scan'),
        isNull,
      );
      expect((await persisted(id: otherCaseId)).scene, isNotNull);
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'explicit account cleanup removes encrypted geometry and its key',
    () async {
      final session = make();
      await session.initialize();
      await session.capture();
      expect(secrets.values, isNotEmpty);
      disposeSession(session);
      await store.clear();
      expect(secrets.values, isEmpty);
      expect(await directory.exists(), false);
    },
  );
}
