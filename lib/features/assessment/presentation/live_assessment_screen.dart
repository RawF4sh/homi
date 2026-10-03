import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../../../app/live_app.dart';
import '../../../shared/services/matching_api_client.dart';
import '../application/live_assessment_session.dart';
import '../application/bathroom_scan_adapter.dart';
import '../application/bathroom_scan_availability.dart';
import 'assessment_scan_entry.dart';
import '../application/bathroom_scan_session.dart';
import 'assessment_flow_screen.dart';
import 'bathroom_scan_screen.dart';
import 'save_status_card.dart';
import '../application/assessment_sync.dart';
import '../../../shared/presentation/sah_components.dart';
import 'recovery_photo_review_card.dart';

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
  late final BathroomScanAvailability scanAvailability =
      BathroomScanAvailability(
        adapter:
            widget.services.bathroomScanAdapter ??
            const NativeBathroomScanAdapter(),
        isCurrent: () => mounted && session.isCurrent,
      );
  late final Future<void> ready;
  bool busy = false, canPop = false, initialized = false;
  String? notice;
  Uint8List? recoveredPhoto;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ready = session.initialize().then((_) {
      initialized = true;
      if (mounted) scanAvailability.refresh();
    });
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy || session.flow.isBusy) return;
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
    try {
      await ready;
    } catch (_) {
      // ignore: empty_catches
    }
    if (initialized) await session.flush();
    if (!mounted) return;
    setState(() => canPop = true);
    Navigator.of(context).pop();
  });

  Future<void> openBathroomScan() => run(() async {
    session.guard();
    await session.flush();
    session.guard();
    if (!mounted) return;
    final scanner = BathroomScanSession(
      store: widget.services.store,
      caseId: session.caseId,
      isCurrent: () => session.isCurrent,
      adapter:
          widget.services.bathroomScanAdapter ??
          const NativeBathroomScanAdapter(),
    );
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BathroomScanScreen(
          session: scanner,
          scope: session,
          importedFinding: (id) =>
              session.localSaveFailed ? null : session.importedScanFinding(id),
          activeImports: () => session.activeScanImports,
          onImport: session.importScanObservation,
        ),
      ),
    );
    session.guard();
    await session.flush();
    scanAvailability.refresh();
  });

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        initialized &&
        !busy &&
        ModalRoute.of(context)?.isCurrent == true) {
      scanAvailability.refresh();
    }
    if (initialized &&
        (state == AppLifecycleState.inactive ||
            state == AppLifecycleState.paused)) {
      Future<void>.sync(session.flush).catchError((Object _) {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    scanAvailability.dispose();
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
          void leaveUnopenedAssessment() {
            setState(() => canPop = true);
            Navigator.of(context).pop();
          }

          return Scaffold(
            appBar: AppBar(
              title: Text(context.tr('Home assessment')),
              leading: BackButton(onPressed: leaveUnopenedAssessment),
            ),
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          context.tr(
                            'The saved assessment could not be opened. Your private draft has been kept. Check your connection and open this case again.',
                          ),
                        ),
                        SizedBox(height: 24),
                        FilledButton(
                          key: const ValueKey('assessment-error-back'),
                          onPressed: leaveUnopenedAssessment,
                          child: Text(context.tr('Back to case')),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return Scaffold(
            body: Center(
              child: CircularProgressIndicator(
                semanticsLabel: context.tr('Opening assessment'),
              ),
            ),
          );
        }
        return ListenableBuilder(
          listenable: Listenable.merge([session, scanAvailability]),
          builder: (context, _) {
            final bool? marksUnsaved =
                session.annotationNotice != null ||
                    session.annotationConflictId != null
                ? null
                : session.photoMarksUnsaved;
            return AssessmentFlowScreen(
              flow: session.flow,
              keptOnDevice: !session.localSaveFailed,
              enabled:
                  !busy &&
                  (!session.localConflict || session.caseWriteBlocked) &&
                  session.sync.recoveryConflict == null,
              actions: [
                IconButton(
                  onPressed: busy ? null : history,
                  tooltip: context.tr('Saved review history'),
                  icon: const Icon(Icons.history),
                ),
                IconButton(
                  onPressed: busy || session.flow.isBusy ? null : close,
                  tooltip: context.tr('Save on device and close'),
                  icon: const Icon(Icons.close),
                ),
              ],
              areaToolsFirst: scanAvailability.prefersScan,
              areaTools: AssessmentScanEntry(
                availability: scanAvailability,
                onCheck: busy || !session.isCurrent
                    ? null
                    : scanAvailability.refresh,
                onOpen:
                    busy ||
                        session.flow.isBusy ||
                        session.localConflict ||
                        !session.sync.canSave
                    ? null
                    : openBathroomScan,
              ),
              status: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (notice != null)
                    SahNotice(
                      message: context.tr(notice!),
                      tone: SahNoticeTone.warning,
                    ),
                  if (session.resumeNotice != null)
                    SahNotice(
                      message: context.tr(session.resumeNotice!),
                      icon: Icons.cloud_off_outlined,
                    ),
                  if (session.caseWriteNotice != null)
                    SahNotice(
                      message: context.tr(session.caseWriteNotice!),
                      tone: SahNoticeTone.warning,
                    ),
                  if (session.localSaveFailed)
                    SahNotice(
                      title: context.tr('Not saved on this device'),
                      message: context.tr(
                        'The private device save failed. Keep this screen open and free some device space before leaving.',
                      ),
                      tone: SahNoticeTone.error,
                    ),
                  if (session.localConflict) ...[
                    SahNotice(
                      title: context.tr(
                        'This device and the saved assessment differ',
                      ),
                      message: context.tr(
                        'Keeping this device’s findings will replace the saved assessment when you explicitly save. Other profile details stay from the latest saved case.\n\nDevice: {deviceCount} findings. Saved: {savedCount} findings.',
                        {
                          'deviceCount': session.controller.findings.length,
                          'savedCount':
                              session.state?.caseSnapshot.findings.length ?? 0,
                        },
                      ),
                      tone: SahNoticeTone.warning,
                    ),
                    OutlinedButton(
                      onPressed:
                          busy ||
                              session.flow.isBusy ||
                              session.caseWriteBlocked
                          ? null
                          : () => run(
                              () =>
                                  session.resolveLocalConflict(keepLocal: true),
                            ),
                      child: Text(
                        context.tr('Keep this device’s findings for review'),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    TextButton(
                      onPressed:
                          busy ||
                              session.flow.isBusy ||
                              session.caseWriteBlocked
                          ? null
                          : () => run(
                              () => session.resolveLocalConflict(
                                keepLocal: false,
                              ),
                            ),
                      child: Text(
                        context.tr(
                          'Discard device edits and use saved assessment',
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    SizedBox(height: 8),
                  ],
                  if (session.sync.recoveryConflict != null)
                    RecoveryPhotoReviewCard(
                      bytes: recoveredPhoto,
                      busy: busy,
                      onShowSaved: () => run(() async {
                        setState(() => recoveredPhoto = null);
                        final bytes = await session.sync
                            .showRecoveredEvidence();
                        if (mounted) setState(() => recoveredPhoto = bytes);
                      }),
                      onKeepSaved: () => run(() async {
                        await session.sync.acceptRecoveredEvidence();
                        await session.flow.refreshSavedImages();
                        await session.flush();
                        recoveredPhoto = null;
                      }),
                      onKeepDevice: () => run(() async {
                        session.sync.keepLocalEvidence();
                        await session.flush();
                        recoveredPhoto = null;
                      }),
                    )
                  else if (!session.localConflict && !session.caseWriteBlocked)
                    SaveStatusCard(
                      sync: session.sync,
                      durableLocal: !session.localSaveFailed,
                      undescribedDraftOpen: session
                          .controller
                          .incompleteFindingIds
                          .any(
                            (id) => !session.sync.savedCase.findings.any(
                              (f) => f.id == id,
                            ),
                          ),
                      photoMarksUnsaved: marksUnsaved,
                      enabled: !busy && !session.flow.isBusy,
                      onSave: () => run(session.save),
                      onRecover: () => run(session.recover),
                    ),
                  if (session.annotationNotice != null)
                    SahNotice(
                      message: context.tr(session.annotationNotice!),
                      tone: SahNoticeTone.warning,
                    ),
                  if (session.annotationConflictId != null)
                    TextButton(
                      onPressed: busy || session.flow.isBusy
                          ? null
                          : () => run(session.reloadConflictingMarks),
                      child: Text(
                        context.tr(
                          'Discard device marks for this photo and reload saved marks',
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (!session.localConflict &&
                      session.sync.recoveryConflict == null &&
                      session.sync.phase == SyncPhase.idle &&
                      !session.sync.hasUnsavedWork &&
                      marksUnsaved != true &&
                      session.controller.findings.any(
                        (f) => f.evidenceIds.isNotEmpty,
                      ))
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        key: const ValueKey('assessment-save-online'),
                        onPressed:
                            busy ||
                                session.flow.isBusy ||
                                session.caseWriteBlocked
                            ? null
                            : () => run(session.save),
                        icon: const Icon(Icons.cloud_upload_outlined),
                        label: Text(
                          context.tr('Save findings and photo marks online'),
                        ),
                      ),
                    ),
                  SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    ),
  );

  void history() {
    final events = session.state?.history.reversed.toList() ?? [];
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('Saved assessment history')),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: events.isEmpty
                  ? [
                      Text(
                        context.tr(
                          'No online assessment corrections have been saved yet.',
                        ),
                      ),
                    ]
                  : [
                      for (final event in events)
                        ExpansionTile(
                          title: Text(
                            DateTime.tryParse(
                                  event['recordedAt'] as String? ?? '',
                                )?.toLocal().toString() ??
                                context.tr('Saved review'),
                          ),
                          subtitle: Text(
                            context.tr('Recorded by the signed-in account'),
                          ),
                          children: [
                            for (final change in event['changes'] as List)
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text(
                                  context.tr(
                                    '{change}\nBefore: {before}\nAfter: {after}',
                                    {
                                      'change': context.tr(
                                        _changeName((change as Map)['path']),
                                      ),
                                      'before': _display(
                                        change['before'],
                                        context: context,
                                      ),
                                      'after': _display(
                                        change['after'],
                                        context: context,
                                      ),
                                    },
                                  ),
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
            child: Text(context.tr('Close')),
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

String _display(Object? value, {BuildContext? context}) {
  if (value == null) return context?.tr('None recorded') ?? 'None recorded';
  if (value is List) {
    return value.map((item) => _display(item, context: context)).join('; ');
  }
  if (value is Map) {
    return value.entries
        .where((e) => !{'id', 'findingId', 'evidenceIds'}.contains(e.key))
        .map((e) => '${e.key}: ${_display(e.value, context: context)}')
        .join(', ');
  }
  return value.toString();
}
