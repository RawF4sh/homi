import '../../../shared/models/contracts.dart';
import '../../../shared/models/export_contract_values.dart';
import '../domain/capture/capture_adapter.dart';
import '../domain/ids/id_factory.dart';
import '../domain/measurement/measurement_fields.dart';
import '../domain/measurement/measurement_input.dart';
import '../domain/review/finding_review_tracker.dart';
import '../domain/review/review_snapshot.dart';

extension AssessmentAreaRoom on AssessmentArea {
  String get roomWireValue => switch (this) {
    AssessmentArea.bathroom => 'bathroom',
    AssessmentArea.entrance => 'entrance',
  };
}

enum MeasurementMethod {
  manual('manual'),
  estimated('estimated');

  const MeasurementMethod(this.wireValue);
  final String wireValue;
}

final class RecordedMeasurement {
  const RecordedMeasurement._({
    required this.type,
    required this.input,
    required this.method,
    required this.confirmed,
  });

  final String type;

  final MeasurementInput input;

  final MeasurementMethod method;

  final bool confirmed;

  bool get promptsZeroReview =>
      needsZeroReviewPrompt(type: type, millimetres: input.millimetres);

  Map<String, Object?> toV1Json() => {
    'type': type,
    'value': _wireNumber(input.millimetres),
    'unit': 'mm',
    'method': method.wireValue,
    'confirmed': confirmed,
  };

  RecordedMeasurement _withConfirmed(bool value) => RecordedMeasurement._(
    type: type,
    input: input,
    method: method,
    confirmed: value,
  );
}

final class FindingDraft {
  const FindingDraft._({
    required this.id,
    required this.area,
    required this.observation,
    required this.evidence,
    required this.measurements,
  });

  final String id;
  final AssessmentArea area;

  final String observation;

  final List<EvidenceVersion> evidence;

  final List<RecordedMeasurement> measurements;

  RecordedMeasurement? measurementOf(String type) {
    for (final RecordedMeasurement m in measurements) {
      if (m.type == type) return m;
    }
    return null;
  }

  ReviewSnapshot get snapshot => ReviewSnapshot(
    observation: observation,
    evidence: evidence,
    measurements: measurements.map((m) => m.toV1Json()),
  );

  FindingDraft _copyWith({
    String? observation,
    List<EvidenceVersion>? evidence,
    List<RecordedMeasurement>? measurements,
  }) => FindingDraft._(
    id: id,
    area: area,
    observation: observation ?? this.observation,
    evidence: evidence == null ? this.evidence : List.unmodifiable(evidence),
    measurements: measurements == null
        ? this.measurements
        : List.unmodifiable(measurements),
  );
}

class AssessmentController {
  AssessmentController({required IdFactory ids, FindingReviewTracker? tracker})
    : _ids = ids,
      _tracker = tracker ?? FindingReviewTracker();

  final IdFactory _ids;
  final FindingReviewTracker _tracker;

  final Map<String, FindingDraft> _drafts = {};
  final Set<String> _issuedFindingIds = {};
  final Set<String> _issuedEvidenceIds = {};

  List<FindingDraft> get drafts => List.unmodifiable(_drafts.values);

  FindingDraft? draftOf(String findingId) => _drafts[findingId];

  FindingReview? reviewOf(String findingId) => _tracker.reviewOf(findingId);

  String startFinding(AssessmentArea area) {
    final String id = _issue(_ids.newFindingId(), _issuedFindingIds);
    _drafts[id] = FindingDraft._(
      id: id,
      area: area,
      observation: '',
      evidence: const [],
      measurements: const [],
    );
    _tracker.start(id);
    return id;
  }

  void setObservation(String findingId, String text) {
    final FindingDraft draft = _require(findingId);
    if (draft.observation == text) return;
    _update(draft._copyWith(observation: text));
  }

  String addEvidence(String findingId, {required String version}) {
    final FindingDraft draft = _require(findingId);
    final String evidenceId = _issue(_ids.newEvidenceId(), _issuedEvidenceIds);
    _tracker.viewAdded(findingId);
    _update(
      draft._copyWith(
        evidence: [
          ...draft.evidence,
          EvidenceVersion(evidenceId: evidenceId, version: version),
        ],
      ),
    );
    return evidenceId;
  }

  void replaceEvidence(
    String findingId,
    String evidenceId, {
    required String version,
  }) {
    final FindingDraft draft = _require(findingId);
    final int index = draft.evidence.indexWhere(
      (e) => e.evidenceId == evidenceId,
    );
    if (index < 0) {
      throw ArgumentError.value(
        evidenceId,
        'evidenceId',
        'Not on this finding',
      );
    }
    if (draft.evidence[index].version == version) return;
    _update(
      draft._copyWith(
        evidence: [...draft.evidence]
          ..[index] = EvidenceVersion(evidenceId: evidenceId, version: version),
      ),
    );
  }

