import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../shared/models/contracts.dart';

enum ProfileCoverageChoice { plan, none, notSure }

/// Device-only response metadata. Policy facts remain in the strict v1 profile.
/// A missing choice is unanswered; an explicit uncertainty is still a response.
class ProfileResponseState {
  const ProfileResponseState({
    this.coverage,
    this.tenureNotSure = false,
    this.consentNotSure = false,
  });

  final ProfileCoverageChoice? coverage;
  final bool tenureNotSure;
  final bool consentNotSure;

  factory ProfileResponseState.fromJson(Object? value) {
    if (value is! Map ||
        value.keys.any(
          (key) =>
              !{'coverage', 'tenureNotSure', 'consentNotSure'}.contains(key),
        ) ||
        value['tenureNotSure'] is! bool ||
        value['consentNotSure'] is! bool) {
      throw const FormatException('Invalid private profile response state.');
    }
    final choice = value['coverage'];
    if (choice != null &&
        !ProfileCoverageChoice.values.any((item) => item.name == choice)) {
      throw const FormatException('Invalid private coverage response.');
    }
    return ProfileResponseState(
      coverage: choice == null
          ? null
          : ProfileCoverageChoice.values.firstWhere(
              (item) => item.name == choice,
            ),
      tenureNotSure: value['tenureNotSure'] as bool,
      consentNotSure: value['consentNotSure'] as bool,
    );
  }

  Map<String, Object?> toJson() => {
    'coverage': coverage?.name,
    'tenureNotSure': tenureNotSure,
    'consentNotSure': consentNotSure,
  };

  int answeredCount(CaseProfile profile) =>
      profile.toJson().values.where((value) => value != null).length +
      (profile.healthPlan == null && coverage != null ? 1 : 0) +
      (profile.tenure == null && tenureNotSure ? 1 : 0) +
      (profile.ownerConsentReported == null && consentNotSure ? 1 : 0);

  /// A known answer always wins over stale or inconsistent uncertainty metadata.
  ProfileResponseState forProfile(CaseProfile profile) => ProfileResponseState(
    coverage:
        profile.healthPlan != null && coverage == ProfileCoverageChoice.notSure
        ? null
        : coverage,
    tenureNotSure: profile.tenure == null && tenureNotSure,
    consentNotSure: profile.ownerConsentReported == null && consentNotSure,
  );

  static String fingerprint(CaseProfile profile) {
    final entries = profile.toJson().entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return sha256
        .convert(utf8.encode(jsonEncode(Map.fromEntries(entries))))
        .toString();
  }
}
