import 'dart:async';
import 'package:flutter/material.dart';
import '../../app/live_app.dart';
import '../../shared/models/case_draft.dart';

class ProfileEditorScreen extends StatefulWidget {
  const ProfileEditorScreen({super.key, required this.services});
  final AppServices services;
  @override
  State<ProfileEditorScreen> createState() => _ProfileEditorScreenState();
}

class _ProfileEditorScreenState extends State<ProfileEditorScreen> {
  final _form = GlobalKey<FormState>();
  final _fields = <String, TextEditingController>{};
  String? _tenure;
  bool? _consent;
  bool _saving = false, _restoring = true;
  String? _notice;
  late final String _caseId;
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
    _caseId = widget.services.coordinator.currentDraft().caseId;
    final p = widget.services.coordinator.currentDraft().profile.toJson();
    for (final key in labels.keys) {
      _fields[key] = TextEditingController(text: p[key]?.toString() ?? '');
    }
    _tenure = p['tenure'] as String?;
    _consent = p['ownerConsentReported'] as bool?;
    _restore();
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _restore() async {
    try {
      final saved = await widget.services.store.readJson(_editKey);
      if (!mounted) return;
      if (saved != null) {
        final values = saved['values'] as Map;
        for (final key in _fields.keys) {
          _fields[key]!.text = values[key] as String? ?? '';
        }
        _tenure = saved['tenure'] as String?;
        _consent = saved['consent'] as bool?;
        _notice = 'Recovered unfinished edits from this device.';
      }
    } catch (_) {
      if (mounted) {
        _notice =
            'Unfinished edits could not be restored. The saved case is still available.';
      }
    }
    if (mounted) setState(() => _restoring = false);
  }

  void _stash() {
    if (_restoring) return;
    final value = <String, Object?>{
      'values': {for (final key in _fields.keys) key: _fields[key]!.text},
      'tenure': _tenure,
      'consent': _consent,
    };
    unawaited(
      widget.services.store.writeJson(_editKey, value).catchError((Object _) {
        if (mounted) {
          setState(
            () => _notice =
                'Edits could not be saved on this device. Keep this screen open and retry.',
          );
        }
      }),
    );
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final c = widget.services.coordinator;
      final value = c.currentDraft().toJson();
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
      if (c.currentDraft().caseId != _caseId) {
        throw StateError('This case is no longer selected.');
      }
      await c.updateDraft(CaseDraft.fromJson(value));
      await widget.services.store.delete(_editKey);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) await showOperationError(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Resident details')),
    body: SafeArea(
      child: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Leave an answer blank if you do not know. Zero and No are separate answers.',
            ),
            if (_notice != null) Text(_notice!),
            if (_restoring) const LinearProgressIndicator(),
            const SizedBox(height: 16),
            for (final key in labels.keys)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: TextFormField(
                  controller: _fields[key],
                  enabled: !_saving && !_restoring,
                  onChanged: (_) => _stash(),
                  decoration: InputDecoration(
                    labelText: labels[key],
                    helperText: 'Optional · blank means not provided',
                  ),
                  keyboardType:
                      [
                        'ageYears',
                        'householdSize',
                        'annualIncomeUsd',
                      ].contains(key)
                      ? const TextInputType.numberWithOptions(decimal: true)
                      : TextInputType.text,
                  validator: (text) {
                    if (text == null || text.trim().isEmpty) return null;
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
                  },
                ),
              ),
            DropdownButtonFormField<String>(
              key: ValueKey('tenure-$_restoring'),
              initialValue: _tenure,
              decoration: const InputDecoration(
                labelText: 'Do you own or rent?',
              ),
              items: const [
                DropdownMenuItem(value: null, child: Text('Not provided')),
                DropdownMenuItem(value: 'owner', child: Text('Own')),
                DropdownMenuItem(value: 'renter', child: Text('Rent')),
              ],
              onChanged: _saving || _restoring
                  ? null
                  : (v) => setState(() {
                      _tenure = v;
                      _stash();
                    }),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<bool>(
              key: ValueKey('consent-$_restoring'),
              initialValue: _consent,
              decoration: const InputDecoration(
                labelText: 'Owner permission reported?',
              ),
              items: const [
                DropdownMenuItem(value: null, child: Text('Not known')),
                DropdownMenuItem(value: true, child: Text('Yes')),
                DropdownMenuItem(value: false, child: Text('No')),
              ],
              onChanged: _saving || _restoring
                  ? null
                  : (v) => setState(() {
                      _consent = v;
                      _stash();
                    }),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'A reported answer is not a signed owner authorization.',
              ),
            ),
            FilledButton(
              onPressed: _saving || _restoring ? null : _save,
              child: const Text('Keep edits on this device'),
            ),
          ],
        ),
      ),
    ),
  );
}