  bool removeEvidence(String findingId, String evidenceId) {
    final FindingDraft draft = _require(findingId);
    final List<EvidenceVersion> kept = draft.evidence
        .where((e) => e.evidenceId != evidenceId)
        .toList();
    if (kept.length == draft.evidence.length) return false;
    _update(draft._copyWith(evidence: kept));
    return true;
  }

  void setMeasurement(
    String findingId,
    String type,
    MeasurementInput input, {
    MeasurementMethod method = MeasurementMethod.manual,
  }) {
    final FindingDraft draft = _require(findingId);
    if (measurementFieldSpecFor(type) == null) {
      throw ArgumentError.value(type, 'type', 'Not a known measurement type');
    }
    final RecordedMeasurement? existing = draft.measurementOf(type);
    if (existing != null &&
        existing.input == input &&
        existing.method == method) {
      return;
    }
    final next = RecordedMeasurement._(
      type: type,
      input: input,
      method: method,
      confirmed: false,
    );
    _update(
      draft._copyWith(
        measurements: existing == null
            ? [...draft.measurements, next]
            : [
                for (final RecordedMeasurement m in draft.measurements)
                  m.type == type ? next : m,
              ],
      ),
    );
  }

  bool clearMeasurement(String findingId, String type) {
    final FindingDraft draft = _require(findingId);
    if (draft.measurementOf(type) == null) return false;
    _update(
      draft._copyWith(
        measurements: draft.measurements.where((m) => m.type != type).toList(),
      ),
    );
    return true;
  }

  bool confirmMeasurement(String findingId, String type) {
    final FindingDraft draft = _require(findingId);
    final RecordedMeasurement? existing = draft.measurementOf(type);
    if (existing == null) return false;
    if (existing.confirmed) return true;
    _drafts[findingId] = draft._copyWith(
      measurements: [
        for (final RecordedMeasurement m in draft.measurements)
          m.type == type ? m._withConfirmed(true) : m,
      ],
    );
    return true;
  }

  ReviewOutcome confirm(String findingId) =>
      _tracker.confirm(findingId, _require(findingId).snapshot);

  ReviewOutcome dismiss(String findingId) {
    _require(findingId);
    return _tracker.dismiss(findingId);
  }

  ReviewOutcome restore(String findingId) {
    _require(findingId);
    return _tracker.restore(findingId);
  }

  ReviewOutcome requestAnotherView(String findingId) {
    _require(findingId);
    return _tracker.requestAnotherView(findingId);
  }

  Finding? toFinding(String findingId) {
    final FindingDraft draft = _require(findingId);
    final String observation = draft.observation.trim();
    if (observation.isEmpty) return null;
    return Finding.fromJson({
      'id': draft.id,
      'room': draft.area.roomWireValue,
      'observation': observation,
      'reviewState': _tracker.reviewOf(findingId)!.state.wireValue,
      'evidenceIds': [for (final e in draft.evidence) e.evidenceId],
      'measurements': [for (final m in draft.measurements) m.toV1Json()],
    });
  }

  List<Finding> get findings =>
      List.unmodifiable(_drafts.keys.map(toFinding).whereType<Finding>());

  List<String> get incompleteFindingIds => List.unmodifiable(
    _drafts.values.where((d) => d.observation.trim().isEmpty).map((d) => d.id),
  );

  FindingDraft? removeFinding(String findingId) {
    _tracker.forget(findingId);
    return _drafts.remove(findingId);
  }

  void clear() {
    _drafts.clear();
    _issuedFindingIds.clear();
    _issuedEvidenceIds.clear();
    _tracker.clear();
  }

  FindingDraft _require(String findingId) =>
      _drafts[findingId] ??
      (throw ArgumentError.value(findingId, 'findingId', 'Unknown finding'));

  void _update(FindingDraft next) {
    _drafts[next.id] = next;
    _tracker.contentChanged(next.id, next.snapshot);
  }

  static String _issue(String id, Set<String> issued) {
    ExportContractValues.id(id);
    if (!issued.add(id)) {
      throw StateError('IdFactory returned an ID it had already issued.');
    }
    return id;
  }
}

num _wireNumber(double value) =>
    value == value.truncateToDouble() && value.abs() < 9007199254740992
    ? value.toInt()
    : value;
