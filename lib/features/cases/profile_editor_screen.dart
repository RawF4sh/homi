import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import '../../app/live_app.dart';
import 'profile_suggestion_field.dart';
import 'profile_suggestions.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/presentation/draft_exit_guard.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/services/draft_save_tracker.dart';
import '../../shared/services/matching_api_client.dart';

class ProfileEditorScreen extends StatefulWidget {
  const ProfileEditorScreen({super.key, required this.services});
  final AppServices services;
  @override
  State<ProfileEditorScreen> createState() => _ProfileEditorScreenState();
}

class _ProfileEditorScreenState extends State<ProfileEditorScreen> {
  final _form = GlobalKey<FormState>();
  final _scroll = ScrollController();
  final _fields = <String, TextEditingController>{};
  final _fieldAnchors = <String, GlobalKey>{};
  final _fieldFocus = <String, FocusNode>{};
  final _errors = <String, String>{};
  int _validationAttempt = 0;
  String? _tenure;
  bool? _consent;
  bool _saving = false, _restoring = true;
  bool _leaving = false;
  late final DraftSaveTracker _draftSaves;
  VoidCallback? _requestExit;
  String? _notice;
  String? _countyAutofillCity;
  bool _confirmingCounty = false;
  late final String _caseId;
  late final int _generation;
  late int? _baseRevision;
  late Map<String, Object?> _baseProfile;
  late String _baseFingerprint;
  Timer? _autosaveTimer;
  Future<void>? _journalWrite;
  bool _needsLocalPromotion = false;
  Completer<void>? _onlineSave;
  bool _syncFailed = false, _syncRequested = false;
  int _editVersion = 0;
  String? _pendingProfileFingerprint;
  Map<String, Object?>? _recovered;
  int _fieldVersion = 0;
  String get _editKey => 'profile-edit.$_caseId';
  static const labels = {
    'city': 'City',
    'county': 'County',
    'healthPlan': 'Health plan',
    'ageYears': 'Age in years',
    'householdSize': 'People in household',
    'annualIncomeUsd': 'Annual household income (USD)',
  };
  @override
  void initState() {
    super.initState();
    final c = widget.services.coordinator;
    _caseId = c.currentDraft().caseId;
    _generation = c.generation;
    _baseRevision = c.snapshot?.revision;
    _baseProfile = c.currentDraft().profile.toJson();
    _baseFingerprint = _fingerprint(_baseProfile);
    _draftSaves = DraftSaveTracker(isCurrent: () => _sameBase);
    final p = _baseProfile;
    for (final key in labels.keys) {
      _fields[key] = TextEditingController(text: p[key]?.toString() ?? '');
      _fieldAnchors[key] = GlobalKey();
      _fieldFocus[key] = FocusNode();
    }
    _tenure = p['tenure'] as String?;
    _consent = p['ownerConsentReported'] as bool?;
    c.addListener(_caseChanged);
    _restore();
  }

  @override
  void dispose() {
    widget.services.coordinator.removeListener(_caseChanged);
    _cancelAutosave();
    _draftSaves.dispose();
    _scroll.dispose();
    for (final field in _fields.values) {
      field.dispose();
    }
    for (final focus in _fieldFocus.values) {
      focus.dispose();
    }
    super.dispose();
  }

  String _fingerprint(Map<String, Object?> profile) {
    final entries = profile.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return sha256
        .convert(utf8.encode(jsonEncode(Map.fromEntries(entries))))
        .toString();
  }

  bool get _selected => mounted && _scopeCurrent;

  bool get _scopeCurrent {
    final c = widget.services.coordinator;
    return c.isCurrent &&
        c.generation == _generation &&
        c.draft?.caseId == _caseId;
  }

  bool get _sameBase {
    final c = widget.services.coordinator;
    if (!_selected || c.snapshot?.revision != _baseRevision) return false;
    final fingerprint = _fingerprint(c.draft!.profile.toJson());
    return fingerprint == _baseFingerprint ||
        fingerprint == _pendingProfileFingerprint;
  }

  bool get _editable =>
      !_saving && !_restoring && !_leaving && _recovered == null && _sameBase;

  void _requireBase() {
    if (!_sameBase) throw MatchingApiException.forCode('STALE_RESPONSE');
  }

