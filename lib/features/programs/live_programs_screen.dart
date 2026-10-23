import 'dart:async';
import 'package:flutter/material.dart';
import '../tracking/program_progress_screen.dart';
import '../local_help/local_help_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../app/live_app.dart';
import '../../shared/models/contracts.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/services/packet_preparation_service.dart';
import 'program_intake_screen.dart';
import '../requests/draft_packet_screen.dart';
import '../requests/form_review_screen.dart';
import '../requests/private_export_screen.dart';
import '../requests/request_history_screen.dart';

class LiveProgramsScreen extends StatefulWidget {
  const LiveProgramsScreen({
    super.key,
    required this.services,
    this.workspaceMode = false,
    this.header,
    this.embedded = false,
  });
  final AppServices services;
  final bool workspaceMode;
  final Widget? header;
  final bool embedded;
  @override
  LiveProgramsScreenState createState() => LiveProgramsScreenState();
}

class LiveProgramsScreenState extends State<LiveProgramsScreen>
    with WidgetsBindingObserver {
  MatchResponse? _result;
  bool _busy = false;
  bool _tracking = false;

  bool get canLeave => !_tracking;

  MatchResponse? get assistantMatches {
    final c = widget.services.coordinator;
    final snapshot = c.snapshot;
    return c.isCurrent &&
            !_busy &&
            _error == null &&
            snapshot != null &&
            !c.hasUnsavedChanges &&
            _result?.isFreshFor(snapshot, now: DateTime.now()) == true
        ? _result
        : null;
  }

  String? _assistantProgramId;
  void openAssistantProgram(String id) {
    if (!mounted ||
        !canLeave ||
        assistantMatches?.matches.any((m) => m.programId == id) != true) {
      return;
    }
    setState(() => _assistantProgramId = id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          assistantMatches?.matches.any((m) => m.programId == id) == true) {
        _detailsController(id).expand();
      }
    });
  }

  String? _error;
  Timer? _timer;
  int? _autoRevision;
  final _detailsControllers = <String, ExpansibleController>{};
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.services.coordinator.addListener(_changed);
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _changed());
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final c = widget.services.coordinator;
    final snapshot = c.snapshot, result = _result;
    if (_busy ||
        result == null ||
        snapshot == null ||
        c.hasUnsavedChanges ||
        (result.caseId == snapshot.caseId &&
            result.caseRevision == snapshot.revision) ||
        _autoRevision == snapshot.revision) {
      return;
    }
    _autoRevision = snapshot.revision;
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _changed();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.services.coordinator.removeListener(_changed);
    _timer?.cancel();
    for (final controller in _detailsControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final c = widget.services.coordinator;
    final generation = c.generation;
    try {
      final result = await widget.services.matching.matchCase(
        c.currentCase(),
        currentCase: c.currentCase,
      );
      if (mounted && c.isCurrent && c.generation == generation) {
        setState(() => _result = result);
        scheduleMicrotask(_changed);
      }
    } catch (error) {
      if (mounted && c.isCurrent && c.generation == generation) {
        setState(() => _error = safeOperationMessage(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open(Widget screen) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));

  Future<void> _openSource(String value) async {
    final uri = Uri.tryParse(value);
    try {
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw const FormatException();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'The official page could not be opened. You can copy its address from Program sources.',
        );
      }
    }
  }

  void _replace(Widget screen) => Navigator.of(
    context,
  ).pushReplacement(MaterialPageRoute<void>(builder: (_) => screen));

  void _start(ProgramMatch match) {
    void export() => _replace(
      PrivateExportScreen(services: widget.services, program: match),
    );
    void answers() => _replace(
      FormReviewScreen(
        services: widget.services,
        program: match,
        onNext: export,
      ),
    );
    _open(
      ProgramIntakeScreen(
        services: widget.services,
        program: match,
        onNext: answers,
      ),
    );
  }

  Future<void> _trackProgram(ProgramMatch match) async {
    if (_tracking) return;
    final c = widget.services.coordinator;
    final generation = c.generation;
    if (!c.isCurrent || c.snapshot == null || c.hasUnsavedChanges) return;
    final snapshot = c.currentCase();
    if (_result?.caseId != snapshot.caseId ||
        _result?.caseRevision != snapshot.revision) {
      return;
    }
    bool current() =>
        mounted &&
        c.isCurrent &&
        c.generation == generation &&
        c.snapshot?.caseId == snapshot.caseId &&
        c.snapshot?.revision == snapshot.revision &&
        !c.hasUnsavedChanges;
    setState(() => _tracking = true);
    try {
      await widget.services.progressReady;
      if (!current()) return;
      await widget.services.progress!.refresh(snapshot.caseId);
      if (!current()) return;
      await widget.services.progress!.mutate(
        snapshot.caseId,
        snapshot.revision,
        {'type': 'track_program', 'programId': match.programId},
      );
      if (current()) _open(ProgramProgressScreen(services: widget.services));
    } catch (error) {
      if (mounted && current()) await showOperationError(context, error);
    } finally {
      if (mounted) setState(() => _tracking = false);
    }
  }

  ExpansibleController _detailsController(String programId) =>
      _detailsControllers.putIfAbsent(programId, ExpansibleController.new);

  // Presentation summaries only: matching, coverage and eligibility remain
  // entirely in the versioned server response. No geography is inferred from
  // the program name because v1 does not carry a verified service-area field.
  String _purpose(ProgramMatch match) => switch (match.programId) {
    'scfhp-eaa' => 'Possible help: home accessibility adaptations.',
    'hpsm-eaa' => 'Possible help: home modifications.',
    'rtp-home-repair' => 'Possible help: home repairs.',
    _ => 'Possible help: review the program’s service scope.',
  };

  Future<void> _contactProgram(ProgramMatch match) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.tr('Contact program')),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(match.programName),
            const SizedBox(height: 12),
            SelectableText(
              match.intake ??
                  context.tr(
                    'Contact instructions are not supplied. Use the program sources to confirm the accepted intake route.',
                  ),
            ),
            for (final source in match.sources)
              TextButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  _openSource(source.url);
                },
                icon: const Icon(Icons.open_in_new),
                label: Text(source.title),
              ),
            if (match.sources.isEmpty)
              Text(
                context.tr(
                  'No verified source references are supplied for this route.',
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.tr('Close')),
        ),
      ],
    ),
  );

  List<Widget> _requirements(
    BuildContext context,
    ProgramMatch match,
    bool same,
  ) {
    Widget heading(String label) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Semantics(
        header: true,
        child: Text(
          context.tr(label),
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
    );
    Widget checkTile(RequirementCheck check) => ListTile(
      key: ValueKey('program-${match.programId}-check-${check.id}'),
      contentPadding: EdgeInsets.zero,
      title: Text(
        context.tr(switch (check.status) {
          'pass' => 'Met',
          'fail' => 'Not met',
          _ => 'Needs confirmation',
        }),
      ),
      subtitle: Text(check.explanation),
    );
    final unknowns = match.checks.where((check) => check.status == 'unknown');
    return [
      const SizedBox(height: 8),
      Text(
        context.tr(
          '{met} met · {notMet} not met · {unknown} need confirmation',
          {
            'met': match.checks.where((check) => check.status == 'pass').length,
            'notMet': match.checks
                .where((check) => check.status == 'fail')
                .length,
            'unknown': unknowns.length,
          },
        ),
      ),
      Text(
        context.tr(
          'Checks, not decisions. Each program still reviews the case.',
        ),
      ),
      for (final (resolver, label, guidance) in [
        (
          'resident',
          'You can answer',
          'Answer what you know. Reported answers do not replace required consent or documents.',
        ),
        (
          'program',
          'Ask the program',
          'The program must confirm its policy, coverage and current availability.',
        ),
        (
          'professional',
          'Professional review',
          'A qualified professional must review these items. Home observations do not establish medical necessity.',
        ),
        (
          null,
          'Reviewer not specified',
          'Next step: identify who can confirm this requirement.',
        ),
      ])
        if (unknowns.any((check) => check.resolvedBy == resolver)) ...[
          heading(label),
          Text(context.tr(guidance)),
          if (resolver == 'resident')
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: ValueKey('program-${match.programId}-missing-answers'),
                onPressed: same
                    ? () => _open(
                        ProgramIntakeScreen(
                          services: widget.services,
                          program: match,
                        ),
                      )
                    : null,
                child: Text(context.tr('Answer missing questions')),
              ),
            ),
          if (resolver == 'program')
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: ValueKey('program-${match.programId}-contact'),
                onPressed: () => _contactProgram(match),
                child: Text(context.tr('Contact program')),
              ),
            ),
          for (final check in unknowns.where(
            (check) => check.resolvedBy == resolver,
          ))
            checkTile(check),
        ],
      if (match.checks.any((check) => check.status != 'unknown')) ...[
        heading('Recorded checks'),
        for (final check in match.checks.where(
          (check) => check.status != 'unknown',
        ))
          checkTile(check),
      ],
    ];
  }

  Widget _details(BuildContext context, ProgramMatch match, bool same) {
    final c = widget.services.coordinator;
    Widget step(String key, String label, Widget Function() screen) => Align(
      alignment: AlignmentDirectional.centerStart,
      child: TextButton(
        key: key.isEmpty ? null : ValueKey(key),
        onPressed: same ? () => _open(screen()) : null,
        child: Text(context.tr(label)),
      ),
    );
    return ExpansionTile(
      key: ValueKey('program-${match.programId}-details'),
      controller: _detailsController(match.programId),
      tilePadding: EdgeInsets.zero,
      title: Text(context.tr('Details')),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ..._requirements(context, match, same),
        const SizedBox(height: 16),
        OutlinedButton(
          key: ValueKey('program-${match.programId}-start'),
          onPressed: same ? () => _start(match) : null,
          child: Text(
            context.tr('Prepare a draft'),
            textAlign: TextAlign.center,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(
            context.tr('Open one step'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        step(
          'program-${match.programId}-intake',
          'Review program questions',
          () => ProgramIntakeScreen(services: widget.services, program: match),
        ),
        step(
          '',
          'Draft checklist',
          () => DraftPacketScreen(
            snapshot: c.currentCase(),
            program: match,
            service: ApiPacketPreparationService(widget.services.packets),
            currentCase: c.currentCase,
            caseChanges: c,
          ),
        ),
        step(
          'program-${match.programId}-answers',
          'Review administrative answers',
          () => FormReviewScreen(services: widget.services, program: match),
        ),
        step(
          'program-${match.programId}-export',
          'Review evidence and draft PDF',
          () => PrivateExportScreen(services: widget.services, program: match),
        ),
        step(
          'program-${match.programId}-history',
          'Manual request history',
          () => RequestHistoryScreen(services: widget.services, program: match),
        ),
        if (widget.services.config.trackingEnabled)
          TextButton.icon(
            onPressed: !same || _tracking ? null : () => _trackProgram(match),
            icon: const Icon(Icons.playlist_add),
            label: Text(context.tr('Track program')),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(
            context.tr('Program sources and review dates'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        ListTile(
          title: Text(
            context.tr('Availability: {availability}', {
              'availability': context.tr(switch (match.availability) {
                'accepting' => 'accepting',
                'not_accepting' => 'not accepting',
                _ => 'unverified',
              }),
            }),
          ),
          subtitle: Text(
            context.tr('Rule version: {version}', {
              'version': match.ruleVersion,
            }),
          ),
        ),
        for (final source in match.sources)
          ListTile(
            title: Text(source.title),
            trailing: Icon(
              Icons.open_in_new,
              semanticLabel: context.tr('Opens in your browser'),
            ),
            onTap: () => _openSource(source.url),
            subtitle: SelectableText(
              context.tr(
                'Reviewed {reviewed}\nEffective from: {from}\nEffective until: {until}\n{url}',
                {
                  'reviewed': source.reviewedOn,
                  'from': source.effectiveFrom ?? context.tr('not specified'),
                  'until': source.effectiveUntil ?? context.tr('not specified'),
                  'url': source.url,
                },
              ),
            ),
          ),
        if (match.sources.isEmpty)
          ListTile(
            title: Text(
              context.tr(
                'No verified source references are supplied for this route.',
              ),
            ),
          ),
        if (match.intake != null) ...[
          const SizedBox(height: 12),
          Text(match.intake!),
        ],
        if (match.programId == 'rtp-home-repair')
          OutlinedButton.icon(
            onPressed: () => _openSource(
              'https://rebuildingtogetherpeninsula.my.salesforce-sites.com/HomeownerApplication',
            ),
            icon: const Icon(Icons.open_in_new),
            label: Text(context.tr('Open RTP’s official application')),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.services.coordinator;
    final result = c.isCurrent && c.snapshot?.caseId == _result?.caseId
        ? _result
        : null;
    final same =
        result != null &&
        c.snapshot != null &&
        result.caseId == c.snapshot!.caseId &&
        result.caseRevision == c.snapshot!.revision &&
        !c.hasUnsavedChanges;
    final body = SahContent(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (widget.header != null) widget.header!,
          if (!widget.workspaceMode)
            SahPageHeader(title: context.tr('Possible assistance')),
          if (widget.embedded && !widget.workspaceMode)
            LocalHelpButton(services: widget.services),
          if (widget.services.config.trackingEnabled)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: same
                    ? () => _open(
                        ProgramProgressScreen(services: widget.services),
                      )
                    : null,
                icon: const Icon(Icons.view_list_outlined),
                label: Text(context.tr('Program progress')),
              ),
            ),
          if (Localizations.localeOf(context).languageCode != 'en')
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                context.tr(
                  'Program information and official forms may remain in English. Your saved answers are not translated.',
                ),
              ),
            ),
          if (_busy)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(
                semanticsLabel: context.tr('Checking possible assistance'),
              ),
            ),
          if (_error != null)
            SahNotice(
              message: context.tr(_error!),
              tone: SahNoticeTone.warning,
            ),
          if (result != null && !same && !_busy)
            SahNotice(
              message: context.tr(
                c.hasUnsavedChanges
                    ? 'These results update once the case changes are saved.'
                    : 'The case changed. Refresh these results before preparing a draft.',
              ),
              tone: SahNoticeTone.warning,
            ),
          if (result != null &&
              same &&
              !result.isFreshFor(c.currentCase(), now: DateTime.now().toUtc()))
            SahStatusBadge(
              label: context.tr('Some policy details are unconfirmed'),
              icon: Icons.info_outline_rounded,
              tone: SahNoticeTone.warning,
            ),
          if (!_busy &&
              (_error != null ||
                  result == null ||
                  (!same && !c.hasUnsavedChanges)))
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('program-refresh'),
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(
                  context.tr('Refresh program checks'),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          if (result != null && result.matches.isEmpty)
            SahEmptyState(
              title: context.tr('No routes to review yet'),
              message: context.tr(
                'No program routes are currently configured for this case. Your saved assessment is still available.',
              ),
              icon: Icons.search_rounded,
            ),
          if (result != null && result.matches.isNotEmpty)
            SahSectionHeading(
              title: context.tr(
                result.matches.length == 1
                    ? '{count} program route to review'
                    : '{count} program routes to review',
                {'count': result.matches.length},
              ),
            ),
          if (_assistantProgramId != null)
            TextButton(
              onPressed: () => setState(() => _assistantProgramId = null),
              child: Text(context.tr('All programs')),
            ),
          if (result != null)
            for (final match in result.matches.where(
              (m) =>
                  _assistantProgramId == null ||
                  m.programId == _assistantProgramId,
            ))
              Card(
                key: ValueKey('program-${match.programId}'),
                margin: const EdgeInsets.only(bottom: 24),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          match.programName,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(context.tr(_purpose(match))),
                      const SizedBox(height: 8),
                      Text(
                        context.tr(
                          'Service area: confirm your address with the program.',
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        context.tr(switch (match.availability) {
                          'accepting' =>
                            'Intake is listed as open. Confirm current availability with the program.',
                          'not_accepting' =>
                            'Intake is listed as closed. Ask the program about next steps.',
                          _ =>
                            'Current availability is unverified. Confirm it with the program.',
                        }),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        context.tr(switch (match.status) {
                          'meets_known_criteria' => 'Matches the known checks',
                          'does_not_meet_criterion' =>
                            'A known criterion is not met',
                          _ => 'More information is needed',
                        }),
                      ),
                      if (match.checks.any(
                        (check) => check.status == 'unknown',
                      )) ...[
                        const SizedBox(height: 8),
                        Text(
                          context.tr('Review needed: {groups}', {
                            'groups': [
                              for (final (resolver, label) in [
                                ('resident', 'You can answer'),
                                ('program', 'Ask the program'),
                                ('professional', 'Professional review'),
                                (null, 'Reviewer not specified'),
                              ])
                                if (match.checks.any(
                                  (check) =>
                                      check.status == 'unknown' &&
                                      check.resolvedBy == resolver,
                                ))
                                  context.tr(label),
                            ].join(' · '),
                          }),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        context.tr(
                          'Preparation only. Nothing has been submitted by this app.',
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        key: ValueKey('program-${match.programId}-review'),
                        onPressed: () =>
                            _detailsController(match.programId).expand(),
                        child: Text(
                          context.tr('Review requirements'),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      _details(context, match, same),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          context.tr(widget.workspaceMode ? 'Help' : 'Possible assistance'),
        ),
        actions: [
          if (!widget.workspaceMode) LocalHelpButton(services: widget.services),
        ],
      ),
      body: SafeArea(child: body),
    );
  }
}
