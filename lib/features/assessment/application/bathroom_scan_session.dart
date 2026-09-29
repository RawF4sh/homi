import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../shared/models/case_draft.dart';
import '../../../shared/services/local_private_store.dart';
import '../domain/scan/bathroom_scan_scene.dart';
import '../domain/scan/scan_suggestions.dart';
import 'bathroom_scan_adapter.dart';

class BathroomScanReview {
  BathroomScanReview({
    this.scene,
    this.pendingScanId,
    Set<String> reviewed = const {},
    Map<String, ScanElementKind> labels = const {},
    Set<ScanDifficulty> difficulties = const {},
    Set<String> dismissed = const {},
  }) : reviewed = Set.unmodifiable(reviewed),
       labels = Map.unmodifiable(labels),
       difficulties = Set.unmodifiable(difficulties),
       dismissed = Set.unmodifiable(dismissed);

  final BathroomScanScene? scene;
  final String? pendingScanId;
  final Set<String> reviewed, dismissed;
  final Map<String, ScanElementKind> labels;
  final Set<ScanDifficulty> difficulties;

  BathroomScanReview copyWith({
    String? pendingScanId,
    bool clearPending = false,
    Set<String>? reviewed,
    Map<String, ScanElementKind>? labels,
    Set<ScanDifficulty>? difficulties,
    Set<String>? dismissed,
  }) => BathroomScanReview(
    scene: scene,
    pendingScanId: clearPending ? null : pendingScanId ?? this.pendingScanId,
    reviewed: reviewed ?? this.reviewed,
    labels: labels ?? this.labels,
    difficulties: difficulties ?? this.difficulties,
    dismissed: dismissed ?? this.dismissed,
  );

  Map<String, Object?> toJson(String caseId) => {
    'version': 1,
    'caseId': caseId,
    'scene': scene?.toJson(),
    'pendingScanId': pendingScanId,
    'reviewed': reviewed.toList()..sort(),
    'labels': {for (final e in labels.entries) e.key: e.value.name},
    'difficulties': difficulties.map((e) => e.name).toList()..sort(),
    'dismissed': dismissed.toList()..sort(),
  };

  factory BathroomScanReview.fromJson(Object? raw, String caseId) {
    if (raw is! Map ||
        raw['version'] != 1 ||
        raw['caseId'] != caseId ||
        raw.keys.length != 8) {
      throw const FormatException('Invalid private scan review.');
    }
    final scene = raw['scene'] == null
        ? null
        : BathroomScanScene.fromJson(raw['scene']);
    final pending = raw['pendingScanId'];
    if (pending != null && (pending is! String || !isCaseUuidV4(pending))) {
      throw const FormatException('Invalid pending scan.');
    }
    Set<String> strings(Object? value, int maximum) {
      if (value is! List ||
          value.length > maximum ||
          value.any((e) => e is! String) ||
          value.toSet().length != value.length) {
        throw const FormatException('Invalid private scan selection.');
      }
      return value.cast<String>().toSet();
    }

    final ids = scene?.elements.map((e) => e.id).toSet() ?? <String>{};
    final reviewed = strings(raw['reviewed'], 256);
    final labels = raw['labels'];
    final dismissed = strings(raw['dismissed'], 256);
    if (!ids.containsAll(reviewed) ||
        labels is! Map ||
        labels.length > 256 ||
        !ids.containsAll(labels.keys) ||
        dismissed.any(
          (id) => !RegExp(r'^[a-zA-Z0-9_.:-]{1,128}$').hasMatch(id),
        )) {
      throw const FormatException('Scan review has invalid bindings.');
    }
    try {
      return BathroomScanReview(
        scene: scene,
        pendingScanId: pending as String?,
        reviewed: reviewed,
        labels: {
          for (final e in labels.entries)
            e.key as String: ScanElementKind.values.byName(e.value as String),
        },
        difficulties: strings(
          raw['difficulties'],
          ScanDifficulty.values.length,
        ).map(ScanDifficulty.values.byName).toSet(),
        dismissed: dismissed,
      );
    } catch (_) {
      throw const FormatException('Invalid private scan review values.');
    }
  }
}

