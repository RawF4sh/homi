import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../../../app/live_app.dart';
import '../../../shared/services/matching_api_client.dart';
import '../application/live_assessment_session.dart';
import 'assessment_flow_screen.dart';
import 'save_status_card.dart';

class LiveAssessmentScreen extends StatefulWidget {
  const LiveAssessmentScreen({super.key, required this.services});
  final AppServices services;
  @override
  State<LiveAssessmentScreen> createState() => _LiveAssessmentScreenState();
}

class _LiveAssessmentScreenState extends State<LiveAssessmentScreen>
    with WidgetsBindingObserver {
  late final LiveAssessmentSession session = LiveAssessmentSession(
    services: widget.services,
    context: () => context,
  );
  late final Future<void> ready;
  bool busy = false, canPop = false;
  String? notice;
  Uint8List? recoveredPhoto;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ready = session.initialize();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      notice = null;
    });
    try {
      await action();
    } on MatchingApiException catch (error) {
      if (mounted) setState(() => notice = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => notice =
              'This step could not finish. Your local edits are retained. Check saved state before trying again.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> close() => run(() async {
    await session.flush();
    if (!mounted) return;
    setState(() => canPop = true);
    Navigator.of(context).pop();
  });

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      session.flush().catchError((Object _) {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: canPop,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) close();
    },
    child: FutureBuilder<void>(
      future: ready,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('Home assessment')),
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Text(
                    'The saved assessment could not be opened. Your private draft has been kept. Check your connection and open this case again.',
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () {
                      setState(() => canPop = true);
                      Navigator.of(context).pop();
                    },
                    child: const Text('Back to case'),
                  ),
                ],
              ),
            ),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(
                semanticsLabel: 'Opening assessment',
              ),
            ),
          );
        }
        return ListenableBuilder(
          listenable: session,
          builder: (context, _) => AssessmentFlowScreen(
            flow: session.flow,
            enabled:
                !busy &&
                (!session.localConflict || session.caseWriteBlocked) &&
                session.sync.recoveryConflict == null,
            actions: [
              IconButton(
                onPressed: busy ? null : history,
                tooltip: 'Saved review history',
                icon: const Icon(Icons.history),
              ),
              IconButton(
                onPressed: busy ? null : close,
                tooltip: 'Save on device and close',
                icon: const Icon(Icons.close),
              ),
            ],
            status: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (notice != null) Text(notice!, semanticsLabel: notice),
                if (session.resumeNotice != null) Text(session.resumeNotice!),
                if (session.caseWriteNotice != null)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(session.caseWriteNotice!),
                    ),
                  ),
                if (session.localSaveFailed)
                  const Text(
                    'The private device save failed. Keep this screen open and free some device space before leaving.',
                  ),
                if (session.localConflict)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'This device and the saved assessment differ. Keeping this device’s findings will replace the saved assessment when you explicitly save. Other profile details stay from the latest saved case.',
                          ),
                          Text(
                            'Device: ${session.controller.findings.length} findings. Saved: ${session.state?.caseSnapshot.findings.length ?? 0} findings.',
                          ),
                          OutlinedButton(
                            onPressed: busy || session.caseWriteBlocked
                                ? null
                                : () => run(
                                    () => session.resolveLocalConflict(
                                      keepLocal: true,
                                    ),
                                  ),
                            child: const Text(
                              'Keep this device’s findings for review',
                            ),
                          ),
                          TextButton(
                            onPressed: busy || session.caseWriteBlocked
                                ? null
                                : () => run(
                                    () => session.resolveLocalConflict(
                                      keepLocal: false,
                                    ),
                                  ),
                            child: const Text(
                              'Discard device edits and use saved assessment',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (session.sync.recoveryConflict != null)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'A photo is saved, but the interrupted upload did not return a receipt. Look at the saved photo before choosing which version to keep.',
                          ),
                          if (recoveredPhoto != null)
                            Image.memory(
                              recoveredPhoto!,
                              height: 240,
                              cacheWidth: 1024,
                              fit: BoxFit.contain,
                              semanticLabel: 'Current saved photo',
                            ),
                          OutlinedButton(
                            onPressed: busy
                                ? null
                                : () => run(() async {
                                    final bytes = await session.sync
                                        .showRecoveredEvidence();
                                    if (mounted) {
                                      setState(() => recoveredPhoto = bytes);
                                    }
                                  }),
                            child: const Text('Show saved photo'),
                          ),
                          FilledButton(
                            onPressed: busy || recoveredPhoto == null
                                ? null
                                : () => run(() async {
                                    await session.sync
                                        .acceptRecoveredEvidence();
                                    await session.flow.refreshSavedImages();
                                    await session.flush();
                                    recoveredPhoto = null;
                                  }),
                            child: const Text('Keep the saved photo'),
                          ),
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => run(() async {
                                    session.sync.keepLocalEvidence();
                                    await session.flush();
                                    recoveredPhoto = null;
                                  }),
                            child: const Text(
                              'Keep device photo to upload after review',
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (!session.localConflict && !session.caseWriteBlocked)
                  SaveStatusCard(
                    sync: session.sync,
                    durableLocal: !session.localSaveFailed,
                    onSave: () => run(session.save),
                    onRecover: () => run(session.recover),
                  ),
                if (session.annotationNotice != null)
                  Text(session.annotationNotice!),
                if (session.annotationConflictId != null)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => run(session.reloadConflictingMarks),
                    child: const Text(
                      'Discard device marks for this photo and reload saved marks',
                    ),
                  ),
                if (!session.localConflict &&
                    session.sync.recoveryConflict == null)
                  TextButton(
                    onPressed: busy || session.caseWriteBlocked
                        ? null
                        : () => run(session.save),
                    child: const Text('Save findings and photo marks online'),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );

  void history() {
    final events = session.state?.history.reversed.toList() ?? [];
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Saved assessment history'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: events.isEmpty
                  ? [
                      const Text(
                        'No online assessment corrections have been saved yet.',
                      ),
                    ]
                  : [
                      for (final event in events)
                        ExpansionTile(
                          title: Text(
                            DateTime.tryParse(
                                  event['recordedAt'] as String? ?? '',
                                )?.toLocal().toString() ??
                                'Saved review',
                          ),
                          subtitle: const Text(
                            'Recorded by the signed-in account',
                          ),
                          children: [
                            for (final change in event['changes'] as List)
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text(
                                  '${_changeName((change as Map)['path'])}\nBefore: ${_display(change['before'])}\nAfter: ${_display(change['after'])}',
                                ),
                              ),
                          ],
                        ),
                    ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

String _changeName(Object? path) {
  final text = path.toString();
  if (text.contains('measurement')) return 'Measurement details';
  if (text.contains('review')) return 'Review decision';
  if (text.contains('finding')) return 'Finding details';
  return 'Assessment details';
}

String _display(Object? value) {
  if (value == null) return 'None recorded';
  if (value is List) return value.map(_display).join('; ');
  if (value is Map) {
    return value.entries
        .where((e) => !{'id', 'findingId', 'evidenceIds'}.contains(e.key))
        .map((e) => '${e.key}: ${_display(e.value)}')
        .join(', ');
  }
  return value.toString();
}
