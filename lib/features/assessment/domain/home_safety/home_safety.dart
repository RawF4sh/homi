import 'dart:collection';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../../../../shared/models/case_draft.dart';
import '../../../../shared/models/contracts.dart';
import '../../../../shared/models/export_contract_values.dart';
import '../assessment_location.dart';

const homeSafetyCatalogVersion = 'sah-steadi-home-2017-v1';
const safetyAnswerValues = [
  'yes',
  'no',
  'not_sure',
  'not_applicable',
  'unanswered',
];
const homeSafetyMaximumBytes = 256 * 1024;
typedef V = ExportContractValues;

String safetyHash(Object? value) {
  Object? sorted(Object? v) => v is Map
      ? SplayTreeMap<String, Object?>.from({
          for (final e in v.entries) e.key as String: sorted(e.value),
        })
      : v is List
      ? v.map(sorted).toList()
      : v;
  return sha256.convert(utf8.encode(jsonEncode(sorted(value)))).toString();
}

String? roomName(Object? value) {
  if (value == null) return null;
  if (value is! String ||
      value.isEmpty ||
      value.trim() != value ||
      value.runes.length > 80 ||
      RegExp(
        r'[\x00-\x1f\x7f-\x9f\u2028\u2029\u202a-\u202e\u2066-\u2069]',
      ).hasMatch(value) ||
      value.runes.any((r) => r >= 0xd800 && r <= 0xdfff)) {
    V.invalid();
  }
  return value;
}

class SafetyQuestion {
  SafetyQuestion._(
    this.id,
    this.section,
    this.rooms,
    this.prompt,
    this.concernWhen,
    this.guidance,
  );
  factory SafetyQuestion.fromJson(Object? json) {
    final v = V.object(json, {
      'id',
      'section',
      'rooms',
      'prompt',
      'concernWhen',
      'guidance',
    });
    final polarity = v['concernWhen'];
    if (!{'yes', 'no'}.contains(polarity)) V.invalid();
    return SafetyQuestion._(
      V.id(v['id']),
      V.id(v['section']),
      V.list(
        v['rooms'],
        (r) => AssessmentLocation.values.byName(r as String),
        7,
      ),
      V.id(v['prompt']),
      polarity as String,
      V.id(v['guidance']),
    );
  }
  final String id, section, prompt, concernWhen, guidance;
  final List<AssessmentLocation> rooms;
}

class HomeSafetyCatalog {
  HomeSafetyCatalog._(
    this.questions,
    this.sourceUrl,
    this.sourceTitle,
    this.reviewedOn,
  );
  factory HomeSafetyCatalog.fromJson(Object? json) {
    final v = V.object(json, {
      'version',
      'sourceUrl',
      'sourceTitle',
      'reviewedOn',
      'questions',
    });
    if (v['version'] != homeSafetyCatalogVersion ||
        v['sourceUrl'] !=
            'https://www.cdc.gov/steadi/pdf/steadi-brochure-checkforsafety-508.pdf' ||
        v['reviewedOn'] != '2026-10-24') {
      V.invalid();
    }
    final questions = V.list(v['questions'], SafetyQuestion.fromJson, 16);
    V.unique(questions.map((q) => q.id));
    if (questions.length != 16) V.invalid();
    return HomeSafetyCatalog._(
      questions,
      v['sourceUrl'] as String,
      V.id(v['sourceTitle']),
      v['reviewedOn'] as String,
    );
  }
  static Future<HomeSafetyCatalog> load() async => HomeSafetyCatalog.fromJson(
    jsonDecode(
      await rootBundle.loadString('backend/src/assessment/steadi-catalog.json'),
    ),
  );
  final List<SafetyQuestion> questions;
  final String sourceUrl, sourceTitle, reviewedOn;
  SafetyQuestion question(String id) => questions.firstWhere((q) => q.id == id);
  List<SafetyQuestion> forRoom(RoomInstance room) => questions
      .where((q) => q.rooms.contains(room.type))
      .toList(growable: false);
}

class RoomInstance {
  RoomInstance({required this.id, required this.type, required this.name}) {
    V.id(id);
    roomName(name);
  }
  factory RoomInstance.fromJson(Object? json) {
    final v = V.object(json, {'id', 'type', 'name'});
    return RoomInstance(
      id: V.id(v['id']),
      type: AssessmentLocation.values.byName(v['type'] as String),
      name: roomName(v['name']),
    );
  }
  final String id;
  final AssessmentLocation type;
  final String? name;
  Map<String, Object?> toJson() => {'id': id, 'type': type.name, 'name': name};
}

