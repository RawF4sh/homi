import 'package:flutter/material.dart';
import '../../app/live_app.dart';
import '../../shared/models/case_list.dart';
import '../settings/account_settings_screen.dart';
import 'case_workspace_screen.dart';

class CaseHomeScreen extends StatefulWidget {
  const CaseHomeScreen({super.key, required this.services});
  final AppServices services;
  @override
  State<CaseHomeScreen> createState() => _CaseHomeScreenState();
}

class _CaseHomeScreenState extends State<CaseHomeScreen> {
  final _cases = <CaseSummary>[];
  List<String> _local = [];
  String? _cursor, _error;
  bool _loading = false, _loaded = false;
  int _request = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (_loading) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final local = await widget.services.coordinator.localCaseIds();
      final page = await widget.services.discovery.listCases(
        afterCaseId: more ? _cursor : null,
        isCurrent: () =>
            mounted &&
            request == _request &&
            widget.services.coordinator.isCurrent,
      );
      if (!mounted) return;
      setState(() {
        if (!more) _cases.clear();
        for (final item in page.cases) {
          if (!_cases.any((c) => c.caseId == item.caseId)) _cases.add(item);
        }
        _cursor = page.nextAfterCaseId;
        _local = local;
        _loaded = true;
      });
    } catch (error) {
      if (mounted) {
        try {
          _local = await widget.services.coordinator.localCaseIds();
        } catch (_) {}
        if (mounted) setState(() => _error = safeOperationMessage(error));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(Future<void> Function() action) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      await action();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CaseWorkspaceScreen(services: widget.services),
        ),
      );
    } catch (error) {
      if (mounted) await showOperationError(context, error);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        _load();
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Your cases'),
      actions: [
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AccountSettingsScreen(services: widget.services),
            ),
          ),
        ),
      ],
    ),
    body: SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('Private team beta · Fictional information only'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _loading
                  ? null
                  : () => _open(widget.services.coordinator.createDraft),
              icon: const Icon(Icons.add),
              label: const Text('Start a case'),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(20),
                child: LinearProgressIndicator(),
              ),
            if (_error != null) ...[
              Text(_error!),
              TextButton(
                onPressed: _loading ? null : () => _load(),
                child: const Text('Retry saved cases'),
              ),
            ],
            if (_local.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(
                'On this device',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              for (final id in _local)
                ListTile(
                  title: Text('Case ${shortCaseId(id)}'),
                  subtitle: const Text(
                    'Local draft · Check saved state before continuing',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _loading
                      ? null
                      : () => _open(
                          () => widget.services.coordinator.restoreLocal(id),
                        ),
                ),
            ],
            const SizedBox(height: 20),
            Text('Saved online', style: Theme.of(context).textTheme.titleLarge),
            if (_loaded && _cases.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text('No saved cases yet.'),
              ),
            for (final item in _cases)
              ListTile(
                title: Text('Case ${shortCaseId(item.caseId)}'),
                subtitle: Text('Saved revision ${item.caseRevision}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _loading
                    ? null
                    : () =>
                          _open(() => widget.services.coordinator.resume(item)),
              ),
            if (_cursor != null)
              OutlinedButton(
                onPressed: _loading ? null : () => _load(more: true),
                child: const Text('Load more cases'),
              ),
          ],
        ),
      ),
    ),
  );
}

String shortCaseId(String id) => id.length > 8 ? id.substring(0, 8) : id;
