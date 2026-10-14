import 'dart:async';
import '../../shared/models/collaboration.dart';
import '../../shared/models/sensitive_sharing.dart';
import '../../shared/models/evidence.dart';
import '../requests/private_draft_preview.dart';
import '../../shared/models/request_tracking.dart';
import '../../shared/services/matching_api_client.dart';
import 'package:flutter/material.dart' hide SensitiveContent;
import '../../app/live_app.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/models/sharing.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/models/contracts.dart' show Finding;

part 'collaboration_screen.dart';
part 'sensitive_sharing_screen.dart';

abstract class _OnlineState<T extends StatefulWidget> extends State<T>
    with WidgetsBindingObserver {
  AppServices get services;
  late final int _epoch;
  int _request = 0;
  bool busy = false, _foreground = true;
  String? error;
  bool get current =>
      mounted &&
      _foreground &&
      services.coordinator.isCurrent &&
      services.session.epoch == _epoch;
  void clearContent();
  Future<void> reload();
  @override
  void initState() {
    super.initState();
    _epoch = services.session.epoch;
    WidgetsBinding.instance.addObserver(this);
    services.session.addListener(_sessionChanged);
  }

  void _sessionChanged() {
    if (mounted && services.session.epoch != _epoch) {
      _request++;
      setState(() {
        clearContent();
        busy = false;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _request++;
      if (mounted) {
        setState(() {
          clearContent();
          busy = false;
        });
      }
    } else if (current) {
      unawaited(reload());
    }
  }

  Future<void> run(Future<void> Function(bool Function()) action) async {
    if (!current || busy) return;
    final request = ++_request;
    bool valid() => current && request == _request;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action(valid);
    } catch (_) {
      if (valid()) {
        setState(() {
          clearContent();
          error =
              'Sharing could not be confirmed. Refresh access before trying again.';
        });
      }
    } finally {
      if (valid()) setState(() => busy = false);
    }
  }

  Future<SharingResponse> call(
    String route,
    Map<String, Object?> body,
    bool Function() valid,
  ) => services.sharing.request(route, body, isCurrent: valid);
  @override
  void dispose() {
    _request++;
    WidgetsBinding.instance.removeObserver(this);
    services.session.removeListener(_sessionChanged);
    super.dispose();
  }

  List<Widget> status() => [
    if (busy) const LinearProgressIndicator(),
    if (error != null)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(context.tr(error!), semanticsLabel: context.tr(error!)),
      ),
  ];
}

class PeopleWithAccessScreen extends StatefulWidget {
  const PeopleWithAccessScreen({super.key, required this.services});
  final AppServices services;
  @override
  State<PeopleWithAccessScreen> createState() => _PeopleState();
}

class _PeopleState extends _OnlineState<PeopleWithAccessScreen> {
  @override
  AppServices get services => widget.services;
  final recipient = TextEditingController();
  late final String caseId;
  List<OwnerShare> shares = [];
  List<String> programs = [];
  final findings = <String>{}, selectedPrograms = <String>{};
  bool helper = false, notes = false;
  int? days = 30;
  bool _expiryChanged = false;
  String? code;
  CaseMembership? editing;
  SharedCaseProjection? preview;
  Map<String, Object?>? _reviewed;
  @override
  void initState() {
    super.initState();
    caseId = services.coordinator.snapshot!.caseId;
    unawaited(reload());
  }

  @override
  void dispose() {
    recipient.dispose();
    super.dispose();
  }

  @override
  void clearContent() {
    shares = [];
    programs = [];
    code = null;
    preview = null;
    _reviewed = null;
  }

  @override
  Future<void> reload() => run((valid) async {
    final response = await call('list-sharing', {'caseId': caseId}, valid);
    if (valid()) {
      setState(() {
        shares = response.shares;
        programs = response.availableProgramIds;
        preview = null;
        _reviewed = null;
        code = null;
      });
    }
  });
  ShareScope get scope => ShareScope(
    findingIds: findings.toList(),
    programIds: selectedPrograms.toList(),
    allowHelperNotes: helper && notes,
  );
  void _changed() {
    preview = null;
    _reviewed = null;
    code = null;
  }

