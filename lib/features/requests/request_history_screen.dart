import 'dart:async';
import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import '../../app/live_app.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/models/contracts.dart';
import '../../shared/models/request_tracking.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/presentation/draft_exit_guard.dart';
import '../../shared/services/draft_save_tracker.dart';
import '../../shared/services/matching_api_client.dart';

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
  bool _feedbackAtAction = false;
  late final String _caseId;
  late final int _generation;
  late final DraftSaveTracker _draftSaves;
  String get _editKey => 'history-edit.$_caseId.${widget.program.programId}';
  String? _error;
  final _date = TextEditingController(
        text: DateTime.now().toIso8601String().substring(0, 10),
      ),
      _note = TextEditingController(),
      _action = TextEditingController(),
      _follow = TextEditingController();
  String _status = 'preparing', _source = 'self_report', _party = 'resident';
  String get _key => 'history.$_caseId.${widget.program.programId}';
  @override
  void initState() {
    super.initState();
    _caseId = widget.services.coordinator.currentCase().caseId;
    _generation = widget.services.coordinator.generation;
    _draftSaves = DraftSaveTracker(isCurrent: () => _isCurrent);
    _load(initial: true);
  }

  @override
  void dispose() {
    _draftSaves.dispose();
    _date.dispose();
    _note.dispose();
    _action.dispose();
    _follow.dispose();
    super.dispose();
  }

  ReadRequestHistoryRequest _request() {
    final c = _screenCase();
    return ReadRequestHistoryRequest(
      caseId: c.caseId,
      expectedCaseRevision: c.revision,
      programId: widget.program.programId,
    );
  }

  bool get _isCurrent {
    final c = widget.services.coordinator;
    return mounted &&
        c.isCurrent &&
        c.generation == _generation &&
        c.snapshot?.caseId == _caseId &&
        !c.hasUnsavedChanges;
  }

  CaseSnapshot _screenCase() {
    if (!_isCurrent) throw MatchingApiException.forCode('STALE_RESPONSE');
    return widget.services.coordinator.currentCase();
  }

  Future<void> _load({bool initial = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _feedbackAtAction = false;
    });
    try {
      final request = _request();
      if (initial) {
        final value = await widget.services.store.readJson(_key);
        _screenCase();
        if (value != null) _pending = PendingRequestUpdate.fromJson(value);
        final edit = await widget.services.store.readJson(_editKey);
        _screenCase();
        if (edit != null) {
          _date.text = edit['date'] as String? ?? _date.text;
          _note.text = edit['note'] as String? ?? '';
          _action.text = edit['action'] as String? ?? '';
          _follow.text = edit['follow'] as String? ?? '';
          _status = edit['status'] as String? ?? 'preparing';
          _source = edit['source'] as String? ?? 'self_report';
          _party = edit['party'] as String? ?? 'resident';
        }
      }
      final history = await widget.services.history.readHistory(
        request,
        currentCase: _screenCase,
        currentProgramId: () => widget.program.programId,
        currentHistory: () => _history,
        isCurrent: () => _isCurrent,
      );
      _screenCase();
      _history = history;
      _reconciledPending = true;
      if (_pending != null && history.acknowledges(_pending!)) {
        await _clearAcknowledgedJournal();
        _pending = null;
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
    if (_restoring || !_isCurrent) return;
    if (_feedbackAtAction && _error != null) {
      setState(() => _error = null);
    }
    final value = <String, Object?>{
      'date': _date.text,
      'note': _note.text,
      'action': _action.text,
      'follow': _follow.text,
      'status': _status,
      'source': _source,
      'party': _party,
    };
    unawaited(
      _draftSaves
          .track(() => widget.services.store.writeJson(_editKey, value))
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

  Future<void> _clearAcknowledgedJournal() => _draftSaves.track(() async {
    _screenCase();
    await widget.services.store.delete(_key);
    _screenCase();
    await widget.services.store.delete(_editKey);
    _screenCase();
  });

  Future<void> _discardPending() async {
    if (_busy || _pending == null || !_reconciledPending || !_isCurrent) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(ctx.tr('Return this update to the editor?')),
        content: Text(
          ctx.tr(
            'Review the latest history above first. This discards the old pending attempt; a future save creates a new update.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.tr('Return to editor')),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        _busy ||
        !_isCurrent ||
        _pending == null ||
        !_reconciledPending) {
      return;
    }
    final u = _pending!.update;
    setState(() {
      _busy = true;
      _error = null;
      _feedbackAtAction = true;
    });
    try {
      final value = <String, Object?>{
        'date': u.occurredOn,
        'note': u.note ?? '',
        'action': u.nextAction ?? '',
        'follow': u.followUpOn ?? '',
        'status': u.status,
        'source': u.source,
        'party': u.responsibleParty ?? 'resident',
      };
      await _draftSaves.track(() async {
        _screenCase();
        await widget.services.store.writeJson(_editKey, value);
        _screenCase();
        await widget.services.store.delete(_key);
        _screenCase();
      });
      _date.text = u.occurredOn;
      _note.text = u.note ?? '';
      _action.text = u.nextAction ?? '';
      _follow.text = u.followUpOn ?? '';
      _status = u.status;
      _source = u.source;
      _party = u.responsibleParty ?? 'resident';
      setState(() => _pending = null);
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _append() async {
    if (_busy || _history == null || (_pending != null && !_canRetry)) return;
    setState(() {
      _busy = true;
      _error = null;
      _feedbackAtAction = true;
    });
    try {
      _screenCase();
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
      final pendingValue = _pending!.toJson();
      await _draftSaves.track(
        () => widget.services.store.writeJson(_key, pendingValue),
      );
      _screenCase();
      _reconciledPending = false;
      final c = widget.services.coordinator;
      final history = await c.serialize(
        () => widget.services.history.appendUpdate(
          _pending!,
          currentCase: _screenCase,
          currentProgramId: () => widget.program.programId,
          currentHistory: () => _history,
          isCurrent: () => _isCurrent,
        ),
      );
      _screenCase();
      _history = history;
      await _clearAcknowledgedJournal();
      _pending = null;
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
  Widget build(BuildContext context) => DraftExitGuard(
    tracker: _draftSaves,
    builder: (context, requestExit, exiting) => Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: requestExit),
        title: Text(context.tr('Manual request history')),
      ),
      body: SafeArea(
        child: SahContent(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SahPageHeader(title: widget.program.programName),
                SahStatusBadge(
                  label: context.tr('Reported by you · not agency status'),
                  icon: Icons.edit_note_rounded,
                ),
                if (_busy)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator(
                      semanticsLabel: context.tr('Updating request history'),
                    ),
                  ),
                if (_error != null && !_feedbackAtAction)
                  SahNotice(message: context.tr(_error!)),
                const SizedBox(height: 8),
                OutlinedButton(
                  key: const ValueKey('history-reconcile'),
                  onPressed: _busy || exiting ? null : () => _load(),
                  child: Text(
                    context.tr('Reload history and check pending update'),
                    textAlign: TextAlign.center,
                  ),
                ),
                if (_history != null)
                  SahSectionHeading(title: context.tr('Saved updates')),
                if (_history?.events.isEmpty == true)
                  Text(context.tr('No updates yet.')),
                for (final event in _history?.events ?? <RequestEvent>[])
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: ExcludeSemantics(
                      child: Icon(
                        Icons.history_rounded,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    title: Text(
                      context.tr('{status} · {date}', {
                        'status': _label(context, event.update.status),
                        'date': event.update.occurredOn,
                      }),
                    ),
                    subtitle: Text(
                      [
                        event.update.note,
                        if (event.update.nextAction != null)
                          context.tr('Next action: {action}', {
                            'action': event.update.nextAction,
                          }),
                        if (event.update.responsibleParty != null)
                          context.tr('Responsible: {party}', {
                            'party': _label(
                              context,
                              event.update.responsibleParty!,
                            ),
                          }),
                        if (event.update.followUpOn != null)
                          context.tr('Follow-up: {date}', {
                            'date': event.update.followUpOn,
                          }),
                      ].whereType<String>().join('\n'),
                    ),
                  ),
                if (_pending != null) ...[
                  SahSectionHeading(title: context.tr('Pending update')),
                  SahNotice(
                    message: context.tr(
                      'An update may already have been saved. Reload history before retrying the exact pending update.',
                    ),
                    tone: SahNoticeTone.warning,
                  ),
                  Text(
                    context.tr('{status} · {date}', {
                      'status': _label(context, _pending!.update.status),
                      'date': _pending!.update.occurredOn,
                    }),
                  ),
                  Text(_pending!.update.note ?? ''),
                  if (_error != null && _feedbackAtAction)
                    SahActionFeedback(
                      key: const ValueKey('history-save-feedback'),
                      message: context.tr(_error!),
                    ),
                  FilledButton(
                    onPressed: _busy || exiting || !_canRetry ? null : _append,
                    child: Text(
                      context.tr('Retry exact pending update'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (_reconciledPending && !_canRetry)
                    TextButton(
                      onPressed: _busy || exiting ? null : _discardPending,
                      child: Text(
                        context.tr('Review against changed history and edit'),
                      ),
                    ),
                ] else if (_history != null) ...[
                  SahSectionHeading(title: context.tr('Add a reported update')),
                  DropdownButtonFormField<String>(
                    key: ValueKey('status-$_restoring'),
                    initialValue: _status,
                    isExpanded: true,
                    isDense: false,
                    itemHeight: null,
                    decoration: InputDecoration(
                      labelText: context.tr('Reported status'),
                    ),
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
                        DropdownMenuItem(
                          value: value,
                          child: Text(_label(context, value)),
                        ),
                    ],
                    onChanged: _busy || exiting
                        ? null
                        : (v) {
                            setState(() => _status = v!);
                            _stash();
                          },
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _date,
                    onChanged: (_) => _stash(),
                    enabled: !_busy && !exiting,
                    keyboardType: TextInputType.datetime,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: context.tr('Date it happened (YYYY-MM-DD)'),
                      helperText: context.tr('For example 2026-10-23'),
                    ),
                  ),
                  const SizedBox(height: 20),
                  DropdownButtonFormField<String>(
                    key: ValueKey('source-$_restoring'),
                    initialValue: _source,
                    isExpanded: true,
                    isDense: false,
                    itemHeight: null,
                    decoration: InputDecoration(
                      labelText: context.tr('Your source'),
                    ),
                    items: [
                      for (final value in [
                        'self_report',
                        'program_contact',
                        'document',
                      ])
                        DropdownMenuItem(
                          value: value,
                          child: Text(_label(context, value)),
                        ),
                    ],
                    onChanged: _busy || exiting
                        ? null
                        : (v) {
                            setState(() => _source = v!);
                            _stash();
                          },
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _note,
                    onChanged: (_) => _stash(),
                    enabled: !_busy && !exiting,
                    maxLength: 500,
                    minLines: 2,
                    maxLines: 5,
                    decoration: InputDecoration(
                      labelText: context.tr('Optional note'),
                    ),
                  ),
                  SahSectionHeading(title: context.tr('Next action')),
                  TextField(
                    controller: _action,
                    onChanged: (_) => _stash(),
                    enabled: !_busy && !exiting,
                    maxLength: 250,
                    minLines: 1,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: context.tr('Optional next action'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    key: ValueKey('party-$_restoring'),
                    initialValue: _party,
                    isExpanded: true,
                    isDense: false,
                    itemHeight: null,
                    decoration: InputDecoration(
                      labelText: context.tr('Who handles the next action?'),
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
                        DropdownMenuItem(
                          value: value,
                          child: Text(_label(context, value)),
                        ),
                    ],
                    onChanged: _busy || exiting
                        ? null
                        : (v) {
                            setState(() => _party = v!);
                            _stash();
                          },
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _follow,
                    onChanged: (_) => _stash(),
                    enabled: !_busy && !exiting,
                    keyboardType: TextInputType.datetime,
                    decoration: InputDecoration(
                      labelText: context.tr(
                        'Optional follow-up date (YYYY-MM-DD)',
                      ),
                      helperText: context.tr('Needs a next action too'),
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_history!.requestRevision >= 50)
                    SahNotice(
                      message: context.tr(
                        'This request history has reached its limit of 50 updates. Your saved history remains available.',
                      ),
                      tone: SahNoticeTone.warning,
                    ),
                  if (_error != null && _feedbackAtAction)
                    SahActionFeedback(
                      key: const ValueKey('history-save-feedback'),
                      message: context.tr(_error!),
                    ),
                  FilledButton(
                    key: const ValueKey('history-save'),
                    onPressed:
                        _busy || exiting || _history!.requestRevision >= 50
                        ? null
                        : _append,
                    child: Text(context.tr('Save manual update')),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

String _label(BuildContext context, String text) => context.tr(switch (text) {
  'needs_information' => 'Needs info',
  'program_contact' => 'Program contact',
  'self_report' => 'Self report',
  _ =>
    text.isEmpty
        ? text
        : '${text[0].toUpperCase()}${text.substring(1).replaceAll('_', ' ')}',
});