class SafetyAnswer {
  SafetyAnswer._(this.roomId, this.questionId, this.value, this.revision);
  factory SafetyAnswer.fromJson(Object? json) {
    final v = V.object(json, {'roomId', 'questionId', 'value', 'revision'});
    if (!safetyAnswerValues.contains(v['value'])) V.invalid();
    return SafetyAnswer._(
      V.id(v['roomId']),
      V.id(v['questionId']),
      v['value'] as String,
      V.integer(v['revision']),
    );
  }
  final String roomId, questionId, value;
  final int revision;
  Map<String, Object?> toJson() => {
    'roomId': roomId,
    'questionId': questionId,
    'value': value,
    'revision': revision,
  };
}

class FindingRoom {
  FindingRoom._(
    this.findingId,
    this.roomId,
    this.questionId,
    this.answerRevision,
  );
  factory FindingRoom.fromJson(Object? json) {
    final v = V.object(json, {
      'findingId',
      'roomId',
      'questionId',
      'answerRevision',
    });
    final question = v['questionId'] == null ? null : V.id(v['questionId']);
    if ((question == null) != (v['answerRevision'] == null)) V.invalid();
    return FindingRoom._(
      V.id(v['findingId']),
      V.id(v['roomId']),
      question,
      question == null ? null : V.integer(v['answerRevision']),
    );
  }
  final String findingId, roomId;
  final String? questionId;
  final int? answerRevision;
  Map<String, Object?> toJson() => {
    'findingId': findingId,
    'roomId': roomId,
    'questionId': questionId,
    'answerRevision': answerRevision,
  };
}

class SafetyDocument {
  SafetyDocument._(this.rooms, this.answers, this.findingRooms);
  factory SafetyDocument.empty() =>
      SafetyDocument._(const [], const [], const []);
  factory SafetyDocument.fromJson(Object? json, HomeSafetyCatalog catalog) {
    final v = V.object(json, {
      'catalogVersion',
      'rooms',
      'answers',
      'findingRooms',
    });
    if (v['catalogVersion'] != homeSafetyCatalogVersion) V.invalid();
    final rooms = V.list(v['rooms'], RoomInstance.fromJson, 32);
    final answers = V.list(v['answers'], SafetyAnswer.fromJson, 512);
    final links = V.list(v['findingRooms'], FindingRoom.fromJson, 100);
    V.unique(rooms.map((r) => r.id));
    V.unique(answers.map((a) => jsonEncode([a.roomId, a.questionId])));
    V.unique(links.map((l) => l.findingId));
    V.unique(
      links
          .where((l) => l.questionId != null)
          .map((l) => jsonEncode([l.roomId, l.questionId])),
    );
    for (final a in answers) {
      final room = rooms.where((r) => r.id == a.roomId).firstOrNull;
      if (room == null ||
          !catalog.question(a.questionId).rooms.contains(room.type)) {
        V.invalid();
      }
    }
    for (final link in links) {
      if (!rooms.any((r) => r.id == link.roomId)) V.invalid();
      if (link.questionId != null) {
        final answer = answers
            .where(
              (a) => a.roomId == link.roomId && a.questionId == link.questionId,
            )
            .firstOrNull;
        if (answer == null || link.answerRevision! > answer.revision) {
          V.invalid();
        }
      }
    }
    return SafetyDocument._(rooms, answers, links);
  }
  final List<RoomInstance> rooms;
  final List<SafetyAnswer> answers;
  final List<FindingRoom> findingRooms;
  SafetyAnswer? answer(String room, String question) => answers
      .where((a) => a.roomId == room && a.questionId == question)
      .firstOrNull;
  FindingRoom? link(String room, String question) => findingRooms
      .where((l) => l.roomId == room && l.questionId == question)
      .firstOrNull;
  Map<String, Object?> toJson() => {
    'catalogVersion': homeSafetyCatalogVersion,
    'rooms': rooms.map((r) => r.toJson()).toList(),
    'answers': answers.map((a) => a.toJson()).toList(),
    'findingRooms': findingRooms.map((l) => l.toJson()).toList(),
  };
}