class ScanScopeExpired implements Exception {
  const ScanScopeExpired();
}

class _ScanCaptureAttempt {
  _ScanCaptureAttempt(this.id);
  final String id;
  bool cancelled = false, nativeStarted = false, acceptingResult = false;
}

class BathroomScanSession extends ChangeNotifier {
  BathroomScanSession({
    required this.store,
    required this.caseId,
    required this.isCurrent,
    required this.adapter,
  });
  final LocalPrivateStore store;
  final String caseId;
  final bool Function() isCurrent;
  final BathroomScanAdapter adapter;
  String get key => 'assessment:$caseId:bathroom-scan';
  BathroomScanReview review = BathroomScanReview();
  BathroomScanCapabilities? capabilities;
  bool busy = false, dirty = false, initialized = false, _disposed = false;
  String? notice;
  _ScanCaptureAttempt? _captureAttempt;
  bool get canCancelCapture =>
      _captureAttempt != null && !_captureAttempt!.acceptingResult;

  void guard() {
    if (_disposed || !isCurrent()) throw const ScanScopeExpired();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    guard();
    final bytes = await store.readBytes(key);
    guard();
    if (bytes != null) {
      if (bytes.length > 768 * 1024) {
        throw const FormatException('Private scan exceeds its storage bound.');
      }
      review = BathroomScanReview.fromJson(
        jsonDecode(utf8.decode(bytes)),
        caseId,
      );
    }
    if (review.pendingScanId != null) {
      notice =
          'The previous scan was interrupted. Your saved model is retained. Start a new scan when ready.';
      await _save(review.copyWith(clearPending: true));
    }
    await refreshCapabilities();
    initialized = true;
    _changed();
  }

  Future<void> refreshCapabilities() async {
    guard();
    try {
      final result = await adapter.capabilities();
      guard();
      capabilities = result;
    } on ScanScopeExpired {
      rethrow;
    } catch (_) {
      notice =
          'Scanner availability could not be checked. You can still use photos and manual measurements.';
    }
    _changed();
  }

  Future<void> _save(BathroomScanReview next) async {
    guard();
    final bytes = Uint8List.fromList(
      utf8.encode(jsonEncode(next.toJson(caseId))),
    );
    if (bytes.length > 768 * 1024) {
      throw const FormatException('Private scan exceeds its storage bound.');
    }
    review = next;
    dirty = true;
    _changed();
    try {
      await store.writeBytes(key, bytes);
      guard();
      dirty = false;
      _changed();
    } catch (_) {
      if (!_disposed && isCurrent()) {
        notice =
            'The device save failed. Keep this screen open, free device space and retry saving. The model has not been uploaded.';
        _changed();
      }
      rethrow;
    }
  }

