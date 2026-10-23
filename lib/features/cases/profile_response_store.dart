import 'package:flutter/foundation.dart';

import '../../shared/models/contracts.dart';
import '../../shared/services/local_private_store.dart';
import 'profile_response_state.dart';

/// Account-encrypted metadata deliberately bound to the entire saved profile.
/// A remote or external profile change invalidates local response markers rather
/// than silently transferring an old uncertainty to a different set of answers.
class ProfileResponseStore extends ChangeNotifier {
  ProfileResponseStore({
    required this.store,
    required this.isCurrentCase,
    this.scopeKey,
  });

  final LocalPrivateStore store;
  final bool Function(String caseId) isCurrentCase;
  final Object? Function()? scopeKey;
  final _cache =
      <
        String,
        ({Object? scope, String fingerprint, ProfileResponseState state})
      >{};
  final _operations = <String, int>{};
  bool _disposed = false;

  bool _current(String caseId, Object? scope) =>
      !_disposed && isCurrentCase(caseId) && scopeKey?.call() == scope;

  void _requireCurrent(String caseId, Object? scope) {
    if (!_current(caseId, scope)) {
      throw StateError('The selected private profile changed.');
    }
  }

  ProfileResponseState currentFor(String caseId, CaseProfile profile) {
    if (_disposed || !isCurrentCase(caseId)) {
      return const ProfileResponseState();
    }
    final cached = _cache[caseId];
    return cached?.scope == scopeKey?.call() &&
            cached?.fingerprint == ProfileResponseState.fingerprint(profile)
        ? cached!.state
        : const ProfileResponseState();
  }

  Future<ProfileResponseState> read(String caseId, CaseProfile profile) async {
    final scope = scopeKey?.call();
    _requireCurrent(caseId, scope);
    final operation = (_operations[caseId] ?? 0) + 1;
    _operations[caseId] = operation;
    final fingerprint = ProfileResponseState.fingerprint(profile);
    try {
      final saved = await store.readJson('profile-response.$caseId');
      _requireCurrent(caseId, scope);
      var state = const ProfileResponseState();
      if (saved != null) {
        if (saved['version'] != 1 ||
            saved['caseId'] != caseId ||
            saved['profileFingerprint'] is! String ||
            saved.keys.any(
              (key) => !{
                'version',
                'caseId',
                'profileFingerprint',
                'responses',
              }.contains(key),
            )) {
          throw const FormatException('Invalid private profile responses.');
        }
        final parsed = ProfileResponseState.fromJson(saved['responses']);
        if (saved['profileFingerprint'] == fingerprint) {
          state = parsed.forProfile(profile);
        }
      }
      // An earlier disk read must not replace a newer read or successful save.
      if (_operations[caseId] == operation) {
        _cache[caseId] = (scope: scope, fingerprint: fingerprint, state: state);
        notifyListeners();
      }
      return state;
    } catch (_) {
      if (_current(caseId, scope) && _operations[caseId] == operation) {
        _cache.remove(caseId);
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<void> write(
    String caseId,
    CaseProfile profile,
    ProfileResponseState responses,
  ) async {
    final scope = scopeKey?.call();
    _requireCurrent(caseId, scope);
    final operation = (_operations[caseId] ?? 0) + 1;
    _operations[caseId] = operation;
    final fingerprint = ProfileResponseState.fingerprint(profile);
    final state = responses.forProfile(profile);
    await store.writeJson('profile-response.$caseId', {
      'version': 1,
      'caseId': caseId,
      'profileFingerprint': fingerprint,
      'responses': state.toJson(),
    });
    _requireCurrent(caseId, scope);
    if (_operations[caseId] == operation) {
      _cache[caseId] = (scope: scope, fingerprint: fingerprint, state: state);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cache.clear();
    _operations.clear();
    super.dispose();
  }
}