  void _requireExactDraft(Set<String> allowedFingerprints) {
    _requireBase();
    final current = widget.services.coordinator.currentDraft();
    if (!allowedFingerprints.contains(_fingerprint(current.toJson()))) {
      setState(() {
        _notice =
            'The case changed while these edits were being saved. Your unfinished entries are still here. Review the current case before trying to keep them again.';
      });
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
  }

  void _caseChanged() {
    if (mounted) setState(() {});
    if (_syncRequested && _onlineSave == null) {
      scheduleMicrotask(() => unawaited(_saveOnline()));
    }
  }

  Map<String, Object?> _parseEdits(Map<String, Object?> saved) {
    final values = saved['values'];
    if (values is! Map ||
        !{null, 'owner', 'renter'}.contains(saved['tenure']) ||
        saved['consent'] != null && saved['consent'] is! bool) {
      throw const FormatException('Invalid private profile edits.');
    }
    final restored = <String, Object?>{};
    for (final key in labels.keys) {
      final value = values[key];
      if (value != null && value is! String) {
        throw const FormatException('Invalid private profile value.');
      }
      restored[key] = value ?? '';
    }
    return {
      'values': restored,
      'tenure': saved['tenure'],
      'consent': saved['consent'],
    };
  }

  void _applyEdits(Map<String, Object?> value) {
    final values = value['values'] as Map;
    for (final key in labels.keys) {
      _fields[key]!.text = values[key] as String;
    }
    _tenure = value['tenure'] as String?;
    _consent = value['consent'] as bool?;
    _fieldVersion++;
  }

  Map<String, Object?> _journal([Map<String, Object?>? edits]) => {
    'version': 2,
    'caseId': _caseId,
    'baseCaseRevision': _baseRevision,
    'baseProfileFingerprint': _baseFingerprint,
    ...?edits,
    if (edits == null) ...{
      'values': {for (final key in labels.keys) key: _fields[key]!.text},
      'tenure': _tenure,
      'consent': _consent,
    },
  };

  Future<void> _restore() async {
    try {
      final saved = await widget.services.store.readJson(_editKey);
      _requireBase();
      if (saved != null) {
        if (saved['version'] == 2 && saved['caseId'] != _caseId) {
          throw const FormatException('Profile edits belong to another case.');
        }
        final edits = _parseEdits(saved);
        if (saved['version'] == 2 &&
            saved['caseId'] == _caseId &&
            saved['baseCaseRevision'] == _baseRevision &&
            saved['baseProfileFingerprint'] == _baseFingerprint) {
          _applyEdits(edits);
          _needsLocalPromotion = true;
          _notice = 'Recovered unfinished edits from this device.';
        } else {
          _recovered = edits;
          _notice =
              'Unfinished edits need comparison before continuing. Neither set of details has been replaced.';
        }
      }
    } catch (_) {
      if (mounted) {
        _notice =
            'Unfinished edits could not be restored. The current case details are shown; check them before continuing.';
      }
    }
    if (mounted) {
      setState(() => _restoring = false);
      if (_needsLocalPromotion && _editable) _scheduleAutosave();
    }
  }

  void _stash() {
    if (!_editable) return;
    _editVersion++;
    _needsLocalPromotion = true;
    unawaited(
      _persistJournal().catchError((Object _) {
        if (_selected) {
          setState(
            () => _notice =
                'Edits could not be saved on this device. Keep this screen open and retry.',
          );
        }
      }),
    );
    _scheduleAutosave();
  }

  void _cancelAutosave() {
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
  }

  void _scheduleAutosave() {
    _cancelAutosave();
    final version = _editVersion;
    _autosaveTimer = Timer(const Duration(milliseconds: 800), () async {
      _autosaveTimer = null;
      if (_confirmingCounty || version != _editVersion || !_sameBase) return;
      await _flushEdits();
    });
  }

  Future<void> _flushEdits() async {
    _cancelAutosave();
    if (!_needsLocalPromotion || _saving || _draftSaves.failed || !_sameBase) {
      return;
    }
    try {
      await _journalWrite;
    } catch (_) {
      return;
    }
    if (_needsLocalPromotion && _sameBase) await _save(automatic: true);
  }

  Future<void> _persistJournal([Map<String, Object?>? edits]) {
    final value = Map<String, Object?>.from(
      jsonDecode(jsonEncode(_journal(edits))) as Map,
    );
    final key = _editKey;
    final write = _draftSaves.track(() {
      _requireBase();
      return widget.services.store.writeJson(key, value);
    });
    _journalWrite = write;
    return write;
  }

  Future<void> _chooseRecovery({required bool useRecovered}) async {
    if (_saving || _restoring || _leaving || _recovered == null || !_sameBase) {
      return;
    }
    final recovered = _recovered!;
    setState(() => _saving = true);
    try {
      _requireBase();
      if (useRecovered) {
        await _persistJournal(recovered);
      } else {
        final c = widget.services.coordinator;
        final chosen = c.currentDraft();
        final chosenFingerprint = _fingerprint(chosen.toJson());
        await _draftSaves.track(() async {
          _requireExactDraft({chosenFingerprint});
          if (c.localSaveFailed || c.localWritePending) {
            await c.updateDraft(chosen);
            _requireExactDraft({chosenFingerprint});
          }
          await widget.services.store.delete(_editKey);
        });
      }
      _requireBase();
      if (useRecovered) _applyEdits(recovered);
      _recovered = null;
      _notice = useRecovered
          ? 'Recovered edits are ready to review. Check the fields before keeping them in this case.'
          : 'Current case details kept. The unfinished edits were removed from this device.';
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (error) {
      if (_selected) _notice = safeOperationMessage(error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _validateField(String key) {
    final text = _fields[key]!.text.trim();
    if (text.isEmpty) return null;
    if (['ageYears', 'householdSize'].contains(key)) {
      final n = int.tryParse(text);
      if (n == null ||
          n < (key == 'householdSize' ? 1 : 0) ||
          n > 9007199254740991) {
        return 'Enter a whole number in the supported range.';
      }
    }
    if (key == 'annualIncomeUsd') {
      final n = num.tryParse(text);
      if (n == null || !n.isFinite || n < 0) {
        return 'Enter a nonnegative amount.';
      }
    }
    if (text.length > 200) return 'Use at most 200 characters.';
    return null;
  }

  void _reviewInvalid() {
    if (!_editable || _errors.isEmpty) return;
    final key = _errors.keys.first;
    _fieldFocus[key]!.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_editable) return;
      final target = _fieldAnchors[key]!.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(target, alignment: 0.1);
      }
    });
  }

  Future<void> _save({bool automatic = false}) async {
    if (automatic) {
      if (_saving || _restoring || _recovered != null || !_sameBase) return;
    } else {
      if (!_editable) return;
      _cancelAutosave();
    }
    final errors = <String, String>{};
    for (final key in labels.keys) {
      final error = _validateField(key);
      if (error != null) errors[key] = error;
    }
    setState(() {
      _validationAttempt++;
      _errors
        ..clear()
        ..addAll(errors);
    });
    if (errors.isNotEmpty) return;
    setState(() => _saving = true);
    try {
      _requireBase();
      final c = widget.services.coordinator;
      final value = c.currentDraft().toJson();
      final beforeFingerprint = _fingerprint(value);
      final p = <String, Object?>{};
      for (final key in labels.keys) {
        final text = _fields[key]!.text.trim();
        p[key] = text.isEmpty
            ? null
            : switch (key) {
                'ageYears' || 'householdSize' => int.parse(text),
                'annualIncomeUsd' => num.parse(text),
                _ => text,
              };
      }
      p['tenure'] = _tenure;
      p['ownerConsentReported'] = _consent;
      value['profile'] = p;
      final changed = CaseDraft.fromJson(value);
      final changedFingerprint = _fingerprint(changed.toJson());
      _pendingProfileFingerprint = _fingerprint(changed.profile.toJson());
      final changedProfile = _pendingProfileFingerprint != _baseFingerprint;
      await _draftSaves.track(() async {
        _requireExactDraft({beforeFingerprint, changedFingerprint});
        if (beforeFingerprint != changedFingerprint || c.hasUndurableEdits) {
          await c.updateDraft(changed);
        }
        _requireExactDraft({changedFingerprint});
        await widget.services.store.delete(_editKey);
      });
      _requireBase();
      _baseProfile = changed.profile.toJson();
      _baseFingerprint = _fingerprint(_baseProfile);
      _pendingProfileFingerprint = null;
      _needsLocalPromotion = false;
      _notice = null;
      if (changedProfile) {
        _syncRequested = true;
        unawaited(_saveOnline());
      }
      if (!automatic &&
          mounted &&
          _selected &&
          ModalRoute.of(context)?.isCurrent == true) {
        _requestExit?.call();
      }
    } catch (error) {
      if (mounted) {
        if (automatic) {
          setState(() => _notice = safeOperationMessage(error));
        } else {
          await showOperationError(context, error);
        }
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveOnline() async {
    final c = widget.services.coordinator;
    if (!_scopeCurrent ||
        _onlineSave != null ||
        c.busy ||
        c.hasUndurableEdits ||
        c.uncertain ||
        c.conflict ||
        c.snapshot?.revision != _baseRevision ||
        _fingerprint(c.currentDraft().profile.toJson()) != _baseFingerprint ||
        !c.hasUnsavedChanges) {
      return;
    }
    final sentProfile = _baseFingerprint;
    final sentRevision = _baseRevision ?? 0;
    final finished = Completer<void>();
    _onlineSave = finished;
    _syncRequested = false;
    _syncFailed = false;
    try {
      await c.save();
      if (_scopeCurrent) _notice = null;
    } catch (error) {
      if (_scopeCurrent) {
        _syncFailed = true;
        _notice = safeOperationMessage(error);
      }
    } finally {
      if (_scopeCurrent &&
          !c.uncertain &&
          !c.conflict &&
          c.snapshot?.revision == sentRevision + 1) {
        final currentProfile = _fingerprint(c.currentDraft().profile.toJson());
        if ((currentProfile == _baseFingerprint ||
                currentProfile == _pendingProfileFingerprint) &&
            _fingerprint(c.currentCase().profile.toJson()) == sentProfile) {
          _baseRevision = c.snapshot!.revision;
          if (mounted && _needsLocalPromotion && !_saving) {
            unawaited(_persistJournal().catchError((Object _) {}));
          }
        }
      }
      if (identical(_onlineSave, finished)) _onlineSave = null;
      finished.complete();
      if (mounted) setState(() {});
      if (_syncRequested && !_syncFailed && _scopeCurrent) {
        unawaited(_saveOnline());
      }
    }
  }

  String get _saveStatus {
    final c = widget.services.coordinator;
    if (_restoring) return context.tr('Opening resident details…');
    if (_recovered != null) {
      return context.tr('Compare the two copies before continuing.');
    }
    if (!_sameBase && _onlineSave == null) {
      return context.tr('Review the changed case.');
    }
    if (_draftSaves.failed || c.localSaveFailed) {
      return context.tr(
        'Device save needs attention. Your entries are still here.',
      );
    }
    if (_errors.isNotEmpty) {
      return context.tr(
        'Entries kept on this device. Correct the highlighted answer to sync.',
      );
    }
    if (_draftSaves.pending || _saving) {
      return context.tr('Saving changes on this device…');
    }
    if (_onlineSave != null) {
      return context.tr('Saved on this device · syncing online…');
    }
    if (c.conflict || c.uncertain) {
      return context.tr(
        'Saved on this device · check saved state from your case.',
      );
    }
    if (_syncFailed || c.hasUnsavedChanges) {
      return context.tr('Saved on this device.');
    }
    return context.tr('Saved online · changes save automatically.');
  }

  String _display(Object? value, {bool housing = false}) => switch (value) {
    null => context.tr('Unknown'),
    true => context.tr('Yes'),
    false => context.tr('No'),
    'owner' when housing => context.tr('Own'),
    'renter' when housing => context.tr('Rent'),
    String text when text.trim().isEmpty => context.tr('Unknown'),
    _ => value.toString(),
  };

  Widget _comparison() {
    final edits = _recovered!;
    final values = <String, Object?>{
      ...Map<String, Object?>.from(edits['values'] as Map),
      'tenure': edits['tenure'],
      'ownerConsentReported': edits['consent'],
    };
    return Column(
      key: const ValueKey('profile-recovery-comparison'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SahSectionHeading(
          title: context.tr('Compare unfinished edits'),
          description: context.tr(
            'Choose which details to review. This does not save anything online.',
          ),
        ),
        for (final entry in {
          ...labels,
          'tenure': 'Own or rent',
          'ownerConsentReported': 'Owner permission reported',
        }.entries)
          Padding(
            key: ValueKey('profile-comparison-${entry.key}'),
            padding: const EdgeInsets.only(bottom: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr(entry.value),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  context.tr('Current: {value}', {
                    'value': _display(
                      _baseProfile[entry.key],
                      housing: entry.key == 'tenure',
                    ),
                  }),
                ),
                Text(
                  context.tr('Unfinished: {value}', {
                    'value': _display(
                      values[entry.key],
                      housing: entry.key == 'tenure',
                    ),
                  }),
                ),
              ],
            ),
          ),
        OutlinedButton(
          key: const ValueKey('profile-keep-current'),
          onPressed: _saving || _leaving || !_sameBase
              ? null
              : () => _chooseRecovery(useRecovered: false),
          child: Text(
            context.tr('Keep current details'),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const ValueKey('profile-review-recovered'),
          onPressed: _saving || _leaving || !_sameBase
              ? null
              : () => _chooseRecovery(useRecovered: true),
          child: Text(
            context.tr('Review recovered edits'),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  void _fieldChanged(String key) {
    if (!_editable) return;
    if (_errors.containsKey(key) ||
        (_countyAutofillCity != null && (key == 'city' || key == 'county'))) {
      setState(() {
        if (key == 'city' || key == 'county') _countyAutofillCity = null;
        final error = _validateField(key);
        if (error == null) {
          _errors.remove(key);
        } else {
          _errors[key] = error;
        }
      });
    }
    _stash();
  }

  void _applySuggestionValues(
    Map<String, String> values, {
    String? countyCity,
  }) {
    if (!_editable) return;
    for (final entry in values.entries) {
      _fields[entry.key]!.value = TextEditingValue(
        text: entry.value,
        selection: TextSelection.collapsed(offset: entry.value.length),
      );
    }
    setState(() {
      if (values.containsKey('city') || values.containsKey('county')) {
        _countyAutofillCity = countyCity;
      }
      for (final key in values.keys) {
        if (!_errors.containsKey(key)) continue;
        final error = _validateField(key);
        if (error == null) {
          _errors.remove(key);
        } else {
          _errors[key] = error;
        }
      }
    });
    _stash();
  }

  Future<void> _selectSuggestion(
    String key,
    ProfileSuggestion suggestion,
  ) async {
    if (!_editable || _confirmingCounty) return;
    final county = key == 'city' ? suggestion.county : null;
    final currentCounty = _fields['county']!.text;
    if (county == null) {
      _applySuggestionValues({key: suggestion.value});
      return;
    }
    if (currentCounty.trim().isEmpty) {
      _applySuggestionValues({
        'city': suggestion.value,
        'county': county,
      }, countyCity: suggestion.value);
      return;
    }
    _applySuggestionValues({'city': suggestion.value});
    if (canonicalProfileCounty(currentCounty) == county) return;
    _confirmingCounty = true;
    try {
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      context.tr('Update county?'),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    context.tr(
                      '{city} is in {county} County. Replace your current county, “{currentCounty}”, with “{county}”?',
                      {
                        'city': suggestion.value,
                        'county': county,
                        'currentCounty': currentCounty,
                      },
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    key: const ValueKey('profile-use-city-county'),
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(
                      context.tr('Use {county}', {'county': county}),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    key: const ValueKey('profile-keep-existing-county'),
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(
                      context.tr('Keep current county'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      if (replace == true &&
          _editable &&
          _fields['city']!.text == suggestion.value &&
          _fields['county']!.text == currentCounty) {
        _applySuggestionValues({
          'county': county,
        }, countyCity: suggestion.value);
      }
    } finally {
      _confirmingCounty = false;
      if (_needsLocalPromotion && _editable) _scheduleAutosave();
    }
  }

  Widget _profileField(String key) {
    final field = TextFormField(
      key: _fieldAnchors[key],
      controller: _fields[key],
      focusNode: _fieldFocus[key],
      forceErrorText: _errors[key] == null ? null : context.tr(_errors[key]!),
      enabled: _editable,
      onChanged: (_) => _fieldChanged(key),
      decoration: InputDecoration(
        labelText: context.tr(labels[key]!),
        helperMaxLines: 4,
        helperText: key == 'county' && _countyAutofillCity != null
            ? context.tr('Filled from {city}. You can change it.', {
                'city': _countyAutofillCity,
              })
            : key == 'annualIncomeUsd'
            ? context.tr('Yearly household total, US dollars')
            : ['city', 'county', 'healthPlan'].contains(key)
            ? context.tr('Type for suggestions, or enter another name.')
            : null,
      ),
      textInputAction: TextInputAction.next,
      keyboardType:
          ['ageYears', 'householdSize', 'annualIncomeUsd'].contains(key)
          ? TextInputType.numberWithOptions(decimal: key == 'annualIncomeUsd')
          : TextInputType.text,
    );
    if (!['city', 'county', 'healthPlan'].contains(key)) return field;
    return ProfileSuggestionField(
      field: key,
      controller: _fields[key]!,
      enabled: _editable,
      onSelected: (suggestion) => _selectSuggestion(key, suggestion),
      child: field,
    );
  }

  @override
  Widget build(BuildContext context) => DraftExitGuard(
    tracker: _draftSaves,
    beforeExit: _flushEdits,
    builder: (context, requestExit, exiting) {
      _leaving = exiting;
      _requestExit = requestExit;
      return Scaffold(
        appBar: AppBar(
          leading: Navigator.of(context).canPop()
              ? BackButton(onPressed: requestExit)
              : null,
          title: Text(context.tr('Resident details')),
        ),
        body: SafeArea(
          child: Form(
            key: _form,
            child: SahContent(
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SahPageHeader(
                      title: context.tr('About the resident'),
                      description: context.tr(
                        'Changes save automatically. All answers are optional; blank means unknown, not 0 or No.',
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: ListenableBuilder(
                        listenable: _draftSaves,
                        builder: (context, _) => Text(
                          _saveStatus,
                          key: const ValueKey('profile-save-status'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                    if (_notice != null)
                      SahNotice(message: context.tr(_notice!)),
                    if (!_sameBase && !_restoring && !_saving)
                      SahNotice(
                        title: context.tr('This case changed'),
                        message: context.tr(
                          'Return to the case and reopen Resident details to compare your unfinished work with its current details.',
                        ),
                        tone: SahNoticeTone.warning,
                      ),
                    if (_restoring)
                      LinearProgressIndicator(
                        semanticsLabel: context.tr('Restoring private edits'),
                      ),
                    if (_recovered != null) _comparison(),
                    for (final key in labels.keys) ...[
                      if (key == 'city')
                        SahSectionHeading(title: context.tr('Location')),
                      if (key == 'healthPlan')
                        SahSectionHeading(title: context.tr('Health coverage')),
                      if (key == 'ageYears')
                        SahSectionHeading(title: context.tr('Household')),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _profileField(key),
                      ),
                    ],
                    SahSectionHeading(title: context.tr('Housing')),
                    DropdownButtonFormField<String>(
                      key: ValueKey(
                        'tenure-$_restoring${_fieldVersion == 0 ? '' : '-$_fieldVersion'}',
                      ),
                      initialValue: _tenure,
                      isExpanded: true,
                      isDense: false,
                      itemHeight: null,
                      decoration: InputDecoration(
                        labelText: context.tr('Do you own or rent?'),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: null,
                          child: Text(context.tr('Not provided')),
                        ),
                        DropdownMenuItem(
                          value: 'owner',
                          child: Text(context.tr('Own')),
                        ),
                        DropdownMenuItem(
                          value: 'renter',
                          child: Text(context.tr('Rent')),
                        ),
                      ],
                      onChanged: !_editable
                          ? null
                          : (v) => setState(() {
                              _tenure = v;
                              _stash();
                            }),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<bool>(
                      key: ValueKey(
                        'consent-$_restoring${_fieldVersion == 0 ? '' : '-$_fieldVersion'}',
                      ),
                      initialValue: _consent,
                      isExpanded: true,
                      isDense: false,
                      itemHeight: null,
                      decoration: InputDecoration(
                        labelText: context.tr('Owner permission reported?'),
                        helperText: context.tr(
                          'Reported only, not a signed authorization.',
                        ),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: null,
                          child: Text(context.tr('Not known')),
                        ),
                        DropdownMenuItem(
                          value: true,
                          child: Text(context.tr('Yes')),
                        ),
                        DropdownMenuItem(
                          value: false,
                          child: Text(context.tr('No')),
                        ),
                      ],
                      onChanged: !_editable
                          ? null
                          : (v) => setState(() {
                              _consent = v;
                              _stash();
                            }),
                    ),
                    const SizedBox(height: 24),
                    if (_errors.isNotEmpty)
                      SahActionFeedback(
                        key: const ValueKey('profile-validation-feedback'),
                        title: context.tr('Check this answer'),
                        message: context.tr('{field}: {error}', {
                          'field': context.tr(labels[_errors.keys.first]!),
                          'error': context.tr(_errors.values.first),
                        }),
                        tone: SahNoticeTone.error,
                        onReview: _reviewInvalid,
                        revealRevision: _validationAttempt,
                      ),
                    if (_syncFailed &&
                        _sameBase &&
                        !widget.services.coordinator.uncertain &&
                        !widget.services.coordinator.conflict)
                      OutlinedButton(
                        key: const ValueKey('profile-retry-online'),
                        onPressed: _onlineSave == null ? _saveOnline : null,
                        child: Text(context.tr('Retry sync')),
                      ),
                    FilledButton(
                      key: const ValueKey('profile-keep-edits'),
                      onPressed: _editable ? _save : null,
                      child: Text(
                        context.tr('Done'),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 72),
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
