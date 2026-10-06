import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/sharing.dart';
import '../../support/contract_schema.dart';

List<Map<String, Object?>> sharingFixtures() =>
    (jsonDecode(
              File(
                'contracts/v3/fixtures/permission-sharing.json',
              ).readAsStringSync(),
            )
            as List)
        .cast<Map<String, Object?>>();
Map<String, Object?> sharedFixture() =>
    sharingFixtures().firstWhere(
          (v) => v['route'] == 'read-shared-case',
        )['response']
        as Map<String, Object?>;
void main() {
  test(
    'all ten sharing requests and responses match strict v3 schema and Dart contracts',
    () {
      final schema =
          jsonDecode(
                File(
                  'contracts/v3/permission-sharing.schema.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      for (final fixture in sharingFixtures()) {
        final route = fixture['route']! as String;
        for (final side in ['request', 'response']) {
          expect(
            acceptsContract(
              fixture[side],
              schema[r'$defs']['$route-$side'],
              {},
              schema,
            ),
            isTrue,
            reason: '$route $side',
          );
        }
        SharingResponse.fromJson(fixture['response'], route);
      }
    },
  );
  test(
    'unknown profile, photo, PDF fields and out-of-scope findings fail the Dart boundary',
    () {
      final raw = sharedFixture(),
          projection = Map<String, Object?>.from(raw['projection']! as Map);
      for (final key in ['profile', 'photos', 'pdfs', 'annualIncomeUsd']) {
        expect(
          () => SharingResponse.fromJson({
            ...raw,
            'projection': {...projection, key: 'private'},
          }, 'read-shared-case'),
          throwsFormatException,
        );
      }
      final member = Map<String, Object?>.from(raw['membership']! as Map);
      expect(
        () => SharingResponse.fromJson({
          ...raw,
          'membership': {
            ...member,
            'scope': {
              'findingIds': [],
              'programIds': [],
              'allowHelperNotes': true,
            },
          },
        }, 'read-shared-case'),
        throwsFormatException,
      );
      expect(
        () => CaseMembership.fromJson({...member, 'role': 'viewer'}),
        throwsFormatException,
      );
    },
  );
}
