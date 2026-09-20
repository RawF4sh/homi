import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../app/live_app.dart';
import '../../shared/models/contracts.dart';
import '../../shared/services/packet_preparation_service.dart';
import 'program_intake_screen.dart';
import '../requests/draft_packet_screen.dart';
import '../requests/form_review_screen.dart';
import '../requests/private_export_screen.dart';
import '../requests/request_history_screen.dart';

class LiveProgramsScreen extends StatefulWidget {
  const LiveProgramsScreen({super.key, required this.services});
  final AppServices services;
  @override
  State<LiveProgramsScreen> createState() => _LiveProgramsScreenState();
}

class _LiveProgramsScreenState extends State<LiveProgramsScreen>
    with WidgetsBindingObserver {
  MatchResponse? _result;
  bool _busy = false;
  String? _error;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.services.coordinator.addListener(_changed);
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _changed());
  }

  void _changed() {
    if (mounted) setState(() {});
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
      appBar: AppBar(title: const Text('Possible assistance')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Program review is still required. These checks do not promise funding or approval.',
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
            OutlinedButton(
              onPressed: _busy ? null : _load,
              child: const Text('Refresh program checks'),
            ),
            if (result != null && !same)
              const Text(
                'The case changed. Refresh these results before preparing a draft.',
              ),
            if (result != null &&
                same &&
                !result.isFreshFor(
                  c.currentCase(),
                  now: DateTime.now().toUtc(),
                ))
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Some policy details or deadlines still need confirmation. Review each unresolved requirement.',
                ),
              ),
            if (result != null && result.matches.isEmpty)
              const Text(
                'No program routes are currently configured for this case. Your saved assessment is still available.',
              ),
            if (result != null)
              for (final match in result.matches)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          match.programName,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        Text(switch (match.status) {
                          'meets_known_criteria' => 'Matches the known checks',
                          'does_not_meet_criterion' =>
                            'A known criterion is not met',
                          _ => 'More information is needed',
                        }),
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
                            label: const Text(
                              'Open RTP’s official application',
                            ),
                          ),
                        for (final check in match.checks)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(switch (check.status) {
                              'pass' => 'Met',
                              'fail' => 'Not met',
                              _ => 'Needs confirmation',
                            }),
                            subtitle: Text(check.explanation),
                          ),
                        ExpansionTile(
                          title: const Text('Program sources and review dates'),
                          children: [
                            ListTile(
                              title: Text(
                                'Availability: ${match.availability.replaceAll('_', ' ')}',
                              ),
                              subtitle: Text(
                                'Rule version: ${match.ruleVersion}',
                              ),
                            ),
                            for (final source in match.sources)
                              ListTile(
                                title: Text(source.title),
                                trailing: const Icon(
                                  Icons.open_in_new,
                                  semanticLabel: 'Opens in your browser',
                                ),
                                onTap: () => _openSource(source.url),
                                subtitle: SelectableText(
                                  'Reviewed ${source.reviewedOn}\nEffective from: ${source.effectiveFrom ?? 'not specified'}\nEffective until: ${source.effectiveUntil ?? 'not specified'}\n${source.url}',
                                ),
                              ),
                            if (match.sources.isEmpty)
                              const ListTile(
                                title: Text(
                                  'No verified source references are supplied for this route.',
                                ),
                              ),
                          ],
                        ),
                        OutlinedButton(
                          onPressed: !same
                              ? null
                              : () => _open(
                                  ProgramIntakeScreen(
                                    services: widget.services,
                                    program: match,
                                  ),
                                ),
                          child: const Text('Review program questions'),
                        ),
                        OutlinedButton(
                          onPressed: !same
                              ? null
                              : () => _open(
                                  DraftPacketScreen(
                                    snapshot: c.currentCase(),
                                    program: match,
                                    service: ApiPacketPreparationService(
                                      widget.services.packets,
                                    ),
                                    currentCase: c.currentCase,
                                    caseChanges: c,
                                  ),
                                ),
                          child: const Text('Draft checklist'),
                        ),
                        OutlinedButton(
                          onPressed: !same
                              ? null
                              : () => _open(
                                  FormReviewScreen(
                                    services: widget.services,
                                    program: match,
                                  ),
                                ),
                          child: const Text('Review administrative answers'),
                        ),
                        FilledButton(
                          onPressed: !same
                              ? null
                              : () => _open(
                                  PrivateExportScreen(
                                    services: widget.services,
                                    program: match,
                                  ),
                                ),
                          child: const Text('Review evidence and draft PDF'),
                        ),
                        TextButton(
                          onPressed: !same
                              ? null
                              : () => _open(
                                  RequestHistoryScreen(
                                    services: widget.services,
                                    program: match,
                                  ),
                                ),
                          child: const Text('Manual request history'),
                        ),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
