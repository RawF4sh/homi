import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'local_private_store.dart';

final _secureStorageTails = <String, Future<void>>{};
Future<T> _secureStorageOperation<T>(
  String namespace,
  Future<T> Function() action,
) {
  final work = (_secureStorageTails[namespace] ?? Future<void>.value()).then(
    (_) => action(),
  );
  _secureStorageTails[namespace] = work.then<void>(
    (_) {},
    onError: (Object _, StackTrace stack) {},
  );
  return work;
}

class SecureSessionStorage extends LocalStorage {
  SecureSessionStorage(this.secrets, this.namespace);
  final SecretValueStore secrets;
  final String namespace;
  String get _key => '$namespace.session';
  @override
  Future<void> initialize() async {}
  @override
  Future<String?> accessToken() =>
      _secureStorageOperation(namespace, () => secrets.read(_key));
  @override
  Future<bool> hasAccessToken() async => await accessToken() != null;
  @override
  Future<void> persistSession(String persistSessionString) =>
      _secureStorageOperation(
        namespace,
        () => secrets.write(_key, persistSessionString),
      );
  @override
  Future<void> removePersistedSession() =>
      _secureStorageOperation(namespace, () => secrets.delete(_key));
}

class SecurePkceStorage extends GotrueAsyncStorage {
  SecurePkceStorage(this.secrets, this.namespace);
  final SecretValueStore secrets;
  final String namespace;
  String get _index => '$namespace.pkce-index';
  Future<List<String>> _keys() async {
    final encoded = await secrets.read(_index);
    return encoded == null
        ? []
        : List<String>.from(jsonDecode(encoded) as List);
  }

  @override
  Future<String?> getItem({required String key}) => _secureStorageOperation(
    namespace,
    () => secrets.read('$namespace.pkce.$key'),
  );
  @override
  Future<void> setItem({required String key, required String value}) =>
      _secureStorageOperation(namespace, () async {
        final keys = await _keys();
        if (!keys.contains(key)) keys.add(key);
        await secrets.write(_index, jsonEncode(keys));
        await secrets.write('$namespace.pkce.$key', value);
      });

  @override
  Future<void> removeItem({required String key}) =>
      _secureStorageOperation(namespace, () async {
        await secrets.delete('$namespace.pkce.$key');
        final keys = await _keys();
        keys.remove(key);
        if (keys.isEmpty) {
          await secrets.delete(_index);
        } else {
          await secrets.write(_index, jsonEncode(keys));
        }
      });

  Future<void> clear() => _secureStorageOperation(namespace, () async {
    for (final key in await _keys()) {
      await secrets.delete('$namespace.pkce.$key');
    }
    await secrets.delete(_index);
  });
}

abstract class SessionService extends ChangeNotifier {
  String? get userId;
  int get epoch;
  bool get recoveryRequired;
  Future<String?> accessToken();
  Future<void> signIn(String email, String password);
  Future<void> reauthenticate(String password);
  Future<void> signOut();
  Future<void> requestRecovery(String email);
  Future<void> updatePassword(String password);
}

class SupabaseSessionService extends SessionService {
  SupabaseSessionService(
    this.client, {
    required this.callback,
    required this.emailDeliveryEnabled,
    required this.reauthenticationClient,
  }) {
    _userId = client.auth.currentUser?.id;
    _subscription = client.auth.onAuthStateChange.listen(
      (change) {
        final next = change.session?.user.id;
        if (next != _userId || change.event == AuthChangeEvent.signedOut) {
          _epoch++;
          _confirmedToken = null;
        }
        _userId = next;
        if (change.event == AuthChangeEvent.passwordRecovery) _recovery = true;
        if (next == null) _recovery = false;
        notifyListeners();
      },
      onError: (Object _) {
        notifyListeners();
      },
    );
  }
  final SupabaseClient client;
  final Uri callback;
  final bool emailDeliveryEnabled;
  final GoTrueClient Function() reauthenticationClient;
  ({String token, DateTime expires})? _confirmedToken;
  bool _disposed = false;
  late final StreamSubscription<AuthState> _subscription;
  String? _userId;
  int _epoch = 0;
  bool _recovery = false;
  @override
  String? get userId => _userId;
  @override
  int get epoch => _epoch;
  @override
  bool get recoveryRequired => _recovery;
  @override
  Future<String?> accessToken() async {
    final owner = _userId;
    final generation = _epoch;
    if (_disposed || owner == null) return null;
    final confirmed = _confirmedToken;
    if (confirmed != null && DateTime.now().isBefore(confirmed.expires)) {
      return confirmed.token;
    }
    _confirmedToken = null;
    final session = client.auth.currentSession;
    if (session == null) return null;
    if (session.isExpired) await client.auth.refreshSession();
    if (_disposed || _epoch != generation || _userId != owner) return null;
    return client.auth.currentSession?.accessToken;
  }

  @override
  Future<void> signIn(String email, String password) async {
    await client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
  }

  @override
  Future<void> reauthenticate(String password) async {
    final owner = _userId;
    final generation = _epoch;
    final email = client.auth.currentUser?.email;
    if (owner == null || email == null || password.isEmpty) {
      throw StateError('The current account must sign in again.');
    }
    final verifier = reauthenticationClient();
    try {
      final result = await verifier
          .signInWithPassword(email: email, password: password)
          .timeout(const Duration(seconds: 15));
      final verified = result.session;
      if (_disposed ||
          _epoch != generation ||
          _userId != owner ||
          verified == null ||
          verified.user.id != owner ||
          verified.expiresAt == null ||
          verified.isExpired) {
        throw StateError('The account changed during password confirmation.');
      }
      final expiry = DateTime.fromMillisecondsSinceEpoch(
        verified.expiresAt! * 1000,
      );
      final confirmationLimit = DateTime.now().add(const Duration(minutes: 9));
      _confirmedToken = (
        token: verified.accessToken,
        expires: expiry.isBefore(confirmationLimit)
            ? expiry
            : confirmationLimit,
      );
    } finally {
      verifier.dispose();
    }
  }

  @override
  Future<void> signOut() async {
    _epoch++;
    _confirmedToken = null;
    _userId = null;
    _recovery = false;
    notifyListeners();
    await client.auth.signOut(scope: SignOutScope.local);
  }

  @override
  Future<void> requestRecovery(String email) async {
    if (!emailDeliveryEnabled) {
      throw StateError('Email recovery has not been enabled for this beta.');
    }
    await client.auth.resetPasswordForEmail(
      email.trim(),
      redirectTo: callback.toString(),
    );
  }

  @override
  Future<void> updatePassword(String password) async {
    if (!_recovery) {
      throw StateError('Open a valid password recovery link first.');
    }
    await client.auth.updateUser(UserAttributes(password: password));
    _recovery = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _confirmedToken = null;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