Map<String, Object?> safetyOperation(Object? json, HomeSafetyCatalog catalog) {
  if (json is! Map) V.invalid();
  final type = json['type'];
  final keys = switch (type) {
    'add_room' => {'type', 'room'},
    'rename_room' => {'type', 'roomId', 'name'},
    'answer' => {'type', 'roomId', 'questionId', 'value'},
    'assign_finding' => {'type', 'roomId', 'findingId'},
    'review_concern' => {
      'type',
      'roomId',
      'questionId',
      'findingId',
      'observation',
      'state',
    },
    _ => <String>{},
  };
  final v = V.object(json, keys);
  if (type == 'add_room') {
    RoomInstance.fromJson(v['room']);
  } else {
    V.id(v['roomId']);
    if (type == 'rename_room') {
      roomName(v['name']);
    }
    if (type == 'answer' || type == 'review_concern') {
      catalog.question(V.id(v['questionId']));
    }
    if (type == 'answer' && !safetyAnswerValues.contains(v['value'])) {
      V.invalid();
    }
    if (type == 'assign_finding' || type == 'review_concern') {
      V.id(v['findingId']);
    }
    if (type == 'review_concern') {
      final observation = v['observation'];
      if (observation is! String ||
          observation.isEmpty ||
          observation.trim() != observation ||
          observation.length > 500 ||
          RegExp(r'[\x00-\x1f]').hasMatch(observation) ||
          !{'confirmed', 'needs_review', 'dismissed'}.contains(v['state'])) {
        V.invalid();
      }
    }
  }
  return Map<String, Object?>.from(jsonDecode(jsonEncode(v)) as Map);
}

class SafetyMutation {
  SafetyMutation._(this._json);
  factory SafetyMutation.fromJson(Object? json, HomeSafetyCatalog catalog) {
    final v = V.object(json, {
      'schemaVersion',
      'caseId',
      'expectedCaseRevision',
      'expectedSafetyRevision',
      'mutationId',
      'operation',
    });
    if (v['schemaVersion'] != '3') V.invalid();
    V.id(v['caseId']);
    V.id(v['mutationId']);
    V.integer(v['expectedCaseRevision']);
    V.integer(v['expectedSafetyRevision'], min: 0);
    return SafetyMutation._({
      ...v,
      'operation': safetyOperation(v['operation'], catalog),
    });
  }
  final Map<String, Object?> _json;
  String get caseId => _json['caseId'] as String;
  String get id => _json['mutationId'] as String;
  int get caseRevision => _json['expectedCaseRevision'] as int;
  int get safetyRevision => _json['expectedSafetyRevision'] as int;
  Map<String, Object?> get operation => Map<String, Object?>.from(
    jsonDecode(jsonEncode(_json['operation'])) as Map,
  );
  Map<String, Object?> toJson() =>
      Map<String, Object?>.from(jsonDecode(jsonEncode(_json)) as Map);
}

class HomeSafetyState {
  HomeSafetyState._(
    this.snapshot,
    this.revision,
    this.document,
    this.history,
    this.acknowledgedMutationId,
    this._record,
  );
  factory HomeSafetyState.fromJson(Object? json, HomeSafetyCatalog catalog) {
    final v = V.object(json, {
      'schemaVersion',
      'case',
      'safety',
      'acknowledgedMutationId',
    });
    final record = V.object(v['safety'], {
      'schemaVersion',
      'caseId',
      'revision',
      'document',
      'history',
    });
    final snapshot = parseCurrentCase(v['case']);
    if (v['schemaVersion'] != '3' ||
        record['schemaVersion'] != '3' ||
        record['caseId'] != snapshot.caseId ||
        utf8.encode(jsonEncode(record)).length > homeSafetyMaximumBytes) {
      V.invalid();
    }
    final revision = V.integer(record['revision'], min: 0, max: 500);
    final doc = SafetyDocument.fromJson(record['document'], catalog);
    final history = V.list(record['history'], (raw) {
      final event = V.object(raw, {
        'mutationId',
        'requestHash',
        'revision',
        'caseRevision',
        'recordedAt',
        'recordedBy',
        'operation',
      });
      V.id(event['mutationId']);
      V.digest(event['requestHash']);
      V.integer(event['revision']);
      V.instant(event['recordedAt']);
      V.integer(event['caseRevision'], max: snapshot.revision);
      V.id(event['recordedBy']);
      safetyOperation(event['operation'], catalog);
      return Map<String, Object?>.unmodifiable(event);
    }, 500);
    V.unique(history.map((e) => e['mutationId'] as String));
    if (history.length != revision ||
        history.indexed.any((e) => e.$2['revision'] != e.$1 + 1) ||
        revision == 0 &&
            safetyHash(doc.toJson()) !=
                safetyHash(SafetyDocument.empty().toJson())) {
      V.invalid();
    }
    final ack = v['acknowledgedMutationId'] == null
        ? null
        : V.id(v['acknowledgedMutationId']);
    if (ack != null && !history.any((e) => e['mutationId'] == ack)) V.invalid();
    return HomeSafetyState._(
      snapshot,
      revision,
      doc,
      history,
      ack,
      Map<String, Object?>.from(jsonDecode(jsonEncode(record)) as Map),
    );
  }
  final CaseSnapshot snapshot;
  final int revision;
  final SafetyDocument document;
  final List<Map<String, Object?>> history;
  final String? acknowledgedMutationId;
  final Map<String, Object?> _record;
  bool acknowledges(SafetyMutation request) =>
      request.caseId == snapshot.caseId &&
      history.any(
        (e) =>
            e['mutationId'] == request.id &&
            e['requestHash'] == safetyHash(request.toJson()),
      );
  Map<String, Object?> toJson() => {
    'schemaVersion': '3',
    'case': snapshot.toJson(),
    'safety': jsonDecode(jsonEncode(_record)),
    'acknowledgedMutationId': acknowledgedMutationId,
  };
}

