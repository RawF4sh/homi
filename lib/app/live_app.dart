import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as hashing;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../features/auth/login_screen.dart';
import '../features/cases/case_home_screen.dart';
import '../features/settings/account_settings_screen.dart';
import '../shared/services/annotated_export_api_client.dart';
import '../shared/services/evidence_annotations_api_client.dart';
import '../shared/services/case_coordinator.dart';
import '../shared/services/case_discovery_api_client.dart';
import '../shared/services/case_evidence_api_client.dart';
import '../shared/services/draft_export_api_client.dart';
import '../shared/services/form_answers_api_client.dart';
import '../shared/services/io_matching_transport.dart';
import '../shared/services/local_private_store.dart';
import '../shared/services/lifecycle_api_client.dart';
import '../shared/services/matching_api_client.dart';
import '../shared/services/packet_api_client.dart';
import '../shared/services/program_intake_api_client.dart';
import '../shared/services/request_tracking_api_client.dart';
import '../shared/services/session_service.dart';

class LiveAppConfig {
  LiveAppConfig({
    required this.apiOrigin,
    required this.supabaseUrl,
    required this.publishableKey,
    this.emailDeliveryEnabled = false,
  }) {
    for (final uri in [apiOrigin, supabaseUrl]) {
      if (uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          (uri.path.isNotEmpty && uri.path != '/')) {
        throw const FormatException(
          'Live configuration requires HTTPS origins.',
        );
      }
    }
    if (publishableKey.isEmpty) {
      throw const FormatException('Supabase publishable key is missing.');
    }
  }
  final Uri apiOrigin, supabaseUrl;
  final String publishableKey;
  final bool emailDeliveryEnabled;
  Uri get callback => Uri.parse('safeathome://auth/callback');
  bool acceptsCallback(Uri uri) =>
      uri.scheme == callback.scheme &&
      uri.host == callback.host &&
      uri.path == callback.path &&
      uri.userInfo.isEmpty &&
      !uri.hasPort &&
      uri.fragment.isEmpty &&
      !uri.queryParameters.containsKey('access_token') &&
      !uri.queryParameters.containsKey('refresh_token');
  static LiveAppConfig fromEnvironment() => LiveAppConfig(
    apiOrigin: Uri.parse(const String.fromEnvironment('SAH_API_URL')),
    supabaseUrl: Uri.parse(const String.fromEnvironment('SUPABASE_URL')),
    publishableKey: const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
    emailDeliveryEnabled: const bool.fromEnvironment(
      'SAH_EMAIL_DELIVERY_ENABLED',
    ),
  );
}

class AppServices {
  AppServices({
    required this.config,
    required this.session,
    required this.store,
    MatchingTransport? transport,
    this.pdfPreviewBuilder,
  }) {
    transport ??= IoMatchingTransport();
    Future<String?> token() async {
      final epoch = session.epoch;
      final value = await session.accessToken();
      if (session.epoch != epoch || session.userId != store.accountId) {
        throw MatchingApiException.forCode('UNAUTHENTICATED');
      }
      return value;
    }

    Uri endpoint(String name) => config.apiOrigin.resolve('/v1/$name');
    cases = CaseEvidenceApiClient(
      createCaseEndpoint: endpoint('create-case'),
      saveCaseEndpoint: endpoint('save-case'),
      caseEndpoint: endpoint('read-case'),
      uploadEvidenceEndpoint: endpoint('upload-evidence'),
      deleteEvidenceEndpoint: endpoint('delete-evidence'),
      tokenProvider: token,
      transport: transport,
    );
    discovery = CaseDiscoveryApiClient(
      listCasesEndpoint: endpoint('list-cases'),
      caseEndpoint: endpoint('read-case'),
      tokenProvider: token,
      transport: transport,
    );
    exports = DraftExportApiClient(
      evidenceEndpoint: endpoint('list-evidence'),
      evidenceDownloadEndpoint: endpoint('download-evidence'),
      exportEndpoint: endpoint('create-draft-export'),
      exportDownloadEndpoint: endpoint('download-draft-export'),
      tokenProvider: token,
      transport: transport,
    );
    lifecycle = LifecycleApiClient(
      apiBaseUrl: config.apiOrigin,
      tokenProvider: token,
      transport: transport,
    );
    intake = ProgramIntakeApiClient(
      baseUri: config.apiOrigin,
      tokenProvider: token,
      transport: transport,
    );
    annotatedExports = AnnotatedExportApiClient(
      baseUri: config.apiOrigin,
      tokenProvider: token,
      transport: transport,
    );
    annotations = EvidenceAnnotationsApiClient(
      baseUri: config.apiOrigin,
      tokenProvider: token,
      transport: transport,
    );
    matching = MatchingApiClient(
      endpoint: endpoint('match-case'),
      tokenProvider: token,
      transport: transport,
    );
    packets = PacketApiClient(
      endpoint: endpoint('prepare-packet'),
      tokenProvider: token,
      transport: transport,
    );
    answers = FormAnswersApiClient(
      protocolVersion: '2',
      readEndpoint: config.apiOrigin.resolve('/v2/read-form-answers'),
      saveEndpoint: config.apiOrigin.resolve('/v2/save-form-answers'),
      caseEndpoint: endpoint('read-case'),
      tokenProvider: token,
      transport: transport,
    );
    history = RequestTrackingApiClient(
      readHistoryEndpoint: endpoint('read-request-history'),
      appendUpdateEndpoint: endpoint('append-request-update'),
      tokenProvider: token,
      transport: transport,
    );
    coordinator = CaseCoordinator(
      session: session,
      store: store,
      cases: cases,
      discovery: discovery,
    );
  }
  final LiveAppConfig config;
  final SessionService session;
  final LocalPrivateStore store;

