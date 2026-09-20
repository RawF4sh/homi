import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../app/live_app.dart';
import '../../shared/models/contracts.dart';
import '../../shared/models/program_intake.dart';

class ProgramIntakeScreen extends StatefulWidget {
  const ProgramIntakeScreen({
    super.key,
    required this.services,
    required this.program,
  });
  final AppServices services;
  final ProgramMatch program;
  @override
  State<ProgramIntakeScreen> createState() => _ProgramIntakeScreenState();
}

class _ProgramIntakeScreenState extends State<ProgramIntakeScreen> {
  final _form = GlobalKey<FormState>();
  final _text = <String, TextEditingController>{};
  final _booleans = <String, bool?>{};
  ProgramIntakeResponse? _response;
  Map<String, Object?>? _restoredDraft;
  bool _busy = true, _uncertain = false, _restoring = true;
  String? _notice;
  late final String _caseId;
  String get _key => 'intake.$_caseId.${widget.program.programId}';
  @override
  void initState() {
    super.initState();
    _caseId = widget.services.coordinator.currentCase().caseId;
    _read(initial: true);
  }

  @override
  void dispose() {
    for (final controller in _text.values) {
      controller.dispose();
    }
    super.dispose();
  }

  bool _current(int revision, int generation) {
    final c = widget.services.coordinator;
    return mounted &&
        c.isCurrent &&
        c.generation == generation &&
        c.snapshot?.caseId == _caseId &&
        c.snapshot?.revision == revision &&
        !c.hasUnsavedChanges;
  }

  Map<String, Object?> _raw() => {
    'values': {for (final entry in _text.entries) entry.key: entry.value.text},
    'booleans': _booleans,
    'uncertain': _uncertain,
    'questionnaireVersion': _response?.definition.questionnaireVersion,
    'caseRevision': _response?.caseRevision,
  };
  Future<void> _persist() => widget.services.store.writeJson(_key, _raw());
  void _stash() {
    if (_restoring) return;
    unawaited(
      _persist().catchError((Object _) {
        if (mounted) {
          setState(
            () => _notice =
                'Unfinished answers could not be saved on this device. Keep this screen open and retry.',
          );
        }
      }),
    );
  }

  List<IntakeAnswer> _answers() => [
    for (final q in _response!.definition.questions)
      IntakeAnswer.fromJson({
        'key': q.key,
        'value': _value(q),
        'reviewState': _value(q) == null ? 'unknown' : 'reported',
      }, _response!.definition),
  ];
  Object? _value(IntakeQuestion q) {
    if (q.kind == 'boolean') return _booleans[q.key];
    final value = _text[q.key]!.text.trim();
    return value.isEmpty
        ? null
        : q.kind == 'money'
        ? num.parse(value)
        : value;
  }

