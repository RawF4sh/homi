import 'package:flutter/material.dart';
import '../../app/live_app.dart';
import '../../shared/models/account_deletion.dart';
import '../../shared/services/io_matching_transport.dart';
import '../../shared/services/lifecycle_api_client.dart';
import '../../shared/services/local_private_store.dart';
import '../../shared/services/matching_api_client.dart';

class AccountSettingsScreen extends StatefulWidget {
  const AccountSettingsScreen({super.key, required this.services});
  final AppServices services;
  @override
  State<AccountSettingsScreen> createState() => _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends State<AccountSettingsScreen> {
  bool _busy = true, _caseDeletionPending = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _restoreDeletion();
  }

  Future<void> _restoreDeletion() async {
    final id = widget.services.coordinator.snapshot?.caseId;
    if (id == null) {
      _busy = false;
      return;
    }
    try {
      final value = await widget.services.store.readJson('case-delete.$id');
      if (mounted) setState(() => _caseDeletionPending = value != null);
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkCaseDeletion() async {
    setState(() => _busy = true);
    final c = widget.services.coordinator;
    final id = c.snapshot!.caseId;
    try {
      final remote = await widget.services.answers.reloadCase(
        id,
        currentCase: c.currentCase,
      );
      await c.adoptRemoteSnapshot(remote);
      await widget.services.store.delete('case-delete.$id');
      if (mounted) {
        setState(() {
          _caseDeletionPending = false;
          _error =
              'The case still exists. Review it before choosing Delete again.';
        });
      }
    } on MatchingApiException catch (error) {
      if (error.code == 'CASE_NOT_FOUND') {
        await c.clearSelected();
        if (mounted) {
          setState(() {
            _caseDeletionPending = false;
            _error = 'The case is deleted. Its local copies were removed.';
          });
        }
      } else if (mounted) {
        setState(() => _error = safeOperationMessage(error));
      }
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  LifecycleApiClient get _client => widget.services.lifecycle;
  Future<bool> _confirm(String title, String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> _signOut() async {
    if (!await _confirm(
      'Sign out and clear this device?',
      'Local drafts and staged photos will be removed. Save any work you want to keep online first.',
    )) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.services.signOut();
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteCase() async {
    final c = widget.services.coordinator;
    if (c.snapshot == null) return;
    if (!await _confirm(
      'Delete selected case?',
      'This removes its saved case, photos, answers and generated drafts. Copies already shared outside the app cannot be removed.',
    )) {
      return;
    }
    setState(() => _busy = true);
    try {
      await c.serialize(() async {
        final catalog = await widget.services.exports.listEvidence(
          c.currentCase(),
          currentCase: c.currentCase,
          currentCatalog: () => null,
        );
        await widget.services.store
            .writeJson('case-delete.${c.currentCase().caseId}', {
              'snapshot': c.currentCase().toJson(),
              'catalogRevision': catalog.catalogRevision,
            });
        if (mounted) setState(() => _caseDeletionPending = true);
        await _client.deleteCase(
          c.currentCase(),
          expectedCatalogRevision: catalog.catalogRevision,
          isCurrent: () => mounted && c.isCurrent,
        );
      });
      await c.clearSelected();
      if (mounted) {
        setState(() {
          _caseDeletionPending = false;
          _error = 'Selected case deleted.';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeLocalDraft() async {
    if (!await _confirm(
      'Remove this local draft?',
      'This removes the selected draft and its staged photos from this device.',
    )) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.services.coordinator.clearSelected();
      if (mounted) setState(() => _error = 'Local draft removed.');
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAccount() async {
    setState(() => _busy = true);
    try {
      final c = widget.services.coordinator;
      final owner = widget.services.session.userId;
      final epoch = widget.services.session.epoch;
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _ReauthenticateDialog(services: widget.services),
      );
      if (confirmed != true ||
          !mounted ||
          !c.isCurrent ||
          widget.services.session.userId != owner ||
          widget.services.session.epoch != epoch) {
        return;
      }
      final preview = await _client.prepareAccountDeletion(
        isCurrent: () => mounted && c.isCurrent,
      );
      if (!mounted) return;
      if (!await _confirm(
        'Delete this account?',
        'This removes ${preview.counts.cases} cases and ${preview.counts.evidence} photos. Application data is removed first; account-provider cleanup may complete later. This cannot be undone.',
      )) {
        return;
      }
      final secrets = DeviceSecretStore();
      await secrets.write(
        'sah.deletion.${widget.services.config.apiOrigin.host}',
        preview.deletionToken,
      );
      await secrets.write(
        'sah.deletion-owner.${widget.services.config.apiOrigin.host}',
        widget.services.store.accountId,
      );
      final state = await _client.confirmAccountDeletion(
        preview,
        isCurrent: () => mounted && c.isCurrent,
      );
      if (state.applicationDataDeleted) {
        await widget.services.signOut();
      } else if (mounted) {
        setState(
          () => _error =
              'Deletion is not complete. Check the stored deletion receipt.',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Account and privacy')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Private team beta · Use fictional resident records.'),
          const SizedBox(height: 12),
          const Text(
            'Drafts on this device are encrypted and excluded from device backups. Signing out removes local work. A shared PDF is controlled by the recipient.',
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Text(_error!),
          OutlinedButton(
            onPressed: _busy ? null : _signOut,
            child: const Text('Sign out and clear local data'),
          ),
          OutlinedButton(
            onPressed:
                _busy ||
                    _caseDeletionPending ||
                    widget.services.coordinator.snapshot == null
                ? null
                : _deleteCase,
            child: const Text('Delete selected case'),
          ),
          if (widget.services.coordinator.snapshot == null &&
              widget.services.coordinator.draft != null)
            OutlinedButton(
              onPressed:
                  _busy ||
                      widget.services.coordinator.uncertain ||
                      widget.services.coordinator.conflict
                  ? null
                  : _removeLocalDraft,
              child: const Text('Remove selected local draft'),
            ),
          if (_caseDeletionPending)
            OutlinedButton(
              onPressed: _busy ? null : _checkCaseDeletion,
              child: const Text('Check whether case deletion completed'),
            ),
          TextButton(
            onPressed: _busy ? null : _deleteAccount,
            child: const Text('Delete account and application data'),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => DeletionReceiptScreen(
                        config: widget.services.config,
                        services: widget.services,
                      ),
                    ),
                  ),
            child: const Text('Check pending account deletion'),
          ),
        ],
      ),
    ),
  );
}

class _ReauthenticateDialog extends StatefulWidget {
  const _ReauthenticateDialog({required this.services});
  final AppServices services;
  @override
  State<_ReauthenticateDialog> createState() => _ReauthenticateDialogState();
}

class _ReauthenticateDialogState extends State<_ReauthenticateDialog> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  Future<void> _confirmPassword() async {
    if (_busy || _password.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.services.session.reauthenticate(_password.text);
      if (!mounted) return;
      _password.clear();
      setState(() => _busy = false);
      Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        _password.clear();
        setState(
          () => _error =
              'Password confirmation failed. Check your password and connection. Nothing was deleted.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('Confirm your password'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Confirm the current account password before reviewing account deletion.',
            ),
            TextField(
              controller: _password,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: 'Current password'),
              onSubmitted: (_) => _confirmPassword(),
            ),
            if (_error != null) Text(_error!),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _confirmPassword,
          child: Text(_busy ? 'Confirming…' : 'Confirm password'),
        ),
      ],
    ),
  );
}

class DeletionReceiptScreen extends StatefulWidget {
  const DeletionReceiptScreen({super.key, required this.config, this.services});
  final LiveAppConfig config;
  final AppServices? services;
  @override
  State<DeletionReceiptScreen> createState() => _DeletionReceiptScreenState();
}

class _DeletionReceiptScreenState extends State<DeletionReceiptScreen> {
  bool _busy = false;
  String? _message;
  AccountDeletionState? _state;
  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() => _busy = true);
    try {
      final token = await DeviceSecretStore().read(
        'sah.deletion.${widget.config.apiOrigin.host}',
      );
      if (token == null) {
        if (mounted) {
          setState(
            () => _message =
                'No account deletion receipt is stored on this device.',
          );
        }
        return;
      }
      final client = LifecycleApiClient(
        apiBaseUrl: widget.config.apiOrigin,
        tokenProvider: () async => null,
        transport: IoMatchingTransport(),
      );
      final state = await client.readAccountDeletionStatus(
        token,
        isCurrent: () => mounted,
      );
      if (mounted) setState(() => _state = state);
      final services = widget.services;
      final owner = await DeviceSecretStore().read(
        'sah.deletion-owner.${widget.config.apiOrigin.host}',
      );
      if (state.applicationDataDeleted &&
          services != null &&
          services.session.userId == owner) {
        await services.signOut();
      }
    } catch (error) {
      if (mounted) setState(() => _message = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Account deletion')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_message != null) Text(_message!),
          if (_state != null)
            Text(switch (_state!.status) {
              'complete' =>
                'Application data and the provider account were deleted.',
              'auth_pending' =>
                'Application data is deleted. Provider account cleanup is still pending.',
              _ =>
                'Deletion is awaiting confirmation; data has not been deleted.',
            }),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _busy ? null : _check,
            child: const Text('Refresh status'),
          ),
        ],
      ),
    ),
  );
}
