import 'dart:async';
import 'package:flutter/material.dart';
import '../../app/live_app.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/models/contracts.dart';
import '../../shared/models/request_tracking.dart';

class RequestHistoryScreen extends StatefulWidget {
  const RequestHistoryScreen({
    super.key,
    required this.services,
    required this.program,
  });
  final AppServices services;
  final ProgramMatch program;
  @override
  State<RequestHistoryScreen> createState() => _RequestHistoryScreenState();
}

class _RequestHistoryScreenState extends State<RequestHistoryScreen> {
  RequestHistory? _history;
  PendingRequestUpdate? _pending;
  bool _busy = false, _reconciledPending = false, _restoring = true;
  String get _editKey =>
      'history-edit.${widget.services.coordinator.currentCase().caseId}.${widget.program.programId}';
  String? _error;
  final _date = TextEditingController(
        text: DateTime.now().toIso8601String().substring(0, 10),
      ),
      _note = TextEditingController(),
      _action = TextEditingController(),
      _follow = TextEditingController();
  String _status = 'preparing', _source = 'self_report', _party = 'resident';
  String get _key =>
      'history.${widget.services.coordinator.currentCase().caseId}.${widget.program.programId}';
  @override
  void initState() {
    super.initState();
    _load(initial: true);
  }

  @override
  void dispose() {
    _date.dispose();
    _note.dispose();
    _action.dispose();
    _follow.dispose();
    super.dispose();
  }

  ReadRequestHistoryRequest _request() {
    final c = widget.services.coordinator.currentCase();
    return ReadRequestHistoryRequest(
      caseId: c.caseId,
      expectedCaseRevision: c.revision,
      programId: widget.program.programId,
    );
  }

