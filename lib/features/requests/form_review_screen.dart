import 'dart:convert';
import '../programs/program_field_localization.dart';
import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import '../../app/live_app.dart';
import '../../shared/models/contracts.dart';
import '../../shared/models/form_answers.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/presentation/draft_exit_guard.dart';
import '../../shared/services/draft_save_tracker.dart';
import '../../shared/services/matching_api_client.dart';

class FormReviewScreen extends StatefulWidget {
  const FormReviewScreen({
    super.key,
    required this.services,
    required this.program,
    this.onNext,
  });
  final AppServices services;
  final ProgramMatch program;

  final VoidCallback? onNext;
  @override
  State<FormReviewScreen> createState() => _FormReviewScreenState();
}

class _FormReviewScreenState extends State<FormReviewScreen> {
  final _fields = <String, TextEditingController>{};
  final _reviewed = <String, bool>{};
  FormAnswersResponse? _answers;
  Map<String, Object?>? _restoredDraft;
  bool _busy = true, _uncertain = false;
  bool _feedbackAtAction = false;
  String? _error;
  late final String _caseId;
  late final int _generation;
  late final DraftSaveTracker _draftSaves;
  bool _leaving = false;
  bool _justSaved = false;
  String get _key => 'form.$_caseId.${widget.program.programId}';
  @override
  void initState() {
    super.initState();
    _caseId = widget.services.coordinator.currentCase().caseId;
    _generation = widget.services.coordinator.generation;
    _draftSaves = DraftSaveTracker(isCurrent: () => _scopeCurrent);
    for (final key in formAnswerValueLimits.keys) {
      _fields[key] = TextEditingController();
      _reviewed[key] = false;
    }
    _read(initial: true);
  }