({SafetyDocument document, CaseSnapshot snapshot}) projectSafety(
  SafetyDocument document,
  CaseSnapshot snapshot,
  Map<String, Object?> raw,
  HomeSafetyCatalog catalog,
) {
  final op = safetyOperation(raw, catalog), data = document.toJson();
  final rooms = (data['rooms'] as List).cast<Map<String, Object?>>();
  final answers = (data['answers'] as List).cast<Map<String, Object?>>();
  final links = (data['findingRooms'] as List).cast<Map<String, Object?>>();
  var next = snapshot;
  if (op['type'] == 'add_room') {
    if (rooms.any((r) => r['id'] == (op['room'] as Map)['id'])) V.invalid();
    rooms.add(Map<String, Object?>.from(op['room'] as Map));
  } else {
    final room = rooms.firstWhere((r) => r['id'] == op['roomId']);
    if (op['type'] == 'rename_room') {
      room['name'] = op['name'];
    } else if (op['type'] == 'assign_finding') {
      if (!snapshot.findings.any((f) => f.id == op['findingId']) ||
          links.any(
            (l) => l['findingId'] == op['findingId'] && l['questionId'] != null,
          )) {
        V.invalid();
      }
      links.removeWhere((l) => l['findingId'] == op['findingId']);
      links.add({
        'findingId': op['findingId'],
        'roomId': op['roomId'],
        'questionId': null,
        'answerRevision': null,
      });
    } else {
      final q = catalog.question(op['questionId'] as String);
      if (!q.rooms.any((r) => r.name == room['type'])) V.invalid();
      final answer = answers
          .where((a) => a['roomId'] == op['roomId'] && a['questionId'] == q.id)
          .firstOrNull;
      if (op['type'] == 'answer') {
        if (answer == null) {
          answers.add({
            'roomId': op['roomId'],
            'questionId': q.id,
            'value': op['value'],
            'revision': 1,
          });
        } else {
          answer['value'] = op['value'];
          answer['revision'] = (answer['revision'] as int) + 1;
        }
      } else {
        final link = links
            .where(
              (l) => l['roomId'] == op['roomId'] && l['questionId'] == q.id,
            )
            .firstOrNull;
        final old = snapshot.findings
            .where((f) => f.id == op['findingId'])
            .firstOrNull;
        if (answer == null ||
            link == null && answer['value'] != q.concernWhen ||
            link != null &&
                (link['findingId'] != op['findingId'] || old == null) ||
            link == null && old != null) {
          V.invalid();
        }
        final finding =
            old?.toJson() ??
            {
              'id': op['findingId'],
              'room': {'bathroom', 'entrance'}.contains(room['type'])
                  ? room['type']
                  : 'other',
              'evidenceIds': <String>[],
              'measurements': <Object>[],
            };
        finding['observation'] = op['observation'];
        finding['reviewState'] = op['state'];
        next = parseWritableCase({
          ...snapshot.toJson(),
          'revision': snapshot.revision + 1,
          'findings': [
            ...snapshot.findings
                .where((f) => f.id != op['findingId'])
                .map((f) => f.toJson()),
            finding,
          ],
        });
        if (link == null) {
          links.add({
            'findingId': op['findingId'],
            'roomId': op['roomId'],
            'questionId': q.id,
            'answerRevision': answer['revision'],
          });
        } else {
          link['answerRevision'] = answer['revision'];
        }
      }
    }
  }
  return (document: SafetyDocument.fromJson(data, catalog), snapshot: next);
}