  Future<void> _preview() => run((valid) async {
    final snapshot = services.coordinator.snapshot;
    if (snapshot == null ||
        snapshot.caseId != caseId ||
        services.coordinator.hasUnsavedChanges) {
      throw StateError('Save first');
    }
    final fields = <String, Object?>{
      'caseId': caseId,
      'expectedCaseRevision': snapshot.revision,
      'scope': scope.toJson(),
    };
    final response = await call('preview-sharing', fields, valid);
    if (valid()) {
      setState(() {
        preview = response.projection;
        _reviewed = {
          ...fields,
          'role': helper ? 'helper' : 'viewer',
          'expiresAt': editing != null && !_expiryChanged
              ? editing!.expiresAt
              : days == null
              ? null
              : DateTime.now()
                    .toUtc()
                    .add(Duration(days: days!))
                    .toIso8601String(),
        };
      });
    }
  });
  Future<void> _save() => run((valid) async {
    final reviewed = _reviewed;
    if (reviewed == null) throw StateError('Review first');
    final edit = editing;
    final fields = {
      ...reviewed,
      'invitationId': edit?.id ?? newUuidV4(),
      if (edit == null) 'recipientId': recipient.text.trim(),
      if (edit != null) 'expectedPermissionRevision': edit.revision,
    };
    final response = await call(
      edit == null ? 'create-invitation' : 'change-sharing',
      fields,
      valid,
    );
    if (valid()) {
      final listed = await call('list-sharing', {'caseId': caseId}, valid);
      if (valid()) {
        setState(() {
          shares = listed.shares;
          programs = listed.availableProgramIds;
          code = response.invitationCode;
          editing = null;
          preview = null;
          _reviewed = null;
        });
      }
    }
  });
  Future<void> _revoke(CaseMembership grant) => run((valid) async {
    await call('revoke-sharing', {
      'caseId': caseId,
      'invitationId': grant.id,
      'expectedPermissionRevision': grant.revision,
    }, valid);
    final response = await call('list-sharing', {'caseId': caseId}, valid);
    if (valid()) {
      setState(() {
        shares = response.shares;
        code = null;
      });
    }
  });
  void _edit(OwnerShare share) {
    final grant = share.membership;
    setState(() {
      editing = grant;
      _expiryChanged = false;
      recipient.text = grant.recipientId;
      helper = grant.role == 'helper';
      notes = grant.scope.allowHelperNotes;
      findings
        ..clear()
        ..addAll(grant.scope.findingIds);
      selectedPrograms
        ..clear()
        ..addAll(grant.scope.programIds);
      days = grant.expiresAt == null
          ? null
          : DateTime.parse(
              grant.expiresAt!,
            ).difference(DateTime.now().toUtc()).inDays.clamp(1, 90);
      _changed();
    });
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = services.coordinator.snapshot;
    final available = snapshot?.caseId == caseId
        ? snapshot!.findings
        : <Finding>[];
    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('People with access')),
        actions: [
          IconButton(
            onPressed: busy ? null : reload,
            tooltip: context.tr('Refresh access'),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            ...status(),
            Text(
              context.tr(
                'Obtain the resident’s permission before sharing. Account access does not establish professional consent or legal authority.',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              context.tr(
                'Revocation stops future access. It cannot erase information someone has already seen or copied.',
              ),
            ),
            for (final share in shares)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(share.membership.recipientId),
                      Text(
                        context.tr(
                          share.membership.role == 'helper'
                              ? 'Helper'
                              : 'Viewer',
                        ),
                      ),
                      Text(context.tr(share.membership.state)),
                      AccessDetails(membership: share.membership),
                      Text(
                        context.tr('Permission revision {revision}', {
                          'revision': share.membership.revision,
                        }),
                      ),
                      if (share.projection?.stale == true)
                        Text(
                          context.tr(
                            'The owner has newer information. This shared copy needs review.',
                          ),
                        ),
                      for (final note in share.notes) Text(note.text),
                      if (services.config.trackingEnabled &&
                          share.membership.state == 'active')
                        TextButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  await Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => CollaborationScreen(
                                        services: services,
                                        membership: share.membership,
                                        ownerView: true,
                                      ),
                                    ),
                                  );
                                  if (current) await reload();
                                },
                          child: Text(context.tr('Shared tasks and proposals')),
                        ),
                      if (services.config.sensitiveSharingEnabled &&
                          share.membership.role == 'helper' &&
                          share.membership.state == 'active')
                        TextButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  await Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => SensitiveSharingScreen(
                                        services: services,
                                        membership: share.membership,
                                        ownerView: true,
                                      ),
                                    ),
                                  );
                                  if (current) await reload();
                                },
                          child: Text(context.tr('Detailed helper access')),
                        ),

                      ExpansionTile(
                        title: Text(
                          context.tr('Recent access events: {count}', {
                            'count': share.audit.length,
                          }),
                        ),
                        children: [
                          for (final event in share.audit.reversed)
                            ListTile(
                              title: Text(context.tr(event['type']! as String)),
                              subtitle: Text(
                                '${event['actorId']} · ${event['at']}',
                              ),
                            ),
                        ],
                      ),
                      if ({
                        'active',
                        'pending',
                      }.contains(share.membership.state))
                        Wrap(
                          spacing: 8,
                          children: [
                            TextButton(
                              onPressed: busy ? null : () => _edit(share),
                              child: Text(context.tr('Review permissions')),
                            ),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => _revoke(share.membership),
                              child: Text(context.tr('Revoke access')),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 20),
            Text(
              context.tr(
                editing == null ? 'Invite a person' : 'Review permissions',
              ),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            TextField(
              controller: recipient,
              enabled: !busy && editing == null,
              decoration: InputDecoration(
                labelText: context.tr('Recipient account ID'),
                helperText: context.tr(
                  'Ask the recipient for the account ID shown in Shared with me.',
                ),
              ),
              onChanged: (_) => setState(_changed),
            ),
            DropdownButtonFormField<bool>(
              key: ValueKey('sharing-role-$helper'),
              initialValue: helper,
              decoration: InputDecoration(labelText: context.tr('Permission')),
              items: [
                DropdownMenuItem(
                  value: false,
                  child: Text(context.tr('Viewer')),
                ),
                DropdownMenuItem(
                  value: true,
                  child: Text(context.tr('Helper')),
                ),
              ],
              onChanged: busy
                  ? null
                  : (value) => setState(() {
                      helper = value!;
                      if (!helper) notes = false;
                      _changed();
                    }),
            ),
            if (helper)
              CheckboxListTile(
                value: notes,
                onChanged: busy
                    ? null
                    : (v) => setState(() {
                        notes = v!;
                        _changed();
                      }),
                title: Text(context.tr('Allow progress notes')),
              ),
            Text(
              context.tr(
                'Choose exactly what this person can see. New findings and programs are not added automatically.',
              ),
            ),
            for (final finding in available)
              CheckboxListTile(
                value: findings.contains(finding.id),
                title: Text(finding.observation),
                onChanged: busy
                    ? null
                    : (v) => setState(() {
                        v!
                            ? findings.add(finding.id)
                            : findings.remove(finding.id);
                        _changed();
                      }),
              ),
            for (final id in programs)
              CheckboxListTile(
                value: selectedPrograms.contains(id),
                title: Text(id),
                subtitle: Text(context.tr('Reported program progress')),
                onChanged: busy
                    ? null
                    : (v) => setState(() {
                        v!
                            ? selectedPrograms.add(id)
                            : selectedPrograms.remove(id);
                        _changed();
                      }),
              ),
            Text(
              context.tr(
                'Photos, PDFs, income, health answers, and downloads are not shared.',
              ),
            ),
            DropdownButtonFormField<int>(
              key: ValueKey('sharing-expiry-$days'),
              initialValue: days ?? 0,
              decoration: InputDecoration(
                labelText: context.tr('Access expires'),
              ),
              items: [
                for (final d in {0, 7, 30, 90, ?days})
                  DropdownMenuItem(
                    value: d,
                    child: Text(
                      d == 0
                          ? context.tr('No access expiry')
                          : context.tr('After {days} days', {'days': d}),
                    ),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (v) => setState(() {
                      _expiryChanged = true;
                      days = v == 0 ? null : v;
                      _changed();
                    }),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: busy ? null : _preview,
              child: Text(context.tr('Preview selected information')),
            ),
            if (preview != null) ...[
              ProjectionContent(projection: preview!),
              FilledButton(
                onPressed:
                    busy || (editing == null && recipient.text.trim().isEmpty)
                    ? null
                    : _save,
                child: Text(
                  context.tr(
                    editing == null
                        ? 'Create invitation code'
                        : 'Save permissions',
                  ),
                ),
              ),
            ],
            if (code != null) ...[
              Text(
                context.tr(
                  'Share this code manually. Creating it has not sent a message. It expires within seven days and can be used once by the selected account.',
                ),
              ),
              SelectableText(code!, key: const ValueKey('invitation-code')),
            ],
          ],
        ),
      ),
    );
  }
}