  Future<void> _run(Future<void> Function() work) async {
    guard();
    if (!initialized || busy) throw StateError('Finish the current scan step.');
    busy = true;
    _changed();
    try {
      await work();
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> retrySave() => _run(() => _save(review));

  Future<void> discardUnsaved() => _run(() async {
    final bytes = await store.readBytes(key);
    guard();
    review = bytes == null
        ? BathroomScanReview()
        : BathroomScanReview.fromJson(jsonDecode(utf8.decode(bytes)), caseId);
    dirty = false;
    _changed();
  });

  Future<void> capture() => _run(() async {
    if (dirty) throw StateError('Save the current model before another scan.');
    final scanId = newUuidV4();
    final previous = review;
    final attempt = _ScanCaptureAttempt(scanId);
    _captureAttempt = attempt;
    notice = null;
    try {
      try {
        await _save(previous.copyWith(pendingScanId: scanId));
      } catch (_) {
        if (attempt.cancelled && !_disposed && isCurrent()) {
          review = previous.copyWith(clearPending: true);
          dirty = true;
          _changed();
        }
        rethrow;
      }
      guard();
      if (attempt.cancelled) {
        await _finishCancelledCapture(attempt, previous);
        return;
      }
      BathroomScanScene result;
      try {
        attempt.nativeStarted = true;
        result = await adapter.start(scanId);
        guard();
        if (result.scanId != scanId) {
          throw const FormatException(
            'Scan response belongs to another capture.',
          );
        }
      } on ScanScopeExpired {
        rethrow;
      } catch (error) {
        guard();
        attempt.acceptingResult = true;
        await _save(previous.copyWith(clearPending: true));
        notice = scanErrorMessage(
          attempt.cancelled ? PlatformException(code: 'scan_cancelled') : error,
        );
        _changed();
        return;
      }
      if (attempt.cancelled) {
        await _finishCancelledCapture(attempt, previous);
        return;
      }
      attempt.acceptingResult = true;
      _changed();
      await _save(BathroomScanReview(scene: result));
      notice =
          'Model saved privately on this device. Review the detected features before adding observations.';
      _changed();
    } finally {
      if (identical(_captureAttempt, attempt)) _captureAttempt = null;
    }
  });

  Future<void> _finishCancelledCapture(
    _ScanCaptureAttempt attempt,
    BathroomScanReview previous,
  ) async {
    guard();
    attempt.acceptingResult = true;
    await _save(previous.copyWith(clearPending: true));
    notice = scanErrorMessage(PlatformException(code: 'scan_cancelled'));
    _changed();
  }

  Future<void> reviewElement(
    String id, {
    required bool confirmed,
    ScanElementKind? label,
  }) => _run(() async {
    final element = review.scene?.elementById(id);
    if (element == null) throw const FormatException('Unknown scan feature.');
    final labels = {...review.labels};
    final reviewed = {...review.reviewed};
    if (label != null) labels[id] = label;
    if (confirmed) {
      reviewed.add(id);
    } else {
      reviewed.remove(id);
    }
    await _save(
      review.copyWith(reviewed: reviewed, labels: labels, dismissed: {}),
    );
  });

  Future<void> setDifficulty(ScanDifficulty difficulty, bool value) =>
      _run(() async {
        final next = {...review.difficulties};
        if (value) {
          next.add(difficulty);
        } else {
          next.remove(difficulty);
        }
        await _save(review.copyWith(difficulties: next, dismissed: {}));
      });

  Future<void> dismiss(String id) => _run(() async {
    if (review.dismissed.length >= 256) {
      throw StateError('Review limit reached.');
    }
    await _save(review.copyWith(dismissed: {...review.dismissed, id}));
  });

  Future<void> clearModel() => _run(() async {
    await _save(BathroomScanReview());
    notice =
        'Device model removed. Observations already added to the assessment can be edited or removed there.';
  });

  Future<void> cancelCapture() async {
    final attempt = _captureAttempt;
    if (attempt == null || attempt.acceptingResult) return;
    attempt.cancelled = true;
    if (attempt.nativeStarted) {
      try {
        await adapter.cancel(attempt.id);
      } catch (_) {
        if (!_disposed && isCurrent()) {
          notice =
              'Cancellation was requested. If the camera stays open, close the native scan. Its result will not replace your saved model.';
          _changed();
        }
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(cancelCapture().catchError((Object _) {}));
    super.dispose();
  }
}

String scanErrorMessage(Object error) {
  final code = error is PlatformException ? error.code : 'scan_failed';
  return switch (code) {
    'scan_cancelled' => 'Scan cancelled. Your previous model is retained.',
    'scan_interrupted' =>
      'Scanning was interrupted. Your previous model is retained; start a new scan when ready.',
    'scan_permission_denied' =>
      'Camera access is off. Enable it in device Settings, or continue with manual assessment.',
    'scan_unavailable' =>
      'Scanning is unavailable on this device. Continue with photos and manual measurements.',
    'scan_busy' => 'Another camera session is active. Close it and try again.',
    'scan_limit' =>
      'This scan reached its limit. Try a shorter bathroom scan with fewer objects.',
    _ =>
      'The scan could not be processed. Your previous model is retained. Try again in good light, or use photos and manual measurements.',
  };
}