  Future<void> _read({bool initial = false}) async {
    setState(() => _busy = true);
    try {
      if (initial) _restoredDraft = await widget.services.store.readJson(_key);
      final local = _restoredDraft;
      if (local != null) _uncertain = local['uncertain'] == true;
      final c = widget.services.coordinator;
      if (!initial || _uncertain) {
        final remote = await widget.services.answers.reloadCase(
          _caseId,
          currentCase: c.currentCase,
        );
        await c.adoptRemoteSnapshot(remote);
      }
      final snapshot = c.currentCase(), generation = c.generation;
      final response = await widget.services.intake.readIntake(
        snapshot,
        programId: widget.program.programId,
        isCurrent: () => _current(snapshot.revision, generation),
      );
      if (!_current(snapshot.revision, generation)) return;
      final previous = _response;
      _response = response;
      for (final q in response.definition.questions) {
        if (q.kind != 'boolean') {
          _text.putIfAbsent(q.key, () => TextEditingController());
        }
      }
      if (initial || previous == null) {
        for (final answer in response.saved?.answers ?? <IntakeAnswer>[]) {
          if (_text.containsKey(answer.key)) {
            _text[answer.key]!.text = answer.value?.toString() ?? '';
          } else {
            _booleans[answer.key] = answer.value as bool?;
          }
        }
        if (local != null &&
            local['questionnaireVersion'] ==
                response.definition.questionnaireVersion) {
          final values = local['values'] as Map;
          final booleans = local['booleans'] as Map;
          for (final key in _text.keys) {
            _text[key]!.text = values[key] as String? ?? '';
          }
          for (final q in response.definition.questions.where(
            (q) => q.kind == 'boolean',
          )) {
            _booleans[q.key] = booleans[q.key] as bool?;
          }
          _notice = 'Recovered unfinished answers. Review them before saving.';
        }
      }
      _restoredDraft = null;
      if (_uncertain || !initial) {
        var same = false;
        try {
          final saved = {
            for (final a in response.saved?.answers ?? <IntakeAnswer>[])
              a.key: a.toJson(),
          };
          same = _answers().every(
            (a) => jsonEncode(a.toJson()) == jsonEncode(saved[a.key]),
          );
        } catch (_) {
          // ignore: empty_catches
        }
        _uncertain = false;
        _notice = same
            ? 'The submitted answers are confirmed saved.'
            : 'Saved state reloaded. Compare the saved answers below with your local entries before another explicit save.';
        if (previous != null &&
            previous.definition.questionnaireVersion !=
                response.definition.questionnaireVersion) {
          _notice =
              'The questionnaire changed. Review all questions before saving.';
        }
        await _persist();
      }
    } catch (error) {
      if (mounted) _notice = safeOperationMessage(error);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _restoring = false;
        });
      }
    }
  }

  Future<void> _save() async {
    if (_busy ||
        _uncertain ||
        _response == null ||
        !_form.currentState!.validate()) {
      return;
    }
    setState(() => _busy = true);
    try {
      final answers = _answers();
      _uncertain = true;
      await _persist();
      final c = widget.services.coordinator;
      await c.serialize(() async {
        final saved = c.currentCase(), generation = c.generation;
        final response = await widget.services.intake.saveIntake(
          saved,
          definition: _response!.definition,
          expectedIntakeRevision: _response!.saved?.intakeRevision ?? 0,
          answers: answers,
          isCurrent: () => _current(saved.revision, generation),
        );
        await c.adoptRemoteSnapshot(
          CaseSnapshot.fromJson({
            ...saved.toJson(),
            'revision': response.caseRevision,
          }),
        );
        _response = response;
        _uncertain = false;
        await _persist();
      });
      if (mounted) {
        _notice =
            'Reported program answers saved. Refresh the program checks to use the new case revision.';
      }
    } catch (error) {
      if (mounted) _notice = safeOperationMessage(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Program questions')),
    body: SafeArea(
      child: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              widget.program.programName,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Text(
              'These are reported facts, not a diagnosis, professional determination or funding decision. Unknown is different from No or zero.',
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_notice!),
              ),
            if (_uncertain)
              const Text(
                'A save may already have succeeded. Check saved answers before another save.',
              ),
            OutlinedButton(
              onPressed: _busy ? null : () => _read(),
              child: const Text('Check saved answers and reconcile'),
            ),
            if (_response?.saved != null)
              ExpansionTile(
                title: const Text('Compare saved answers'),
                children: [
                  for (final q in _response!.definition.questions)
                    ListTile(
                      title: Text(q.label),
                      subtitle: Text(_savedLabel(q.key)),
                    ),
                ],
              ),
            for (final q
                in _response?.definition.questions ?? <IntakeQuestion>[])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(q.description),
                    const SizedBox(height: 6),
                    if (q.kind == 'boolean')
                      DropdownButtonFormField<String>(
                        key: ValueKey('${q.key}-$_restoring'),
                        initialValue: _booleans[q.key]?.toString() ?? 'unknown',
                        isExpanded: true,
                        decoration: InputDecoration(labelText: q.label),
                        items: const [
                          DropdownMenuItem(
                            value: 'unknown',
                            child: Text('Unknown'),
                          ),
                          DropdownMenuItem(value: 'true', child: Text('Yes')),
                          DropdownMenuItem(value: 'false', child: Text('No')),
                        ],
                        onChanged: _busy || _uncertain
                            ? null
                            : (v) {
                                setState(
                                  () => _booleans[q.key] = v == 'unknown'
                                      ? null
                                      : v == 'true',
                                );
                                _stash();
                              },
                      )
                    else
                      TextFormField(
                        controller: _text[q.key],
                        enabled: !_busy && !_uncertain,
                        decoration: InputDecoration(
                          labelText: q.label,
                          helperText: 'Blank means unknown',
                        ),
                        keyboardType: q.kind == 'money'
                            ? const TextInputType.numberWithOptions(
                                decimal: true,
                              )
                            : TextInputType.text,
                        maxLength: q.maxLength ?? 20,
                        onChanged: (_) => _stash(),
                        validator: (value) {
                          try {
                            IntakeAnswer.fromJson({
                              'key': q.key,
                              'value': _value(q),
                              'reviewState': _value(q) == null
                                  ? 'unknown'
                                  : 'reported',
                            }, _response!.definition);
                            return null;
                          } catch (_) {
                            return q.kind == 'money'
                                ? 'Enter a nonnegative amount with at most two decimal places.'
                                : 'Enter a supported value or leave it blank.';
                          }
                        },
                      ),
                  ],
                ),
              ),
            FilledButton(
              onPressed: _busy || _uncertain || _response == null
                  ? null
                  : _save,
              child: const Text('Save these reported answers'),
            ),
          ],
        ),
      ),
    ),
  );
  String _savedLabel(String key) {
    final answers = _response?.saved?.answers.where((a) => a.key == key);
    final value = answers == null || answers.isEmpty
        ? null
        : answers.single.value;
    return value == null
        ? 'Unknown'
        : value == true
        ? 'Yes'
        : value == false
        ? 'No'
        : value.toString();
  }
}
