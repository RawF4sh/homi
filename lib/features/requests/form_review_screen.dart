import 'dart:convert';
import 'package:flutter/material.dart';
import '../../app/live_app.dart';
import '../../shared/models/contracts.dart';
import '../../shared/models/form_answers.dart';

class FormReviewScreen extends StatefulWidget {
  const FormReviewScreen({
    super.key,
    required this.services,
    required this.program,
  });
  final AppServices services;
  final ProgramMatch program;
  @override
  State<FormReviewScreen> createState() => _FormReviewScreenState();
}

class _FormReviewScreenState extends State<FormReviewScreen> {
  final _fields = <String, TextEditingController>{};
  final _reviewed = <String, bool>{};
  FormAnswersResponse? _answers;
  Map<String, Object?>? _restoredDraft;
  bool _busy = true, _uncertain = false;
  String? _error;
  String get _key =>
      'form.${widget.services.coordinator.currentCase().caseId}.${widget.program.programId}';
  @override
  void initState() {
    super.initState();
    for (final key in formAnswerValueLimits.keys) {
      _fields[key] = TextEditingController();
      _reviewed[key] = false;
    }
    _read(initial: true);
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Iterable<String> get _activeKeys =>
      _answers?.fieldDefinitions.map((field) => field.key) ?? const <String>[];
  FormAnswerFieldDefinition _definition(String key) =>
      _answers!.fieldDefinitions.firstWhere((field) => field.key == key);

  List<FormAnswerInput> _inputs() => [
    for (final key in _activeKeys)
      FormAnswerInput.fromJson({
        'key': key,
        'value': _fields[key]!.text.trim().isEmpty
            ? null
            : _fields[key]!.text.trim(),
        'reviewState':
            _fields[key]!.text.trim().isNotEmpty && _reviewed[key] == true
            ? 'reviewed'
            : 'needs_review',
      }),
  ];
  Future<void> _persist() async {
    await widget.services.store.writeJson(_key, {
      'values': {for (final key in _fields.keys) key: _fields[key]!.text},
      'reviewed': _reviewed,
      'uncertain': _uncertain,
      'caseRevision': widget.services.coordinator.currentCase().revision,
      'formContextId': _answers?.context.formContextId,
    });
  }

  Future<void> _read({bool initial = false}) async {
    setState(() => _busy = true);
    try {
      if (initial) _restoredDraft = await widget.services.store.readJson(_key);
      final local = _restoredDraft;
      if (local != null) {
        final values = local['values'] as Map;
        for (final key in _fields.keys) {
          _fields[key]!.text = values[key] as String? ?? '';
        }
        _uncertain = local['uncertain'] == true;
      }
      final c = widget.services.coordinator;
      if (!initial || _uncertain) {
        final remote = await widget.services.answers.reloadCase(
          c.currentCase().caseId,
          currentCase: c.currentCase,
        );
        await c.adoptRemoteSnapshot(remote);
      }
      final response = await widget.services.answers.readAnswers(
        c.currentCase(),
        programId: widget.program.programId,
        currentCase: c.currentCase,
        currentProgramId: () => widget.program.programId,
        currentContext: () => _answers?.context,
      );
      if (!mounted) return;
      _answers = response;
      if (initial || _restoredDraft != null) {
        for (final answer in response.saved?.answers ?? <SavedFormAnswer>[]) {
          _fields[answer.key]!.text = answer.value ?? '';
          _reviewed[answer.key] =
              response.isCurrent && answer.reviewState == 'reviewed';
        }
        if (local != null) {
          final values = local['values'] as Map;
          final reviewed = local['reviewed'] as Map;
          for (final key in _fields.keys) {
            _fields[key]!.text = values[key] as String? ?? '';
            _reviewed[key] =
                reviewed[key] == true &&
                local['caseRevision'] == response.caseRevision &&
                local['formContextId'] == response.context.formContextId;
          }
          _uncertain = local['uncertain'] == true;
        }
        _restoredDraft = null;
      } else {
        final saved = {
          for (final answer in response.saved?.answers ?? <SavedFormAnswer>[])
            answer.key: {
              'key': answer.key,
              'value': answer.value,
              'reviewState': answer.reviewState,
            },
        };
        final same = _inputs().every(
          (answer) =>
              jsonEncode(saved[answer.key]) == jsonEncode(answer.toJson()),
        );
        _uncertain = false;
        _error = same
            ? 'Your answers were saved.'
            : 'Saved state reloaded. Your local answers remain below; review them before saving again.';
        if (!same) {
          for (final key in _reviewed.keys) {
            _reviewed[key] = false;
          }
        }
        await _persist();
      }
    } catch (error) {
      if (mounted) _error = safeOperationMessage(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_answers == null || _uncertain || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final inputs = _inputs();
      _uncertain = true;
      await _persist();
      await widget.services.coordinator.serialize(() async {
        final c = widget.services.coordinator;
        final saved = c.currentCase();
        final response = await widget.services.answers.saveAnswers(
          saved,
          context: _answers!.context,
          expectedAnswerRevision: _answers!.saved?.answerRevision ?? 0,
          answers: inputs,
          currentCase: c.currentCase,
          currentProgramId: () => widget.program.programId,
          currentContext: () => _answers?.context,
        );
        await c.adoptRemoteSnapshot(
          CaseSnapshot.fromJson({
            ...saved.toJson(),
            'revision': response.caseRevision,
          }),
        );
        _answers = response;
        _uncertain = false;
        await _persist();
      });
      if (mounted) {
        _error =
            'Administrative answers saved. Clinical review, consent and signatures remain separate.';
      }
    } catch (error) {
      if (mounted) _error = safeOperationMessage(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edited(String key) async {
    setState(() => _reviewed[key] = false);
    try {
      await _persist();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'The latest edits could not be saved on this device. Keep this screen open and retry.',
        );
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Administrative answers')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(widget.program.programName),
          const SizedBox(height: 8),
          const Text(
            'These answers do not supply diagnoses, medical necessity, consent or signatures. Review each supplied value yourself.',
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_error!),
            ),
          if (_uncertain)
            const Text(
              'A save may have succeeded. Check saved answers before another save.',
            ),
          OutlinedButton(
            onPressed: _busy ? null : () => _read(),
            child: const Text('Reload saved answers and reconcile'),
          ),
          if (_answers != null) ...[
            Text(
              _answers!.artifactKind == 'preparation_worksheet'
                  ? 'Preparation worksheet · this is not an official application form.'
                  : 'Official-form draft · incomplete and unsubmitted.',
            ),
            if (!_answers!.isCurrent)
              const Text(
                'The saved answer set needs review for the current case and form.',
              ),
            for (final key in _activeKeys)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  children: [
                    TextField(
                      controller: _fields[key],
                      enabled: !_busy,
                      decoration: InputDecoration(
                        labelText: _definition(key).label,
                        helperText: _definition(key).kind == 'date'
                            ? 'YYYY-MM-DD; leave blank if unknown'
                            : 'Leave blank if unknown',
                        counterText: '',
                      ),
                      maxLength: _definition(key).maxLength,
                      onChanged: (_) => _edited(key),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('I reviewed this value'),
                      value: _reviewed[key] ?? false,
                      onChanged: _busy || _fields[key]!.text.trim().isEmpty
                          ? null
                          : (v) async {
                              setState(() => _reviewed[key] = v ?? false);
                              try {
                                await _persist();
                              } catch (error) {
                                if (context.mounted) {
                                  await showOperationError(context, error);
                                }
                              }
                            },
                    ),
                  ],
                ),
              ),
            FilledButton(
              onPressed: _busy || _uncertain ? null : _save,
              child: const Text('Save reviewed administrative answers'),
            ),
          ],
        ],
      ),
    ),
  );
}
