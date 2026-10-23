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
  final _fieldAnchors = <String, GlobalKey>{};
  final _fieldFocus = <String, FocusNode>{};
  final _validationErrors = <String, String>{};
  bool _onlineContext = false;
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
      _fieldAnchors[key] = GlobalKey();
      _fieldFocus[key] = FocusNode();
    }
    _read(initial: true);
  }

  @override
  void dispose() {
    _draftSaves.dispose();
    for (final field in _fields.values) {
      field.dispose();
    }
    for (final focus in _fieldFocus.values) {
      focus.dispose();
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
      'response': _answers?.toJson(),
    };
    if (!_onlineContext) _restoredDraft = value;
    await _draftSaves.track(() => widget.services.store.writeJson(_key, value));
  }

  void _restoreCached(Map<String, Object?> local) {
    final raw = local['response'];
    if (raw == null) return; // Older journals need one online reload.
    final response = raw is Map && raw['schemaVersion'] == '2'
        ? FormAnswersResponse.fromV2Json(raw)
        : FormAnswersResponse.fromJson(raw);
    if (response.caseId != _caseId ||
        response.context.programId != widget.program.programId ||
        response.caseRevision > _screenCase().revision) {
      throw const FormatException('Private form context does not match.');
    }
    final values = local['values'] as Map;
    for (final key in _fields.keys) {
      final value = values[key];
      if (value != null && value is! String) {
        throw const FormatException('Invalid private form value.');
      }
    }
    _answers = response;
    for (final key in _activeKeys) {
      final value = values[key];
      _fields[key]!.text = value as String? ?? '';
      // Offline context is useful for editing, never proof of current review.
      _reviewed[key] = false;
    }
    _uncertain = local['uncertain'] == true;
  }

  Future<void> _read({bool initial = false}) async {
    if (_leaving) return;
    setState(() {
      _busy = true;
      _feedbackAtAction = false;
      _onlineContext = false;
    });
    try {
      final c = widget.services.coordinator;
      final openingGeneration = c.generation;
      _screenCase(generation: openingGeneration);
      if (initial) _restoredDraft = await widget.services.store.readJson(_key);
      _screenCase(generation: openingGeneration);
      final local = _restoredDraft;
      if (local != null) {
        _restoreCached(local);
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
      _validationErrors.clear();
      _onlineContext = true;
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
      }
      if (_uncertain || !initial) {
        final saved = {
          for (final answer in response.saved?.answers ?? <SavedFormAnswer>[])
            answer.key: {
              'key': answer.key,
              'value': answer.value,
              'reviewState': answer.reviewState,
            },
        };
        final same =
            _validateAnswers().isEmpty &&
            _inputs().every(
              (answer) =>
                  jsonEncode(saved[answer.key]) == jsonEncode(answer.toJson()),
            );
        _uncertain = false;
        final currentReview = same && response.isCurrent;
        _error = response.saved != null && !response.isCurrent
            ? 'Saved answers are from an earlier case or form. Your values remain below; review them again before saving.'
            : same
            ? 'Your answers were saved.'
            : 'Saved state reloaded. Your local answers remain below; review them before saving again.';
        if (!currentReview) {
          for (final key in _reviewed.keys) {
            _reviewed[key] = false;
          }
        }
      }
      await _persist();
    } catch (error) {
      if (mounted) _error = safeOperationMessage(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, String> _validateAnswers() {
    final errors = <String, String>{};
    final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    for (final key in _activeKeys) {
      final value = _fields[key]!.text.trim();
      if (value.isEmpty) continue;
      try {
        FormAnswerInput.fromJson({
          'key': key,
          'value': value,
          'reviewState': 'needs_review',
        });
        if (_definition(key).kind == 'date' && value.compareTo(today) > 0) {
          errors[key] = 'Enter a date on or before today.';
        }
      } catch (_) {
        errors[key] = switch (_definition(key).kind) {
          'date' => 'Enter a valid date as YYYY-MM-DD, or leave blank.',
          'email' => 'Enter a valid email address, or leave blank.',
          _ => 'Check this answer or leave it blank.',
        };
      }
    }
    final birth = _fields['memberBirthDate']!.text.trim();
    final referral = _fields['referralDate']!.text.trim();
    if (_activeKeys.contains('memberBirthDate') &&
        _activeKeys.contains('referralDate') &&
        !errors.containsKey('memberBirthDate') &&
        !errors.containsKey('referralDate') &&
        birth.isNotEmpty &&
        referral.isNotEmpty &&
        birth.compareTo(referral) > 0) {
      errors['memberBirthDate'] =
          'Birth date must be on or before the referral date.';
    }
    return errors;
  }

  void _reviewInvalid() {
    if (_validationErrors.isEmpty || _busy || !_scopeCurrent) return;
    final key = _validationErrors.keys.first;
    _fieldFocus[key]!.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scopeCurrent) return;
      final target = _fieldAnchors[key]!.currentContext;
      if (target != null) Scrollable.ensureVisible(target, alignment: .1);
    });
  }

  Future<void> _save() async {
    if (_leaving ||
        !_onlineContext ||
        _answers == null ||
        _uncertain ||
        _busy) {
      return;
    }
    final errors = _validateAnswers();
    setState(() {
      _validationErrors
        ..clear()
        ..addAll(errors);
      _justSaved = false;
      _error = null;
    });
    if (errors.isNotEmpty) {
      _reviewInvalid();
      return;
    }
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
        _error = 'Answers saved.';
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
      if (_validationErrors.isNotEmpty) {
        _validationErrors
          ..clear()
          ..addAll(_validateAnswers());
      }
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
                    SahPageHeader(title: widget.program.programName),
                    if (Localizations.localeOf(context).languageCode != 'en')
                      SahNotice(
                        message: context.tr(
                          'Program information and official forms may remain in English. Your saved answers are not translated.',
                        ),
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
                      if (!_onlineContext)
                        SahNotice(
                          key: const ValueKey('form-offline-context'),
                          message: context.tr(
                            'These answers are kept on this device. Reconnect and reload before saving online.',
                          ),
                        ),
                      SahStatusBadge(
                        label: _answers!.artifactKind == 'preparation_worksheet'
                            ? context.tr('Worksheet · not an official form')
                            : context.tr('Official-form draft · not submitted'),
                        icon: Icons.description_outlined,
                      ),
                      if (_onlineContext &&
                          _answers!.saved != null &&
                          !_answers!.isCurrent)
                        SahNotice(
                          message: context.tr(
                            'Saved answers need review for the current case and form.',
                          ),
                          tone: SahNoticeTone.warning,
                        ),
                      SahSectionHeading(
                        title: context.tr('Review your answers'),
                        description:
                            _activeKeys.every(
                              (key) => _fields[key]!.text.trim().isEmpty,
                            )
                            ? context.tr(
                                'Enter what you know. Leave unknown answers blank, then review each value you enter.',
                              )
                            : context.tr('{reviewed} of {total} checked', {
                                'reviewed': _activeKeys
                                    .where(
                                      (key) =>
                                          _fields[key]!.text
                                              .trim()
                                              .isNotEmpty &&
                                          _reviewed[key] == true,
                                    )
                                    .length,
                                'total': _activeKeys
                                    .where(
                                      (key) =>
                                          _fields[key]!.text.trim().isNotEmpty,
                                    )
                                    .length,
                              }),
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
                                key: _fieldAnchors[key],
                                focusNode: _fieldFocus[key],
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
                                  error: _validationErrors[key] == null
                                      ? null
                                      : Text(
                                          context.tr(_validationErrors[key]!),
                                        ),
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
                      if (_validationErrors.isNotEmpty) ...[
                        SahNotice(
                          key: const ValueKey('form-validation-feedback'),
                          title: context.tr('Check this answer'),
                          message:
                              '${administrativeFieldLabel(context, widget.program.programId, _definition(_validationErrors.keys.first))}: ${context.tr(_validationErrors.values.first)}',
                          tone: SahNoticeTone.error,
                        ),
                        OutlinedButton(
                          onPressed: _reviewInvalid,
                          child: Text(context.tr('Review this answer')),
                        ),
                      ],
                      FilledButton(
                        key: const ValueKey('form-save'),
                        onPressed:
                            _busy || !_onlineContext || _uncertain || exiting
                            ? null
                            : () async {
                                await _save();
                                if (mounted && _justSaved) {
                                  (widget.onNext ?? requestExit)();
                                }
                              },
                        child: Text(
                          context.tr(
                            widget.onNext == null
                                ? 'Save'
                                : 'Save and continue',
                          ),
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
