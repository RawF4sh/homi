import 'dart:async';
import 'package:flutter/material.dart';
import '../../app/live_app.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/services/draft_save_tracker.dart';
import '../../shared/presentation/draft_exit_guard.dart';
import 'progress_models.dart';
import 'progress_service.dart';
import 'program_progress_screen.dart';

class TaskEditorScreen extends StatefulWidget {
  const TaskEditorScreen({
    super.key,
    required this.services,
    required this.snapshot,
    this.task,
    this.program,
    this.proposal,
    this.initialFindingId,
    this.referralId,
  });
  final AppServices services;
  final ProgressSnapshot snapshot;
  final NextStepTask? task;
  final TrackedProgram? program;
  final Map<String, Object?>? proposal;
  final String? initialFindingId, referralId;
  @override
  State<TaskEditorScreen> createState() => _TaskEditorScreenState();
}

class _TaskEditorScreenState extends State<TaskEditorScreen> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController(),
      _person = TextEditingController(),
      _due = TextEditingController();
  late final DraftSaveTracker _saves;
  late final int _generation = widget.services.coordinator.generation;
  late String _taskId = widget.task?.id ?? newUuidV4();
  String _kind = 'other', _state = 'pending';
  String? _programId, _findingId, _sourceEventId;
  bool _ready = false, _reviewed = false;
  String? _error;
  String get _key => 'progress-edit.${widget.snapshot.caseId}';
  bool get current =>
      mounted &&
      widget.services.coordinator.isCurrent &&
      widget.services.coordinator.generation == _generation &&
      widget.services.coordinator.snapshot?.caseId == widget.snapshot.caseId;
  @override
  void initState() {
    super.initState();
    _saves = DraftSaveTracker(isCurrent: () => current);
    _restore();
  }

  Future<void> _restore() async {
    final task = widget.task;
    _programId = task?.programId ?? widget.program?.id;
    _title.text = task?.title ?? widget.proposal?['title'] as String? ?? '';
    _person.text =
        task?.responsiblePerson ??
        widget.proposal?['responsiblePerson'] as String? ??
        '';
    _due.text = task?.dueOn ?? '';
    _kind =
        task?.kind ??
        (widget.referralId != null
            ? 'follow_up'
            : widget.initialFindingId == null
            ? 'other'
            : 'room_review');
    _state = task?.state ?? 'pending';
    _findingId = task?.data['findingId'] as String? ?? widget.initialFindingId;
    if (!widget.services.coordinator.currentCase().findings.any(
      (f) => f.id == _findingId,
    )) {
      _findingId = null;
    }
    _sourceEventId =
        task?.data['sourceEventId'] as String? ??
        widget.proposal?['eventId'] as String?;
    try {
      final old = await widget.services.store.readJson(_key);
      if (!current) return;
      if (old != null &&
          old['editingId'] == widget.task?.id &&
          old['editingRevision'] == widget.task?.revision &&
          old['caseRevision'] == widget.snapshot.caseRevision &&
          old['programId'] == _programId &&
          old['initialFindingId'] == widget.initialFindingId &&
          old['referralId'] == widget.referralId &&
          old['sourceEventId'] == _sourceEventId) {
        _taskId = old['id'] as String;
        _title.text = old['title'] as String;
        _person.text = old['person'] as String;
        _due.text = old['due'] as String;
        _kind = old['kind'] as String;
        _state = old['state'] as String;
        _findingId = old['findingId'] as String?;
      }
    } catch (_) {
      if (current) {
        _error = 'Unfinished edits could not be saved on this device.';
      }
    }
    if (mounted) setState(() => _ready = true);
  }

  void _stash() {
    if (!_ready || !current) return;
    final value = <String, Object?>{
      'id': _taskId,
      'editingId': widget.task?.id,
      'editingRevision': widget.task?.revision,
      'caseRevision': widget.snapshot.caseRevision,
      'title': _title.text,
      'person': _person.text,
      'due': _due.text,
      'kind': _kind,
      'state': _state,
      'programId': _programId,
      'findingId': _findingId,
      'sourceEventId': _sourceEventId,
      'initialFindingId': widget.initialFindingId,
      'referralId': widget.referralId,
    };
    unawaited(
      _saves
          .track(() => widget.services.store.writeJson(_key, value))
          .catchError((Object _) {
            if (current) {
              setState(
                () => _error =
                    'Unfinished edits could not be saved on this device.',
              );
            }
          }),
    );
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate() || !current || !_ready) return;
    if (widget.task?.needsReview == true && !_reviewed) {
      setState(
        () =>
            _error = 'Review this task against the current plan before saving.',
      );
      return;
    }
    try {
      if (!await _saves.settle()) throw StateError('Device save failed.');
      if (!mounted || !current) return;
      Navigator.pop(context, <String, Object?>{
        'type': 'put_task',
        'expectedTaskRevision': widget.task?.revision ?? 0,
        'task': {
          'id': _taskId,
          if (widget.task?.referral != null || widget.referralId != null)
            'referral':
                widget.task?.referral ?? {'providerId': widget.referralId!},
          'programId': _programId,
          'findingId': _findingId,
          'formId': widget.task?.data['formId'],
          'title': _title.text.trim(),
          'kind': _kind,
          'state': _state,
          'responsiblePerson': _person.text.trim().isEmpty
              ? null
              : _person.text.trim(),
          'dueOn': _due.text.trim().isEmpty ? null : _due.text.trim(),
          'basedOnCaseRevision': widget.snapshot.caseRevision,
          'basedOnRuleVersion': widget.snapshot.programs
              .where((p) => p.id == _programId)
              .firstOrNull
              ?.ruleVersion,
          'revision': (widget.task?.revision ?? 0) + 1,
          'sourceEventId': _sourceEventId,
        },
      });
    } catch (_) {
      if (current) {
        setState(
          () => _error = 'Unfinished edits could not be saved on this device.',
        );
      }
    }
  }

  @override
  void dispose() {
    _saves.dispose();
    _title.dispose();
    _person.dispose();
    _due.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DraftExitGuard(
    tracker: _saves,
    builder: (context, requestExit, exiting) => Scaffold(
      appBar: AppBar(title: Text(context.tr('Edit task'))),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (!_ready) const LinearProgressIndicator(),
              if (_error != null) Text(context.tr(_error!)),
              TextFormField(
                controller: _title,
                enabled: _ready,
                maxLength: 200,
                decoration: InputDecoration(labelText: context.tr('Next step')),
                onChanged: (_) => _stash(),
                validator: (v) => (v ?? '').trim().isEmpty
                    ? context.tr('Enter a next step.')
                    : null,
              ),
              DropdownButtonFormField<String>(
                key: ValueKey('program-$_ready'),
                initialValue: _programId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: context.tr('Program (optional)'),
                ),
                items: [
                  DropdownMenuItem(
                    value: null,
                    child: Text(context.tr('Whole plan')),
                  ),
                  for (final p in widget.snapshot.programs)
                    DropdownMenuItem(value: p.id, child: Text(p.name)),
                ],
                onChanged: _ready && _sourceEventId == null
                    ? (v) {
                        setState(() => _programId = v);
                        _stash();
                      }
                    : null,
              ),
              DropdownButtonFormField<String>(
                key: ValueKey('kind-$_ready'),
                initialValue: _kind,
                isExpanded: true,
                decoration: InputDecoration(labelText: context.tr('Task type')),
                items: [
                  for (final k in taskKinds)
                    DropdownMenuItem(
                      value: k,
                      child: Text(context.tr(taskKindLabel(k))),
                    ),
                ],
                onChanged: _ready
                    ? (v) {
                        setState(() => _kind = v!);
                        _stash();
                      }
                    : null,
              ),
              DropdownButtonFormField<String>(
                key: ValueKey('state-$_ready'),
                initialValue: _state,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: context.tr('Task status'),
                ),
                items: [
                  for (final s in taskStates)
                    DropdownMenuItem(
                      value: s,
                      child: Text(context.tr(taskStateLabel(s))),
                    ),
                ],
                onChanged: _ready
                    ? (v) {
                        setState(() => _state = v!);
                        _stash();
                      }
                    : null,
              ),
              TextFormField(
                controller: _person,
                maxLength: 100,
                decoration: InputDecoration(
                  labelText: context.tr('Responsible person (optional)'),
                ),
                onChanged: (_) => _stash(),
              ),
              Text(
                context.tr(
                  'A name or role is a label only. This does not give anyone access to the plan.',
                ),
              ),
              TextFormField(
                controller: _due,
                decoration: InputDecoration(
                  labelText: context.tr('Target date (YYYY-MM-DD, optional)'),
                ),
                keyboardType: TextInputType.datetime,
                onChanged: (_) => _stash(),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return null;
                  try {
                    progressDate(v.trim());
                    return null;
                  } catch (_) {
                    return context.tr('Use a valid date: YYYY-MM-DD.');
                  }
                },
              ),
              DropdownButtonFormField<String>(
                key: ValueKey('finding-$_ready'),
                initialValue:
                    widget.services.coordinator.currentCase().findings.any(
                      (f) => f.id == _findingId,
                    )
                    ? _findingId
                    : null,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: context.tr('Related concern (optional)'),
                ),
                items: [
                  DropdownMenuItem(
                    value: null,
                    child: Text(context.tr('None')),
                  ),
                  for (final f
                      in widget.services.coordinator.currentCase().findings)
                    DropdownMenuItem(
                      value: f.id,
                      child: Text(
                        f.observation,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _ready
                    ? (v) {
                        setState(() => _findingId = v);
                        _stash();
                      }
                    : null,
              ),
              if (widget.task?.needsReview == true)
                CheckboxListTile(
                  value: _reviewed,
                  title: Text(
                    context.tr(
                      'I reviewed this task against the current plan.',
                    ),
                  ),
                  onChanged: (v) => setState(() => _reviewed = v!),
                ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _ready ? _save : null,
                child: Text(context.tr('Save task')),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