class SharedWithMeScreen extends StatefulWidget {
  const SharedWithMeScreen({super.key, required this.services});
  final AppServices services;
  @override
  State<SharedWithMeScreen> createState() => _SharedListState();
}

class _SharedListState extends _OnlineState<SharedWithMeScreen> {
  @override
  AppServices get services => widget.services;
  final code = TextEditingController();
  List<CaseMembership> memberships = [];
  CaseMembership? invitation;
  @override
  void initState() {
    super.initState();
    unawaited(reload());
  }

  @override
  void dispose() {
    code.dispose();
    super.dispose();
  }

  @override
  void clearContent() {
    memberships = [];
    invitation = null;
    code.clear();
  }

  @override
  Future<void> reload() => run((valid) async {
    final response = await call('list-shared-cases', {}, valid);
    if (valid()) {
      setState(() {
        memberships = response.memberships;
        invitation = null;
      });
    }
  });
  Future<void> _review() => run((valid) async {
    final result = await call('review-invitation', {
      'code': code.text.trim(),
    }, valid);
    if (valid()) setState(() => invitation = result.membership);
  });
  Future<void> _accept() => run((valid) async {
    await call('accept-invitation', {
      'code': code.text.trim(),
      'expectedPermissionRevision': invitation!.revision,
    }, valid);
    final listed = await call('list-shared-cases', {}, valid);
    if (valid()) {
      setState(() {
        memberships = listed.memberships;
        invitation = null;
        code.clear();
      });
    }
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(context.tr('Shared with me')),
      actions: [
        IconButton(
          onPressed: busy ? null : reload,
          tooltip: context.tr('Refresh access'),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          ...status(),
          Text(context.tr('Your account ID')),
          SelectableText(services.store.accountId),
          TextField(
            controller: code,
            enabled: !busy,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: context.tr('Invitation code'),
            ),
            onChanged: (_) => setState(() => invitation = null),
          ),
          OutlinedButton(
            onPressed: busy ? null : _review,
            child: Text(context.tr('Review invitation')),
          ),
          if (invitation != null) ...[
            AccessDetails(membership: invitation!),
            Text(
              context.tr(invitation!.role == 'helper' ? 'Helper' : 'Viewer'),
            ),
            Text(
              context.tr('Selected findings: {count}', {
                'count': invitation!.scope.findingIds.length,
              }),
            ),
            Text(
              context.tr('Selected programs: {count}', {
                'count': invitation!.scope.programIds.length,
              }),
            ),
            Text(
              context.tr(
                invitation!.scope.allowHelperNotes
                    ? 'Progress notes allowed'
                    : 'Read only',
              ),
            ),
            FilledButton(
              onPressed: busy ? null : _accept,
              child: Text(context.tr('Accept invitation')),
            ),
          ],
          if (memberships.isEmpty && !busy)
            Text(context.tr('No active shared plans.')),
          for (final grant in memberships)
            ListTile(
              title: Text(context.tr('Shared home safety plan')),
              subtitle: Text(
                context.tr(grant.role == 'helper' ? 'Helper' : 'Viewer'),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: busy
                  ? null
                  : () async {
                      setState(clearContent);
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => SharedCaseScreen(
                            services: services,
                            membership: grant,
                          ),
                        ),
                      );
                      if (current) await reload();
                    },
            ),
        ],
      ),
    ),
  );
}