  final Widget Function(Uint8List bytes)? pdfPreviewBuilder;
  late final CaseEvidenceApiClient cases;
  late final CaseDiscoveryApiClient discovery;
  late final DraftExportApiClient exports;
  late final AnnotatedExportApiClient annotatedExports;
  late final ProgramIntakeApiClient intake;
  late final LifecycleApiClient lifecycle;
  late final EvidenceAnnotationsApiClient annotations;
  late final MatchingApiClient matching;
  late final PacketApiClient packets;
  late final FormAnswersApiClient answers;
  late final RequestTrackingApiClient history;
  late final CaseCoordinator coordinator;
  Future<void> signOut() async {
    try {
      await session.signOut();
    } finally {
      try {
        final secrets = DeviceSecretStore();
        final namespace = 'sah.auth.${config.supabaseUrl.host}';
        try {
          await SecureSessionStorage(
            secrets,
            namespace,
          ).removePersistedSession();
        } finally {
          await SecurePkceStorage(secrets, namespace).clear();
        }
      } finally {
        try {
          await store.clear();
        } finally {
          await _clearTransientMedia();
        }
      }
    }
  }

  void dispose() => coordinator.dispose();
}

Future<void> _clearTransientMedia() async {
  const channel = MethodChannel('safe_at_home/private_media');
  try {
    await channel.invokeMethod<void>('clearTemporaryMedia');
  } finally {
    final root = await channel.invokeMethod<String>('privateRootDirectory');
    if (root != null) {
      final shares = Directory('$root/temporary-shares');
      if (await shares.exists()) await shares.delete(recursive: true);
    }
  }
}

class LiveAppBootstrap extends StatefulWidget {
  const LiveAppBootstrap({super.key});
  @override
  State<LiveAppBootstrap> createState() => _LiveAppBootstrapState();
}