  @override
  void dispose() {
    _draftSaves.dispose();
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Iterable<String> get _activeKeys =>
      _answers?.fieldDefinitions.map((field) => field.key) ?? const <String>[];
  FormAnswerFieldDefinition _definition(String key) =>
      _answers!.fieldDefinitions.firstWhere((field) => field.key == key);

  bool get _scopeCurrent {
    final c = widget.services.coordinator;
    return mounted &&
        c.isCurrent &&
        c.generation == _generation &&
        c.snapshot?.caseId == _caseId &&
        !c.hasUnsavedChanges;
  }

  CaseSnapshot _screenCase({int? generation}) {
    final c = widget.services.coordinator;
    if (!_scopeCurrent || (generation != null && c.generation != generation)) {
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
    return c.currentCase();
  }

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
    final snapshot = _screenCase();
    final value = <String, Object?>{
      'values': {for (final key in _fields.keys) key: _fields[key]!.text},
      'reviewed': Map<String, bool>.of(_reviewed),
      'uncertain': _uncertain,
      'caseRevision': snapshot.revision,
      'formContextId': _answers?.context.formContextId,
    };
    await _draftSaves.track(() => widget.services.store.writeJson(_key, value));
  }

  Future<void> _read({bool initial = false}) async {
    if (_leaving) return;
    setState(() {
      _busy = true;
      _feedbackAtAction = false;
    });
    try {
      final c = widget.services.coordinator;
      final openingGeneration = c.generation;
      _screenCase(generation: openingGeneration);
      if (initial) _restoredDraft = await widget.services.store.readJson(_key);
      _screenCase(generation: openingGeneration);
      final local = _restoredDraft;
      if (local != null) {
        final values = local['values'] as Map;
        for (final key in _fields.keys) {
          _fields[key]!.text = values[key] as String? ?? '';
        }
        _uncertain = local['uncertain'] == true;
      }
      if (!initial || _uncertain) {
        final remote = await widget.services.answers.reloadCase(
          _caseId,
          currentCase: () => _screenCase(generation: openingGeneration),
        );
        await c.adoptRemoteSnapshot(remote);
      }
      final generation = c.generation;
      final response = await widget.services.answers.readAnswers(
        _screenCase(generation: generation),
        programId: widget.program.programId,
        currentCase: () => _screenCase(generation: generation),
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
        final currentReview = same && response.isCurrent;
        _error = !response.isCurrent
            ? 'Saved answers are from an earlier case or form. Your values remain below; review them again before saving.'
            : same
            ? 'Your answers were saved.'
            : 'Saved state reloaded. Your local answers remain below; review them before saving again.';
        if (!currentReview) {
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
    if (_leaving || _answers == null || _uncertain || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _feedbackAtAction = true;
    });
    try {
      final c = widget.services.coordinator;
      final generation = c.generation;
      final saved = _screenCase(generation: generation);
      final inputs = _inputs();
      _uncertain = true;
      await _persist();
      _screenCase(generation: generation);
      await c.serialize(() async {
        _screenCase(generation: generation);
        final response = await widget.services.answers.saveAnswers(
          saved,
          context: _answers!.context,
          expectedAnswerRevision: _answers!.saved?.answerRevision ?? 0,
          answers: inputs,
          currentCase: () => _screenCase(generation: generation),
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
        _justSaved = true;
      }
    } catch (error) {
      if (mounted) _error = safeOperationMessage(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edited(String key) async {
    if (_leaving || _busy || !_scopeCurrent) return;
    setState(() {
      _reviewed[key] = false;
      _error = null;
      _justSaved = false;
    });
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
  Widget build(BuildContext context) => DraftExitGuard(
    tracker: _draftSaves,
    builder: (context, requestExit, exiting) {
      _leaving = exiting;
      return SahKeyboardDismissal(
        child: Scaffold(
          appBar: AppBar(
            leading: BackButton(onPressed: requestExit),
            title: Text(context.tr('Administrative answers')),
          ),
          body: SafeArea(
            child: SahContent(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SahPageHeader(
                      title: widget.program.programName,
                      description: context.tr(
                        'Check details that may appear in your draft.',
                      ),
                    ),
                    if (Localizations.localeOf(context).languageCode != 'en')
                      SahNotice(
                        message: context.tr(
                          'Program information and official forms may remain in English. Your saved answers are not translated.',
                        ),
                      ),
                    SahMoreInfo(
                      details: [
                        context.tr(
                          'These answers do not supply diagnoses, medical necessity, consent or signatures. Review each supplied value yourself.',
                        ),
                      ],
                    ),
                    if (_busy)
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: LinearProgressIndicator(
                          semanticsLabel: context.tr(
                            'Updating administrative answers',
                          ),
                        ),
                      ),
                    if (_error != null && !_feedbackAtAction)
                      SahNotice(message: context.tr(_error!)),
                    if (_uncertain)
                      SahNotice(
                        title: context.tr('Check the last save'),
                        message: context.tr(
                          'A save may have succeeded. Check saved answers before another save.',
                        ),
                        tone: SahNoticeTone.warning,
                      ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      key: const ValueKey('form-reconcile'),
                      onPressed: _busy || exiting ? null : () => _read(),
                      child: Text(
                        context.tr('Reload saved answers and reconcile'),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    if (_answers != null) ...[
                      SahStatusBadge(
                        label: _answers!.artifactKind == 'preparation_worksheet'
                            ? context.tr('Worksheet · not an official form')
                            : context.tr('Official-form draft · not submitted'),
                        icon: Icons.description_outlined,
                      ),
                      if (!_answers!.isCurrent)
                        SahNotice(
                          message: context.tr(
                            'Saved answers need review for the current case and form.',
                          ),
                          tone: SahNoticeTone.warning,
                        ),
                      SahSectionHeading(
                        title: context.tr('Review your answers'),
                        description: context.tr(
                          '{reviewed} of {total} checked · blank stays unknown',
                          {
                            'reviewed': _activeKeys
                                .where(
                                  (key) =>
                                      _fields[key]!.text.trim().isNotEmpty &&
                                      _reviewed[key] == true,
                                )
                                .length,
                            'total': _activeKeys
                                .where(
                                  (key) => _fields[key]!.text.trim().isNotEmpty,
                                )
                                .length,
                          },
                        ),
                      ),
                      for (final key in _activeKeys)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ExcludeSemantics(
                                child: Text(
                                  administrativeFieldLabel(
                                    context,
                                    widget.program.programId,
                                    _definition(key),
                                  ),
                                  key: ValueKey('form-label-$key'),
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _fields[key],
                                enabled: !_busy && !exiting,
                                autocorrect: false,
                                textInputAction: TextInputAction.next,
                                keyboardType: switch (_definition(key).kind) {
                                  'date' => TextInputType.datetime,
                                  'email' => TextInputType.emailAddress,
                                  _ => TextInputType.text,
                                },
                                decoration: InputDecoration(
                                  labelText: administrativeFieldLabel(
                                    context,
                                    widget.program.programId,
                                    _definition(key),
                                  ),
                                  helperText: _definition(key).kind == 'date'
                                      ? 'YYYY-MM-DD'
                                      : null,
                                  counterText: '',
                                ),
                                maxLength: _definition(key).maxLength,
                                onChanged: (_) => _edited(key),
                              ),
                              CheckboxListTile(
                                key: ValueKey('form-review-$key'),
                                contentPadding: EdgeInsets.zero,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: Text(
                                  context.tr('I reviewed this value'),
                                  semanticsLabel: context
                                      .tr('I reviewed {field}', {
                                        'field': administrativeFieldLabel(
                                          context,
                                          widget.program.programId,
                                          _definition(key),
                                        ),
                                      }),
                                ),
                                value: _reviewed[key] ?? false,
                                onChanged:
                                    _busy ||
                                        exiting ||
                                        _fields[key]!.text.trim().isEmpty
                                    ? null
                                    : (v) async {
                                        if (_leaving ||
                                            _busy ||
                                            !_scopeCurrent) {
                                          return;
                                        }
                                        setState(() {
                                          _reviewed[key] = v ?? false;
                                          _error = null;
                                        });
                                        try {
                                          await _persist();
                                        } catch (error) {
                                          if (context.mounted) {
                                            await showOperationError(
                                              context,
                                              error,
                                            );
                                          }
                                        }
                                      },
                              ),
                            ],
                          ),
                        ),
                      if (_error != null && _feedbackAtAction)
                        SahActionFeedback(
                          key: const ValueKey('form-save-feedback'),
                          message: context.tr(_error!),
                        ),
                      if (_justSaved && widget.onNext != null)
                        FilledButton(
                          key: const ValueKey('form-next'),
                          onPressed: exiting ? null : widget.onNext,
                          child: Text(context.tr('Continue')),
                        )
                      else
                        FilledButton(
                          key: const ValueKey('form-save'),
                          onPressed: _busy || _uncertain || exiting
                              ? null
                              : _save,
                          child: Text(
                            context.tr('Save reviewed administrative answers'),
                            textAlign: TextAlign.center,
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