class SharedCaseScreen extends StatefulWidget {
  const SharedCaseScreen({
    super.key,
    required this.services,
    required this.membership,
  });
  final AppServices services;
  final CaseMembership membership;
  @override
  State<SharedCaseScreen> createState() => _SharedCaseState();
}

class _SharedCaseState extends _OnlineState<SharedCaseScreen> {
  @override
  AppServices get services => widget.services;
  SharingResponse? view;
  late CaseMembership _grant;
  final note = TextEditingController();
  String? _mutation;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _grant = widget.membership;
    unawaited(reload());
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (current) unawaited(reload());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    note.dispose();
    super.dispose();
  }

  @override
  void clearContent() {
    view = null;
    note.clear();
    _mutation = null;
  }

  Map<String, Object?> get binding => {
    'membershipId': _grant.id,
    'expectedPermissionRevision': _grant.revision,
  };
  @override
  Future<void> reload() => run((valid) async {
    setState(() => view = null);
    final list = await call('list-shared-cases', {}, valid);
    if (!valid()) return;
    _grant = list.memberships.firstWhere((m) => m.id == widget.membership.id);
    final response = await call('read-shared-case', binding, valid);
    if (valid()) setState(() => view = response);
  });
  Future<void> _add() => run((valid) async {
    _mutation ??= newUuidV4();
    setState(() => view = null);
    final response = await call('add-shared-note', {
      ...binding,
      'mutationId': _mutation,
      'note': note.text.trim(),
    }, valid);
    if (valid()) {
      setState(() {
        view = response;
        note.clear();
        _mutation = null;
      });
    }
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(context.tr('Shared home safety plan')),
      actions: [
        IconButton(
          onPressed: busy ? null : reload,
          tooltip: context.tr('Refresh access'),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          ...status(),
          if (view == null && !busy)
            Text(context.tr('Refresh access to view this shared plan.')),
          if (view != null) ...[
            AccessDetails(membership: view!.membership!),
            ProjectionContent(projection: view!.projection!),
            if (services.config.sensitiveSharingEnabled &&
                view!.membership!.role == 'helper')
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () async {
                        final grant = _grant;
                        setState(clearContent);
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => SensitiveSharingScreen(
                              services: services,
                              membership: grant,
                              ownerView: false,
                            ),
                          ),
                        );
                        if (current) await reload();
                      },
                child: Text(context.tr('Detailed helper access')),
              ),
            if (services.config.trackingEnabled)
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () async {
                        final grant = _grant;
                        setState(clearContent);
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => CollaborationScreen(
                              services: services,
                              membership: grant,
                              ownerView: false,
                            ),
                          ),
                        );
                        if (current) await reload();
                      },
                child: Text(context.tr('Shared tasks and proposals')),
              ),

            for (final item in view!.notes)
              ListTile(title: Text(item.text), subtitle: Text(item.recordedAt)),
            if (view!.membership!.role == 'helper' &&
                view!.membership!.scope.allowHelperNotes) ...[
              TextField(
                controller: note,
                maxLength: 500,
                decoration: InputDecoration(
                  labelText: context.tr('Progress note'),
                ),
                onChanged: (_) {
                  _mutation = null;
                },
              ),
              FilledButton(
                onPressed: busy ? null : _add,
                child: Text(context.tr('Add progress note')),
              ),
            ],
          ],
        ],
      ),
    ),
  );
}

