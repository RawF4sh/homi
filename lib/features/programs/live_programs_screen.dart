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
  });
  final AppServices services;
  final bool workspaceMode;
  final Widget? header;
  @override
  State<LiveProgramsScreen> createState() => _LiveProgramsScreenState();
}

class _LiveProgramsScreenState extends State<LiveProgramsScreen>
    with WidgetsBindingObserver {
  MatchResponse? _result;
  bool _busy = false;
  String? _error;
  Timer? _timer;
  int? _autoRevision;
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
    super.dispose();
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final c = widget.services.coordinator;
      final result = await widget.services.matching.matchCase(
        c.currentCase(),
        currentCase: c.currentCase,
      );
      if (mounted) setState(() => _result = result);
      if (mounted) scheduleMicrotask(_changed);
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
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
      tilePadding: EdgeInsets.zero,
      title: Text(context.tr('Details')),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
            onPressed: !same
                ? null
                : () async {
                    try {
                      await widget.services.progressReady;
                      if (!mounted || !c.isCurrent) return;
                      final id = c.currentCase().caseId,
                          revision = c.currentCase().revision;
                      await widget.services.progress!.refresh(id);
                      await widget.services.progress!.mutate(id, revision, {
                        'type': 'track_program',
                        'programId': match.programId,
                      });
                      if (mounted && c.isCurrent) {
                        _open(ProgramProgressScreen(services: widget.services));
                      }
                    } catch (error) {
                      if (context.mounted) {
                        await showOperationError(context, error);
                      }
                    }
                  },
            icon: const Icon(Icons.playlist_add),
            label: Text(context.tr('Track program')),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(
            context.tr('Eligibility checks'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        for (final check in match.checks)
          ListTile(
            key: ValueKey('program-${match.programId}-check-${check.id}'),
            contentPadding: EdgeInsets.zero,
            minLeadingWidth: 24,
            leading: ExcludeSemantics(
              child: Icon(
                switch (check.status) {
                  'pass' => Icons.check_circle_outline_rounded,
                  'fail' => Icons.do_not_disturb_on_outlined,
                  _ => Icons.help_outline_rounded,
                },
                color: check.status == 'pass'
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.tertiary,
              ),
            ),
            title: Text(switch (check.status) {
              'pass' => context.tr('Met'),
              'fail' => context.tr('Not met'),
              _ => context.tr('Needs confirmation'),
            }),
            subtitle: Text(check.explanation),
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
    final result = _result;
    final same =
        result != null &&
        c.snapshot != null &&
        result.caseId == c.snapshot!.caseId &&
        result.caseRevision == c.snapshot!.revision &&
        !c.hasUnsavedChanges;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          context.tr(widget.workspaceMode ? 'Help' : 'Possible assistance'),
        ),
        actions: [
          if (!widget.workspaceMode) LocalHelpButton(services: widget.services),
        ],
      ),
      body: SafeArea(
        child: SahContent(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (widget.header != null) widget.header!,
              if (!widget.workspaceMode)
                SahPageHeader(title: context.tr('Possible assistance')),
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
                SahNotice(
                  message: context.tr(
                    'Program information and official forms may remain in English. Your saved answers are not translated.',
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
                  !result.isFreshFor(
                    c.currentCase(),
                    now: DateTime.now().toUtc(),
                  ))
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
              if (result != null)
                for (final match in result.matches)
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
                          Align(
                            alignment: Alignment.centerLeft,
                            child: SahStatusBadge(
                              label: switch (match.status) {
                                'meets_known_criteria' => context.tr(
                                  'Matches the known checks',
                                ),
                                'does_not_meet_criterion' => context.tr(
                                  'A known criterion is not met',
                                ),
                                _ => context.tr('More information is needed'),
                              },
                              icon: match.status == 'meets_known_criteria'
                                  ? Icons.check_circle_outline_rounded
                                  : Icons.info_outline_rounded,
                              tone: match.status == 'meets_known_criteria'
                                  ? SahNoticeTone.success
                                  : SahNoticeTone.warning,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            context.tr(
                              '{met} met · {notMet} not met · {unknown} need confirmation',
                              {
                                'met': match.checks
                                    .where((check) => check.status == 'pass')
                                    .length,
                                'notMet': match.checks
                                    .where((check) => check.status == 'fail')
                                    .length,
                                'unknown': match.checks
                                    .where((check) => check.status == 'unknown')
                                    .length,
                              },
                            ),
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            key: ValueKey('program-${match.programId}-start'),
                            onPressed: same ? () => _start(match) : null,
                            child: Text(
                              context.tr('Prepare a draft'),
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
        ),
      ),
    );
  }
}
