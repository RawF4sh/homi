import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/live_app.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/presentation/sah_components.dart';
import 'local_help_record.dart';
import 'local_help_repository.dart';
import 'referral_directory.dart';

class LocalHelpButton extends StatelessWidget {
  const LocalHelpButton({super.key, required this.services, this.findingId});
  final AppServices services;
  final String? findingId;
  @override
  Widget build(BuildContext context) => !services.config.localHelpEnabled
      ? const SizedBox.shrink()
      : IconButton(
          tooltip: context.tr('Find local help'),
          icon: const Icon(Icons.support_agent),
          onPressed:
              services.coordinator.isCurrent &&
                  services.coordinator.draft != null &&
                  !services.coordinator.busy &&
                  !services.coordinator.hasUndurableEdits
              ? () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LocalHelpScreen(
                      services: services,
                      findingId: findingId,
                    ),
                  ),
                )
              : null,
        );
}

class LocalHelpScreen extends StatefulWidget {
  const LocalHelpScreen({
    super.key,
    required this.services,
    this.findingId,
    this.openExternal,
  });
  final AppServices services;
  final String? findingId;

  final Future<bool> Function(Uri)? openExternal;
  @override
  State<LocalHelpScreen> createState() => _LocalHelpScreenState();
}

class _LocalHelpScreenState extends State<LocalHelpScreen> {
  LocalHelpRepository? _repository;
  LocalHelpRecord? _record;
  final _locationForm = GlobalKey<FormState>();
  final _city = TextEditingController(),
      _county = TextEditingController(),
      _zip = TextEditingController();
  bool _working = false;
  String? _error;
  bool get _current => _repository?.isCurrent == true;
  @override
  void initState() {
    super.initState();
    if (widget.services.config.localHelpEnabled &&
        widget.services.coordinator.isCurrent &&
        widget.services.coordinator.draft != null) {
      _repository = LocalHelpRepository(widget.services.coordinator);
      widget.services.coordinator.addListener(_changed);
      _load();
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.services.coordinator.removeListener(_changed);
    _city.dispose();
    _county.dispose();
    _zip.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await _run(() async {
      final r = await _repository!.load();
      if (!mounted || !_current) return;
      final profile = widget.services.coordinator.draft!.profile;
      _city.text = r.location?.city ?? profile.city ?? '';
      _county.text = r.location?.county ?? profile.county ?? '';
      _zip.text = r.location?.zip ?? '';
      setState(() => _record = r);
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_working || !_current) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted && _current) {
        setState(
          () => _error =
              'Local help could not be saved or opened. Your previous saved information is kept. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _save(Future<LocalHelpRecord> Function() action) async {
    final next = await action();
    if (!mounted || !_current) throw StateError('Plan changed.');
    setState(() => _record = next);
  }

  Future<void> _open(
    ReferralProvider provider, {
    bool phone = false,
  }) => _run(() async {
    final uri = referralDestination(provider, phone: phone);
    try {
      final opened =
          await (widget.openExternal?.call(uri) ??
              launchUrl(uri, mode: LaunchMode.externalApplication));
      if (!opened) throw StateError('Unavailable external application.');
    } catch (_) {
      if (mounted && _current) {
        setState(
          () => _error =
              'Could not open this link or dialer. Check your connection, try the official locator, or use the phone number or website shown below.',
        );
      }
    }
  });
  Future<void> _contact(ReferralProvider p, SavedHelpContact? saved) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _HelpEditor(
        title: p.name,
        note: saved?.note ?? '',
        onSave: (title, person, date) =>
            _save(() => _repository!.saveContact(p.id, title)),
      ),
    );
  }

  Future<void> _task(String providerId, [HelpFollowUp? previous]) async {
    final id = previous?.id ?? newUuidV4();
    final created =
        previous?.createdAt ?? DateTime.now().toUtc().toIso8601String();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _HelpEditor(
        title: previous == null ? 'Add follow-up' : 'Edit follow-up',
        task: true,
        note: previous?.title ?? '',
        person: previous?.responsible ?? '',
        date: previous?.dueDate,
        onSave: (title, person, date) => _save(
          () => _repository!.saveTask(
            HelpFollowUp(
              id: id,
              providerId: providerId,
              title: title,
              responsible: person,
              dueDate: date,
              createdAt: created,
              findingId: previous == null
                  ? widget.findingId
                  : previous.findingId,
              completedAt: previous?.completedAt,
            ),
          ),
        ),
      ),
    );
  }