  Future<void> _load({bool initial = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (initial) {
        final value = await widget.services.store.readJson(_key);
        if (value != null) _pending = PendingRequestUpdate.fromJson(value);
        final edit = await widget.services.store.readJson(_editKey);
        if (edit != null && mounted) {
          _date.text = edit['date'] as String? ?? _date.text;
          _note.text = edit['note'] as String? ?? '';
          _action.text = edit['action'] as String? ?? '';
          _follow.text = edit['follow'] as String? ?? '';
          _status = edit['status'] as String? ?? 'preparing';
          _source = edit['source'] as String? ?? 'self_report';
          _party = edit['party'] as String? ?? 'resident';
        }
      }
      final c = widget.services.coordinator;
      final generation = c.generation;
      final history = await widget.services.history.readHistory(
        _request(),
        currentCase: c.currentCase,
        currentProgramId: () => widget.program.programId,
        currentHistory: () => _history,
        isCurrent: () => mounted && c.isCurrent && c.generation == generation,
      );
      if (!mounted) return;
      _history = history;
      _reconciledPending = true;
      if (_pending != null && history.acknowledges(_pending!)) {
        _pending = null;
        await widget.services.store.delete(_key);
        await widget.services.store.delete(_editKey);
        _note.clear();
        _action.clear();
        _follow.clear();
        _error = 'The pending update was already saved.';
      }
    } catch (error) {
      if (mounted) _error = safeOperationMessage(error);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _restoring = false;
        });
      }
    }
  }

  bool get _canRetry =>
      _reconciledPending &&
      _pending != null &&
      _history != null &&
      _pending!.request.expectedCaseRevision == _history!.caseRevision &&
      _pending!.expectedRequestRevision == _history!.requestRevision;

  void _stash() {
    if (_restoring) return;
    unawaited(
      widget.services.store
          .writeJson(_editKey, {
            'date': _date.text,
            'note': _note.text,
            'action': _action.text,
            'follow': _follow.text,
            'status': _status,
            'source': _source,
            'party': _party,
          })
          .catchError((Object _) {
            if (mounted) {
              setState(
                () => _error =
                    'Unfinished edits could not be saved on this device.',
              );
            }
          }),
    );
  }

  Future<void> _discardPending() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Return this update to the editor?'),
        content: const Text(
          'Review the latest history above first. This discards the old pending attempt; a future save creates a new update.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Return to editor'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        _pending == null ||
        !_reconciledPending) {
      return;
    }
    final u = _pending!.update;
    _date.text = u.occurredOn;
    _note.text = u.note ?? '';
    _action.text = u.nextAction ?? '';
    _follow.text = u.followUpOn ?? '';
    _status = u.status;
    _source = u.source;
    _party = u.responsibleParty ?? 'resident';
    try {
      await widget.services.store.delete(_key);
      if (mounted) setState(() => _pending = null);
      _stash();
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    }
  }

  Future<void> _append() async {
    if (_busy || _history == null || (_pending != null && !_canRetry)) return;
    setState(() => _busy = true);
    try {
      final nextAction = _action.text.trim();
      _pending ??= PendingRequestUpdate(
        request: _request(),
        expectedRequestRevision: _history!.requestRevision,
        update: RequestUpdate(
          updateId: newUuidV4(),
          status: _status,
          occurredOn: _date.text.trim(),
          source: _source,
          note: _note.text.trim().isEmpty ? null : _note.text.trim(),
          nextAction: nextAction.isEmpty ? null : nextAction,
          responsibleParty: nextAction.isEmpty ? null : _party,
          followUpOn: _follow.text.trim().isEmpty ? null : _follow.text.trim(),
        ),
      );
      await widget.services.store.writeJson(_key, _pending!.toJson());
      _reconciledPending = false;
      final c = widget.services.coordinator;
      final generation = c.generation;
      final history = await c.serialize(
        () => widget.services.history.appendUpdate(
          _pending!,
          currentCase: c.currentCase,
          currentProgramId: () => widget.program.programId,
          currentHistory: () => _history,
          isCurrent: () => mounted && c.isCurrent && c.generation == generation,
        ),
      );
      if (!mounted) return;
      _history = history;
      _pending = null;
      await widget.services.store.delete(_key);
      await widget.services.store.delete(_editKey);
      _note.clear();
      _action.clear();
      _follow.clear();
      _error = 'Manual update saved. This is not verified agency status.';
    } catch (error) {
      if (mounted) _error = safeOperationMessage(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Manual request history')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(widget.program.programName),
          const Text(
            'These are your reports. The app does not submit applications, verify receipt or approve funding.',
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_error!),
            ),
          OutlinedButton(
            onPressed: _busy ? null : () => _load(),
            child: const Text('Reload history and check pending update'),
          ),
          for (final event in _history?.events ?? <RequestEvent>[])
            ListTile(
              title: Text(
                '${_label(event.update.status)} · ${event.update.occurredOn}',
              ),
              subtitle: Text(
                [
                  event.update.note,
                  event.update.nextAction,
                  event.update.responsibleParty,
                  event.update.followUpOn,
                ].whereType<String>().join('\n'),
              ),
            ),
          if (_pending != null) ...[
            const Text(
              'An update may already have been saved. Reload history before retrying the exact pending update.',
            ),
            Text(
              '${_label(_pending!.update.status)} · ${_pending!.update.occurredOn}',
            ),
            Text(_pending!.update.note ?? ''),
            FilledButton(
              onPressed: _busy || !_canRetry ? null : _append,
              child: const Text('Retry exact pending update'),
            ),
            if (_reconciledPending && !_canRetry)
              TextButton(
                onPressed: _busy ? null : _discardPending,
                child: const Text('Review against changed history and edit'),
              ),
          ] else if (_history != null) ...[
            DropdownButtonFormField<String>(
              key: ValueKey('status-$_restoring'),
              initialValue: _status,
              decoration: const InputDecoration(labelText: 'Reported status'),
              items: [
                for (final value in [
                  'preparing',
                  'submitted',
                  'received',
                  'needs_information',
                  'approved',
                  'denied',
                  'withdrawn',
                ])
                  DropdownMenuItem(value: value, child: Text(_label(value))),
              ],
              onChanged: _busy
                  ? null
                  : (v) {
                      setState(() => _status = v!);
                      _stash();
                    },
            ),
            TextField(
              controller: _date,
              onChanged: (_) => _stash(),
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Date it happened (YYYY-MM-DD)',
              ),
            ),
            DropdownButtonFormField<String>(
              key: ValueKey('source-$_restoring'),
              initialValue: _source,
              decoration: const InputDecoration(labelText: 'Your source'),
              items: [
                for (final value in [
                  'self_report',
                  'program_contact',
                  'document',
                ])
                  DropdownMenuItem(value: value, child: Text(_label(value))),
              ],
              onChanged: _busy
                  ? null
                  : (v) {
                      setState(() => _source = v!);
                      _stash();
                    },
            ),
            TextField(
              controller: _note,
              onChanged: (_) => _stash(),
              enabled: !_busy,
              maxLength: 500,
              decoration: const InputDecoration(labelText: 'Optional note'),
            ),
            TextField(
              controller: _action,
              onChanged: (_) => _stash(),
              enabled: !_busy,
              maxLength: 250,
              decoration: const InputDecoration(
                labelText: 'Optional next action',
              ),
            ),
            DropdownButtonFormField<String>(
              key: ValueKey('party-$_restoring'),
              initialValue: _party,
              decoration: const InputDecoration(
                labelText: 'Who handles the next action?',
              ),
              items: [
                for (final value in [
                  'resident',
                  'caregiver',
                  'program',
                  'clinician',
                  'contractor',
                  'other',
                ])
                  DropdownMenuItem(value: value, child: Text(_label(value))),
              ],
              onChanged: _busy
                  ? null
                  : (v) {
                      setState(() => _party = v!);
                      _stash();
                    },
            ),
            TextField(
              controller: _follow,
              onChanged: (_) => _stash(),
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Optional follow-up date (YYYY-MM-DD)',
              ),
            ),
            FilledButton(
              onPressed: _busy || _history!.requestRevision >= 50
                  ? null
                  : _append,
              child: const Text('Save manual update'),
            ),
          ],
        ],
      ),
    ),
  );
}

String _label(String text) => text.replaceAll('_', ' ');