class _LiveAppBootstrapState extends State<LiveAppBootstrap> {
  late final Future<(LiveAppConfig, SessionService)> _ready = _initialize();
  Future<(LiveAppConfig, SessionService)> _initialize() async {
    final config = LiveAppConfig.fromEnvironment();
    final secrets = DeviceSecretStore();
    final namespace = 'sah.auth.${config.supabaseUrl.host}';
    const channel = MethodChannel('safe_at_home/private_media');
    final root = await channel.invokeMethod<String>('privateRootDirectory');
    if (root == null) throw StateError('Private storage unavailable.');
    await Directory(root).create(recursive: true);
    await channel.invokeMethod('preparePrivateDirectory', {'path': root});
    final marker = File('$root/installation-v1');
    if (!await marker.exists()) {
      await SecureSessionStorage(secrets, namespace).removePersistedSession();
      await SecurePkceStorage(secrets, namespace).clear();
      await marker.writeAsString('1', flush: true);
    }
    await _clearTransientMedia();
    await Supabase.initialize(
      url: config.supabaseUrl.toString(),
      publishableKey: config.publishableKey,
      debug: false,
      authOptions: FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
        localStorage: SecureSessionStorage(secrets, namespace),
        pkceAsyncStorage: SecurePkceStorage(secrets, namespace),
        detectSessionInUriPredicate: config.acceptsCallback,
      ),
    );
    return (
      config,
      SupabaseSessionService(
        Supabase.instance.client,
        callback: config.callback,
        emailDeliveryEnabled: config.emailDeliveryEnabled,
        reauthenticationClient: () => GoTrueClient(
          url: '${config.supabaseUrl}/auth/v1',
          headers: {'apikey': config.publishableKey},
          autoRefreshToken: false,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _ready,
    builder: (context, state) {
      if (state.hasData) {
        return _LiveSessionHost(
          config: state.data!.$1,
          session: state.data!.$2,
        );
      }
      return MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: state.hasError
                    ? const Text(
                        'Live setup could not be opened. Check the HTTPS API and Supabase build configuration, then restart. No case has been opened.',
                      )
                    : const CircularProgressIndicator(
                        semanticsLabel: 'Opening secure session',
                      ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _LiveSessionHost extends StatefulWidget {
  const _LiveSessionHost({required this.config, required this.session});
  final LiveAppConfig config;
  final SessionService session;
  @override
  State<_LiveSessionHost> createState() => _LiveSessionHostState();
}

class _LiveSessionHostState extends State<_LiveSessionHost>
    with WidgetsBindingObserver {
  bool _privateCover = false;
  String? _owner;
  int _ownerEpoch = -1, _openGeneration = 0;
  Future<AppServices>? _services;
  AppServices? _opened;
  Future<void> _cleanup = Future.value();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.session.addListener(_changed);
    _changed();
  }

  void _changed() {
    final owner = widget.session.userId;
    final epoch = widget.session.epoch;
    if (owner != _owner || epoch != _ownerEpoch) {
      _ownerEpoch = epoch;
      _openGeneration++;
      final previous = _opened;
      if (previous != null) {
        _cleanup = _cleanup.then((_) => previous.store.close());
        unawaited(_cleanup.catchError((Object _) {}));
      }
      _opened?.dispose();
      _opened = null;
      _owner = owner;
      _services = owner == null ? null : _open(owner, epoch, _openGeneration);
    }
    if (mounted) setState(() {});
  }

  Future<AppServices> _open(String owner, int epoch, int generation) async {
    bool current() =>
        mounted &&
        widget.session.userId == owner &&
        widget.session.epoch == epoch &&
        _openGeneration == generation;
    await _cleanup;
    if (!current()) throw MatchingApiException.forCode('STALE_RESPONSE');
    const channel = MethodChannel('safe_at_home/private_media');
    final root = await channel.invokeMethod<String>('privateRootDirectory');
    if (root == null) throw StateError('Private storage unavailable.');
    final directory = Directory(
      '$root/${hashing.sha256.convert(utf8.encode(owner))}',
    );
    await directory.create(recursive: true);
    await channel.invokeMethod('preparePrivateDirectory', {
      'path': directory.path,
    });
    final store = LocalPrivateStore(
      directory: directory,
      accountId: owner,
      secrets: DeviceSecretStore(),
    );
    if (!current()) {
      await store.close();
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
    return _opened = AppServices(
      config: widget.config,
      session: widget.session,
      store: store,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) {
      setState(() => _privateCover = state != AppLifecycleState.resumed);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.session.removeListener(_changed);
    _openGeneration++;
    if (_opened != null) unawaited(_opened!.store.close());
    _opened?.dispose();
    widget.session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    key: ValueKey(widget.session.epoch),
    title: 'Safe at Home',
    debugShowCheckedModeBanner: false,
    builder: (context, child) => Stack(
      children: [
        ?child,
        if (_privateCover)
          const Positioned.fill(
            child: ColoredBox(
              color: Color(0xFFF7F9F7),
              child: Center(child: Text('Safe at Home')),
            ),
          ),
      ],
    ),
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF176456)),
      useMaterial3: true,
    ),
    home: widget.session.userId == null || widget.session.recoveryRequired
        ? LoginScreen(
            session: widget.session,
            emailDeliveryEnabled: widget.config.emailDeliveryEnabled,
            deletionStatusScreen: DeletionReceiptScreen(config: widget.config),
          )
        : FutureBuilder(
            future: _services,
            builder: (context, state) {
              if (state.hasData) return CaseHomeScreen(services: state.data!);
              return Scaffold(
                appBar: AppBar(title: const Text('Private storage')),
                body: Center(
                  child: state.hasError
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Padding(
                              padding: EdgeInsets.all(24),
                              child: Text(
                                'Private storage could not be opened. Unlock your phone and restart the app.',
                              ),
                            ),
                            TextButton(
                              onPressed: () => widget.session.signOut(),
                              child: const Text('Sign out'),
                            ),
                          ],
                        )
                      : const CircularProgressIndicator(),
                ),
              );
            },
          ),
  );
}

String safeOperationMessage(Object error) => error is MatchingApiException
    ? error.message
    : 'This action could not be completed. Your saved data has not been replaced. Please try again or check saved state.';
Future<void> showOperationError(BuildContext context, Object error) async {
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(safeOperationMessage(error))));
}