  String _date(String date) =>
      MaterialLocalizations.of(context).formatMediumDate(DateTime.parse(date));
  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Semantics(
      header: true,
      child: Text(
        context.tr(text),
        style: Theme.of(context).textTheme.titleLarge,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final r = _record;
    final repository = _repository;
    final available = widget.services.config.localHelpEnabled && _current;
    return PopScope(
      canPop: !_working,
      child: Scaffold(
        appBar: AppBar(title: Text(context.tr('Find local help'))),
        body: SafeArea(
          child: SahContent(
            child: !available
                ? Center(
                    child: Text(
                      context.tr('Reopen the selected plan to use local help.'),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      Text(
                        context.tr(
                          'Organizations may arrange repair or volunteer help. Confirm your address, costs and intake directly. No worker booking or funding is guaranteed.',
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        context.tr(
                          'Contacts and follow-ups stay on this device for this plan. Signing out removes them. No notifications are scheduled.',
                        ),
                      ),
                      if (_error != null) ...[
                        SahNotice(
                          message: context.tr(_error!),
                          tone: SahNoticeTone.warning,
                        ),
                        if (r == null)
                          TextButton(
                            onPressed: _working ? null : _load,
                            child: Text(context.tr('Retry')),
                          ),
                      ],
                      if (_working) const LinearProgressIndicator(),
                      if (r != null) ...[
                        _heading('Confirm your location'),
                        Form(
                          key: _locationForm,
                          child: Column(
                            children: [
                              TextFormField(
                                controller: _city,
                                maxLength: 100,
                                decoration: InputDecoration(
                                  labelText: context.tr('City (optional)'),
                                ),
                              ),
                              TextFormField(
                                controller: _county,
                                maxLength: 100,
                                decoration: InputDecoration(
                                  labelText: context.tr('County (optional)'),
                                ),
                              ),
                              TextFormField(
                                controller: _zip,
                                maxLength: 10,
                                keyboardType: TextInputType.text,
                                decoration: InputDecoration(
                                  labelText: context.tr('ZIP code (optional)'),
                                ),
                                validator: (s) =>
                                    s!.trim().isEmpty ||
                                        RegExp(
                                          r'^[0-9]{5}(-[0-9]{4})?$',
                                        ).hasMatch(s.trim())
                                    ? null
                                    : context.tr(
                                        'Enter a 5-digit ZIP or ZIP+4.',
                                      ),
                              ),
                              FilledButton(
                                onPressed: _working
                                    ? null
                                    : () {
                                        if (_locationForm.currentState!
                                            .validate()) {
                                          _run(
                                            () => _save(
                                              () => repository!.confirmLocation(
                                                HelpLocation(
                                                  city: _city.text.trim(),
                                                  county: _county.text.trim(),
                                                  zip: _zip.text.trim().isEmpty
                                                      ? null
                                                      : _zip.text.trim(),
                                                ),
                                              ),
                                            ),
                                          );
                                        }
                                      },
                                child: Text(context.tr('Confirm location')),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          context.tr(
                            'Unknown location? Use the national locators. Location is not sent to these websites.',
                          ),
                        ),
                        if (r.location != null)
                          Text(
                            context.tr('Confirmed location: {location}', {
                              'location': [
                                r.location!.city,
                                r.location!.county,
                                r.location!.zip ?? '',
                              ].where((v) => v.isNotEmpty).join(', '),
                            }),
                          ),
                        _heading('Official referrals'),
                        if (r.location == null ||
                            !referralCounties.any(
                              (c) =>
                                  normalizeReferralCounty(c) ==
                                  normalizeReferralCounty(r.location!.county),
                            ))
                          Text(
                            context.tr(
                              'No reviewed local listing for this location. Use the national locators to ask who serves your address.',
                            ),
                          ),
                        for (final p in repository!.directory.providers.where(
                          (p) =>
                              p.isLocator ||
                              r.location != null &&
                                  (r.location!.county.isEmpty ||
                                      p.listsCounty(r.location!.county)),
                        ))
                          _providerCard(p, r),
                        _heading('Saved contacts'),
                        if (r.contacts.isEmpty)
                          Text(context.tr('No contacts saved yet.')),
                        for (final c in r.contacts)
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    repository.directory
                                            .provider(c.providerId)
                                            ?.name ??
                                        context.tr(
                                          'Organization no longer listed',
                                        ),
                                  ),
                                  if (c.note.isNotEmpty) Text(c.note),
                                  if (repository.directory.provider(
                                        c.providerId,
                                      )
                                      case final p?) ...[
                                    if (p.phone != null)
                                      SelectableText(p.phone!),
                                    SelectableText(p.website),
                                  ],
                                  Wrap(
                                    spacing: 8,
                                    children: [
                                      if (repository.directory.provider(
                                            c.providerId,
                                          )
                                          case final p?) ...[
                                        if (p.phone != null)
                                          TextButton(
                                            onPressed: _working
                                                ? null
                                                : () => _open(p, phone: true),
                                            child: Text(
                                              context.tr('Call organization'),
                                            ),
                                          ),
                                        TextButton(
                                          onPressed: _working
                                              ? null
                                              : () => _open(p),
                                          child: Text(
                                            context.tr('Open official website'),
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: _working
                                              ? null
                                              : () => _contact(p, c),
                                          child: Text(
                                            context.tr('Edit contact note'),
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: _working
                                              ? null
                                              : () => _task(c.providerId),
                                          child: Text(
                                            context.tr('Add follow-up'),
                                          ),
                                        ),
                                      ],
                                      TextButton(
                                        onPressed: _working
                                            ? null
                                            : () => _run(
                                                () => _save(
                                                  () =>
                                                      repository.removeContact(
                                                        c.providerId,
                                                      ),
                                                ),
                                              ),
                                        child: Text(
                                          context.tr('Remove saved contact'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        _heading('Follow-up tasks'),
                        if (r.tasks.isEmpty)
                          Text(context.tr('No follow-ups yet.')),
                        for (final t in r.tasks) _taskCard(t, repository),
                      ],
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _providerCard(ReferralProvider p, LocalHelpRecord r) {
    final now = DateTime.now();
    final saved = r.contacts.where((c) => c.providerId == p.id).firstOrNull;
    final county = p.counties
        .where(
          (c) =>
              normalizeReferralCounty(c) ==
              normalizeReferralCounty(r.location?.county ?? ''),
        )
        .firstOrNull;
    final coverage = p.coverage(county, now);
    return Card(
      key: ValueKey(p.id),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(p.name, style: Theme.of(context).textTheme.titleMedium),
            Text(context.tr(p.description)),
            Text(
              context.tr(
                coverage == ReferralCoverage.locator
                    ? 'National locator: ask who serves your address.'
                    : coverage == ReferralCoverage.listedCounty
                    ? 'Listed for this county; confirm address coverage.'
                    : 'Coverage unknown: contact to confirm.',
              ),
            ),
            if (p.counties.isNotEmpty) Text(p.counties.join(', ')),
            Text(
              context.tr(
                p.availability == ReferralAvailability.closed
                    ? 'Intake closed: ask about alternatives.'
                    : 'Intake and repair availability unknown.',
              ),
            ),
            if (p.needsReview(now))
              Text(context.tr('Listing needs review. Contact to confirm.')),
            Text(context.tr('Reviewed {date}', {'date': _date(p.reviewedOn)})),
            if (p.phone != null) SelectableText(p.phone!),
            SelectableText(p.website),
            Wrap(
              spacing: 8,
              children: [
                if (p.phone != null)
                  TextButton(
                    onPressed: _working ? null : () => _open(p, phone: true),
                    child: Text(
                      context.tr(
                        p.phone == '211' ? 'Call 211' : 'Call organization',
                      ),
                    ),
                  ),
                TextButton(
                  onPressed: _working ? null : () => _open(p),
                  child: Text(
                    context.tr(
                      p.id == 'referral-211-national'
                          ? 'Find my local 211'
                          : p.id == 'referral-rebuilding-together-national'
                          ? 'Find a Rebuilding Together affiliate'
                          : 'Open official website',
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _working ? null : () => _contact(p, saved),
                  child: Text(
                    context.tr(
                      saved == null ? 'Save contact' : 'Edit contact note',
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _working ? null : () => _task(p.id),
                  child: Text(context.tr('Add follow-up')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _taskCard(HelpFollowUp t, LocalHelpRepository repository) => Card(
    key: ValueKey(t.id),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t.title, style: Theme.of(context).textTheme.titleMedium),
          Text(
            repository.directory.provider(t.providerId)?.name ??
                context.tr('Organization no longer listed'),
          ),
          Text(
            context.tr(
              t.completedAt != null
                  ? 'Completed'
                  : t.overdue(DateTime.now())
                  ? 'Overdue'
                  : 'Open',
            ),
          ),
          if (t.responsible.isNotEmpty)
            Text(
              context.tr('Responsible: {person}', {'person': t.responsible}),
            ),
          Text(
            t.dueDate == null
                ? context.tr('No due date')
                : context.tr('Due {date}', {'date': _date(t.dueDate!)}),
          ),
          if (t.findingId != null) Text(context.tr('Linked to a concern')),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: _working
                    ? null
                    : () => _run(
                        () => _save(
                          () => repository.completeTask(
                            t.id,
                            t.completedAt == null,
                          ),
                        ),
                      ),
                child: Text(
                  context.tr(
                    t.completedAt == null ? 'Mark complete' : 'Reopen task',
                  ),
                ),
              ),
              TextButton(
                onPressed: _working ? null : () => _task(t.providerId, t),
                child: Text(context.tr('Edit follow-up')),
              ),
              TextButton(
                onPressed: _working
                    ? null
                    : () =>
                          _run(() => _save(() => repository.removeTask(t.id))),
                child: Text(context.tr('Delete follow-up')),
              ),
              if (repository.directory.provider(t.providerId) case final p?)
                TextButton(
                  onPressed: _working ? null : () => _open(p),
                  child: Text(context.tr('Open official website')),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _HelpEditor extends StatefulWidget {
  const _HelpEditor({
    required this.title,
    required this.note,
    required this.onSave,
    this.task = false,
    this.person = '',
    this.date,
  });
  final String title, note, person;
  final String? date;
  final bool task;
  final Future<void> Function(String, String, String?) onSave;
  @override
  State<_HelpEditor> createState() => _HelpEditorState();
}

class _HelpEditorState extends State<_HelpEditor> {
  final _form = GlobalKey<FormState>();
  late final _note = TextEditingController(text: widget.note);
  late final _person = TextEditingController(text: widget.person);
  late final _date = TextEditingController(text: widget.date);
  bool _saving = false, _failed = false;
  @override
  void dispose() {
    _note.dispose();
    _person.dispose();
    _date.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      await widget.onSave(
        _note.text.trim(),
        _person.text.trim(),
        _date.text.trim().isEmpty ? null : _date.text.trim(),
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: Text(context.tr(widget.title)),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _note,
                  enabled: !_saving,
                  maxLength: widget.task ? 160 : 500,
                  decoration: InputDecoration(
                    labelText: context.tr(
                      widget.task ? 'Next action' : 'Contact note (optional)',
                    ),
                  ),
                  validator: (v) => widget.task && v!.trim().isEmpty
                      ? context.tr('Enter a next action.')
                      : null,
                ),
                if (widget.task) ...[
                  TextFormField(
                    controller: _person,
                    enabled: !_saving,
                    maxLength: 100,
                    decoration: InputDecoration(
                      labelText: context.tr('Responsible person (optional)'),
                    ),
                  ),
                  TextFormField(
                    controller: _date,
                    enabled: !_saving,
                    maxLength: 10,
                    decoration: InputDecoration(
                      labelText: context.tr('Due date (YYYY-MM-DD, optional)'),
                    ),
                    validator: (v) {
                      if (v!.trim().isEmpty) return null;
                      try {
                        helpDate(v.trim());
                        return null;
                      } catch (_) {
                        return context.tr('Enter a valid date as YYYY-MM-DD.');
                      }
                    },
                  ),
                ],
                if (_failed)
                  Text(
                    context.tr(
                      'Could not save. Keep this editor open and retry. Remove old follow-ups if the limit of 100 has been reached.',
                    ),
                  ),
                if (_saving) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(context.tr('Cancel')),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(context.tr('Save on this device')),
        ),
      ],
    ),
  );
}