class ProjectionContent extends StatelessWidget {
  const ProjectionContent({super.key, required this.projection});
  final SharedCaseProjection projection;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 12),
      Text(
        context.tr('Selected home safety information'),
        style: Theme.of(context).textTheme.titleLarge,
      ),
      Text(
        context.tr('Published revision {revision}', {
          'revision': projection.revision,
        }),
      ),
      if (projection.stale)
        Text(
          context.tr(
            'The owner has newer information. This shared copy needs review.',
          ),
        ),
      for (final finding in projection.findings)
        ListTile(
          title: Text(finding.observation),
          subtitle: Text(context.tr(finding.reviewState)),
        ),
      for (final program in projection.programs)
        ListTile(
          title: Text(program.id),
          subtitle: Text(
            context.tr('Reported status: {status}', {
              'status': program.status == null
                  ? context.tr('Unknown')
                  : context.tr(program.status!),
            }),
          ),
        ),
      Text(
        context.tr(
          'Reported progress does not confirm agency receipt or approval.',
        ),
      ),
    ],
  );
}

class AccessDetails extends StatelessWidget {
  const AccessDetails({super.key, required this.membership});
  final CaseMembership membership;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(context.tr('Invited by account {id}', {'id': membership.grantorId})),
      Text(
        membership.expiresAt == null
            ? context.tr('No access expiry')
            : context.tr('Access expires on {date}', {
                'date': membership.expiresAt,
              }),
      ),
    ],
  );
}
