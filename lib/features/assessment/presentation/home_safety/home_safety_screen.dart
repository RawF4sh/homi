import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../app/live_app.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/models/case_draft.dart';
import '../../../../shared/presentation/sah_components.dart';
import '../../../../shared/services/matching_api_client.dart';
import '../../application/home_safety/home_safety_session.dart';
import '../../domain/assessment_location.dart';
import '../../domain/home_safety/home_safety.dart';
import '../live_assessment_screen.dart';

class HomeSafetyScreen extends StatefulWidget {
  const HomeSafetyScreen({super.key, required this.services, this.catalog});
  final HomeSafetyCatalog? catalog;
  final AppServices services;
  @override
  State<HomeSafetyScreen> createState() => _HomeSafetyScreenState();
}

class _HomeSafetyScreenState extends State<HomeSafetyScreen> {
  HomeSafetySession? session;
  late Future<void> ready;
  String? selectedRoom, error;
  bool working = false;
  @override
  void initState() {
    super.initState();
    ready = initialize();
  }

  Future<void> initialize() async {
    final catalog = widget.catalog ?? await HomeSafetyCatalog.load();
    if (!mounted) return;
    final next = HomeSafetySession(services: widget.services, catalog: catalog);
    session = next;
    await next.initialize();
  }

  bool get enabled =>
      !working && session?.busy != true && session?.isCurrent == true;
  bool get editable =>
      enabled && session?.conflict == null && session?.needsReconcile == false;
  String roomTitle(RoomInstance r) => r.name ?? context.tr(r.type.title);
  Future<void> run(Future<void> Function() action) async {
    if (!enabled) return;
    setState(() {
      working = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => error =
              e is MatchingApiException && e.code == 'HOME_SAFETY_HISTORY_LIMIT'
              ? 'The checklist history limit has been reached. Existing work is retained.'
              : 'This step could not finish. Your saved device changes are retained. Check saved state before trying again.',
        );
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> roomDialog([RoomInstance? room]) async {
    final s = session!;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RoomDialog(room: room, onSave: s.edit),
    );
  }

  Future<void> review(RoomInstance room, SafetyQuestion q) async {
    final s = session!, answer = s.document.answer(room.id, q.id)!;
    final link = s.document.link(room.id, q.id);
    final finding = s.snapshot.findings
        .where((f) => f.id == link?.findingId)
        .firstOrNull;
    final findingId = link?.findingId ?? newUuidV4();
    final note =
        finding?.observation ??
        '${roomTitle(room)}: ${context.tr(q.prompt)} ${context.tr('Reported answer')}: ${context.tr(answerLabel(answer.value))}';
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ConcernDialog(
        observation: note,
        state: finding?.reviewState ?? 'needs_review',
        onSave: (result) => s.edit({
          'type': 'review_concern',
          'roomId': room.id,
          'questionId': q.id,
          'findingId': findingId,
          ...result,
        }),
      ),
    );
  }

  Future<void> assign(RoomInstance room) async {
    final s = session!;
    final candidates = s.snapshot.findings
        .where((f) => !s.document.findingRooms.any((l) => l.findingId == f.id))
        .toList();
    final id = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(context.tr('Link an existing concern')),
        children: [
          for (final finding in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, finding.id),
              child: Text(finding.observation),
            ),
          if (candidates.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(context.tr('No unassigned concerns.')),
            ),
        ],
      ),
    );
    if (id != null && mounted && s.isCurrent) {
      await run(
        () => s.edit({
          'type': 'assign_finding',
          'roomId': room.id,
          'findingId': id,
        }),
      );
    }
  }

  Future<void> openFinding(String id) => run(() async {
    final s = session!;
    await s.save();
    s.guard();
    if (s.hasPending || s.conflict != null || s.caseWriteBlocked || !mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LiveAssessmentScreen(
          services: widget.services,
          initialFindingId: id,
        ),
      ),
    );
    if (!mounted) return;
    s.guard();
    await s.refresh();
  });
  Future<void> resolve(bool keepDevice) async {
    final s = session!, fresh = s.conflict!;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('Review device and saved changes')),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  context.tr(
                    keepDevice
                        ? 'Apply the device changes below to the latest saved version? You will still need to save online.'
                        : 'Use the saved version and discard these device changes?',
                  ),
                ),
                for (final request in s.pending)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: _ConflictChange(
                      operation: request.operation,
                      device: s.document,
                      saved: fresh.document,
                      deviceSnapshot: s.snapshot.toJson(),
                      savedSnapshot: fresh.snapshot.toJson(),
                      catalog: s.catalog,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              context.tr(
                keepDevice
                    ? 'Keep device changes for review'
                    : 'Use saved checklist',
              ),
            ),
          ),
        ],
      ),
    );
    if (accepted == true && mounted && s.isCurrent) {
      await run(() => s.resolve(keepDevice: keepDevice));
    }
  }

  @override
  void dispose() {
    session?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: ready,
    builder: (context, loading) {
      final s = session;
      if (loading.hasError) {
        return Scaffold(
          appBar: AppBar(title: Text(context.tr('Rooms and checklist'))),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                context.tr(
                  'The checklist could not be opened. Existing device changes have been kept. Reopen the case to try again.',
                ),
              ),
            ),
          ),
        );
      }
      if (loading.connectionState != ConnectionState.done || s == null) {
        return Scaffold(
          appBar: AppBar(title: Text(context.tr('Rooms and checklist'))),
          body: const Center(child: CircularProgressIndicator()),
        );
      }
      return AnimatedBuilder(
        animation: s,
        builder: (context, _) {
          final room = s.document.rooms
              .where((r) => r.id == selectedRoom)
              .firstOrNull;
          return PopScope(
            canPop: room == null && !working && !s.busy,
            onPopInvokedWithResult: (popped, result) {
              if (!popped && room != null && enabled) {
                setState(() => selectedRoom = null);
              }
            },
            child: Scaffold(
              appBar: AppBar(
                title: Text(
                  room == null
                      ? context.tr('Rooms and checklist')
                      : roomTitle(room),
                ),
                leading: BackButton(
                  onPressed: enabled
                      ? () {
                          if (room != null) {
                            setState(() => selectedRoom = null);
                          } else {
                            Navigator.pop(context);
                          }
                        }
                      : null,
                ),
                actions: [
                  IconButton(
                    tooltip: context.tr('Check saved state'),
                    onPressed: enabled ? () => run(s.refresh) : null,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              body: SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: ListView(
                      padding: const EdgeInsets.all(20),
                      children: [
                        Text(
                          context.tr(
                            'Home safety questions adapted from CDC STEADI. This is not a clinical fall-risk score or a safety certification.',
                          ),
                        ),
                        TextButton(
                          onPressed: enabled
                              ? () => run(() async {
                                  if (!await launchUrl(
                                    Uri.parse(s.catalog.sourceUrl),
                                    mode: LaunchMode.externalApplication,
                                  )) {
                                    throw StateError('Source unavailable.');
                                  }
                                })
                              : null,
                          child: Text(context.tr('View CDC source (2017)')),
                        ),
                        Text(
                          context.tr(
                            'Checklist translations are provided by the app; they are not official CDC translations.',
                          ),
                        ),
                        if (error != null)
                          SahNotice(
                            message: context.tr(error!),
                            tone: SahNoticeTone.warning,
                          ),
                        if (s.localSaveFailed)
                          SahNotice(
                            message: context.tr(
                              'The device save failed. Keep this screen open and try again.',
                            ),
                            tone: SahNoticeTone.error,
                          ),
                        if (s.offline)
                          SahNotice(
                            message: context.tr(
                              'Your checklist is saved on this device. Online saving is unavailable right now. You can keep working here.',
                            ),
                          ),
                        if (s.caseWriteBlocked)
                          SahNotice(
                            message: context.tr(
                              'Resident details have unsaved changes. You can continue the checklist here; resolve those details before syncing.',
                            ),
                          ),
                        if (s.conflict != null) ...[
                          SahNotice(
                            message: context.tr(
                              'This device and the saved checklist differ. Review both before continuing.',
                            ),
                            tone: SahNoticeTone.warning,
                          ),
                          OutlinedButton(
                            onPressed: enabled ? () => resolve(true) : null,
                            child: Text(
                              context.tr('Keep device changes for review'),
                            ),
                          ),
                          TextButton(
                            onPressed: enabled ? () => resolve(false) : null,
                            child: Text(context.tr('Use saved checklist')),
                          ),
                        ] else if (s.needsReconcile)
                          OutlinedButton(
                            onPressed: enabled ? () => run(s.refresh) : null,
                            child: Text(context.tr('Check saved state')),
                          ),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            context.tr(
                              s.hasPending
                                  ? 'Saved on this device · {count} changes to sync'
                                  : s.offline
                                  ? 'Checklist kept on this device'
                                  : 'Checklist saved online',
                              {'count': s.pending.length},
                            ),
                          ),
                        ),
                        if (s.hasPending)
                          FilledButton.icon(
                            key: const ValueKey('rooms-sync'),
                            onPressed: editable && !s.caseWriteBlocked
                                ? () => run(s.save)
                                : null,
                            icon: const Icon(Icons.cloud_upload_outlined),
                            label: Text(context.tr('Save checklist online')),
                          ),
                        const SizedBox(height: 16),
                        if (room == null)
                          ...roomList(s)
                        else
                          ...roomChecklist(s, room),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );

  List<Widget> roomList(HomeSafetySession s) => [
    FilledButton.icon(
      key: const ValueKey('rooms-add'),
      onPressed: editable && s.document.rooms.length < 32 ? roomDialog : null,
      icon: const Icon(Icons.add),
      label: Text(context.tr('Add a room')),
    ),
    if (s.document.rooms.isEmpty)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          context.tr(
            'Add each room separately, including rooms of the same type. Photos are optional.',
          ),
        ),
      ),
    for (final room in s.document.rooms)
      Card(
        child: ListTile(
          key: ValueKey('room-${room.id}'),
          title: Text(roomTitle(room)),
          subtitle: Text(
            context.tr('{count} of {total} questions answered', {
              'count': s.catalog
                  .forRoom(room)
                  .where(
                    (q) =>
                        s.document.answer(room.id, q.id)?.value !=
                            'unanswered' &&
                        s.document.answer(room.id, q.id) != null,
                  )
                  .length,
              'total': s.catalog.forRoom(room).length,
            }),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: enabled ? () => setState(() => selectedRoom = room.id) : null,
        ),
      ),
  ];
  List<Widget> roomChecklist(HomeSafetySession s, RoomInstance room) => [
    Wrap(
      spacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: editable ? () => roomDialog(room) : null,
          icon: const Icon(Icons.edit_outlined),
          label: Text(context.tr('Rename room')),
        ),
        TextButton(
          onPressed: editable ? () => assign(room) : null,
          child: Text(context.tr('Link an existing concern')),
        ),
      ],
    ),
    Text(
      context.tr(
        'Choose Not applicable for features this room does not have. Not sure and unanswered remain unknown.',
      ),
    ),
    for (final q in s.catalog.forRoom(room))
      _QuestionCard(
        question: q,
        answer: s.document.answer(room.id, q.id),
        link: s.document.link(room.id, q.id),
        findingPresent: s.snapshot.findings.any(
          (f) => f.id == s.document.link(room.id, q.id)?.findingId,
        ),
        editable: editable,
        onAnswer: (value) => run(
          () => s.edit({
            'type': 'answer',
            'roomId': room.id,
            'questionId': q.id,
            'value': value,
          }),
        ),
        onReview: () => review(room, q),
        onPhoto: () => openFinding(s.document.link(room.id, q.id)!.findingId),
        onlineReady: editable && !s.caseWriteBlocked,
      ),
    for (final link in s.document.findingRooms.where(
      (l) => l.roomId == room.id && l.questionId == null,
    ))
      for (final finding in s.snapshot.findings.where(
        (f) => f.id == link.findingId,
      ))
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(finding.observation),
                TextButton(
                  onPressed: editable && !s.caseWriteBlocked
                      ? () => openFinding(finding.id)
                      : null,
                  child: Text(context.tr('Photos and measurements')),
                ),
              ],
            ),
          ),
        ),
  ];
}

String answerLabel(String value) => switch (value) {
  'yes' => 'Yes',
  'no' => 'No',
  'not_sure' => 'Not sure',
  'not_applicable' => 'Not applicable',
  _ => 'Unanswered',
};

class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.question,
    required this.answer,
    required this.link,
    required this.findingPresent,
    required this.editable,
    required this.onAnswer,
    required this.onReview,
    required this.onPhoto,
    required this.onlineReady,
  });
  final SafetyQuestion question;
  final SafetyAnswer? answer;
  final FindingRoom? link;
  final bool findingPresent, editable, onlineReady;
  final ValueChanged<String> onAnswer;
  final VoidCallback onReview, onPhoto;
  @override
  Widget build(BuildContext context) {
    final concern = answer?.value == question.concernWhen;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.tr(question.prompt),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            InputDecorator(
              decoration: InputDecoration(labelText: context.tr('Your answer')),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  key: ValueKey('answer-${question.id}'),
                  value: answer?.value ?? 'unanswered',
                  isExpanded: true,
                  items: [
                    for (final value in safetyAnswerValues)
                      DropdownMenuItem(
                        value: value,
                        child: Text(context.tr(answerLabel(value))),
                      ),
                  ],
                  onChanged: editable
                      ? (v) {
                          if (v != null &&
                              v != (answer?.value ?? 'unanswered')) {
                            onAnswer(v);
                          }
                        }
                      : null,
                ),
              ),
            ),
            if (concern) ...[
              const SizedBox(height: 12),
              Text(
                context.tr(
                  'Possible concern — review before adding to your assessment.',
                ),
              ),
              Text(context.tr(question.guidance)),
            ],
            if (link != null && link!.answerRevision != answer?.revision)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  context.tr(
                    'The answer changed. Review the linked concern; it has not been automatically removed.',
                  ),
                ),
              ),
            if (link != null && !findingPresent)
              Text(
                context.tr(
                  'The linked concern was removed in the assessment. Its checklist history is retained.',
                ),
              ),
            if ((concern || link != null) && (link == null || findingPresent))
              TextButton(
                onPressed: editable ? onReview : null,
                child: Text(
                  context.tr(
                    link == null ? 'Review concern' : 'Review linked concern',
                  ),
                ),
              ),
            if (link != null && findingPresent)
              TextButton(
                onPressed: onlineReady ? onPhoto : null,
                child: Text(context.tr('Photos and measurements')),
              ),
          ],
        ),
      ),
    );
  }
}

mixin _DurableDialog<T extends StatefulWidget> on State<T> {
  bool saving = false;
  String? error;
  Future<void> saveOperation(
    Map<String, Object?> operation,
    Future<void> Function(Map<String, Object?>) callback,
  ) async {
    if (saving) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await callback(operation);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'The device save failed. Your input is still here; try again before closing.',
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }
}

class _RoomDialog extends StatefulWidget {
  const _RoomDialog({this.room, required this.onSave});
  final RoomInstance? room;
  final Future<void> Function(Map<String, Object?>) onSave;
  @override
  State<_RoomDialog> createState() => _RoomDialogState();
}

class _RoomDialogState extends State<_RoomDialog> with _DurableDialog {
  late final name = TextEditingController(text: widget.room?.name ?? '');
  late final roomId = widget.room?.id ?? newUuidV4();
  late AssessmentLocation type =
      widget.room?.type ?? AssessmentLocation.bedroom;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: Text(
        context.tr(widget.room == null ? 'Add a room' : 'Rename room'),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.room == null)
              DropdownButtonFormField<AssessmentLocation>(
                initialValue: type,
                isExpanded: true,
                decoration: InputDecoration(labelText: context.tr('Room type')),
                items: [
                  for (final value in AssessmentLocation.values)
                    DropdownMenuItem(
                      value: value,
                      child: Text(context.tr(value.title)),
                    ),
                ],
                onChanged: saving
                    ? null
                    : (v) {
                        if (v != null) setState(() => type = v);
                      },
              ),
            const SizedBox(height: 12),
            TextField(
              controller: name,
              enabled: !saving,
              maxLength: 80,
              decoration: InputDecoration(
                labelText: context.tr('Room name (optional)'),
                hintText: context.tr('For example: Upstairs bathroom'),
              ),
            ),
            if (error != null) Text(context.tr(error!)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: Text(context.tr('Cancel')),
        ),
        FilledButton(
          onPressed: saving
              ? null
              : () {
                  final text = name.text.trim();
                  try {
                    roomName(text.isEmpty ? null : text);
                  } catch (_) {
                    setState(
                      () => error =
                          'Use a single-line name of up to 80 characters.',
                    );
                    return;
                  }
                  saveOperation(
                    widget.room == null
                        ? {
                            'type': 'add_room',
                            'room': RoomInstance(
                              id: roomId,
                              type: type,
                              name: text.isEmpty ? null : text,
                            ).toJson(),
                          }
                        : {
                            'type': 'rename_room',
                            'roomId': roomId,
                            'name': text.isEmpty ? null : text,
                          },
                    widget.onSave,
                  );
                },
          child: Text(context.tr('Save on device')),
        ),
      ],
    ),
  );
}

class _ConcernDialog extends StatefulWidget {
  const _ConcernDialog({
    required this.observation,
    required this.state,
    required this.onSave,
  });
  final String observation, state;
  final Future<void> Function(Map<String, Object?>) onSave;
  @override
  State<_ConcernDialog> createState() => _ConcernDialogState();
}

class _ConcernDialogState extends State<_ConcernDialog> with _DurableDialog {
  late final note = TextEditingController(text: widget.observation);
  late String state = widget.state;
  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: Text(context.tr('Review concern')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.tr(
                'Describe what you observed. Confirming a concern does not establish medical need or program eligibility.',
              ),
            ),
            TextField(
              controller: note,
              enabled: !saving,
              minLines: 2,
              maxLines: 6,
              maxLength: 500,
              decoration: InputDecoration(labelText: context.tr('Observation')),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: state,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: context.tr('Review state'),
              ),
              items: [
                for (final entry in {
                  'needs_review': 'Needs review',
                  'confirmed': 'Confirmed',
                  'dismissed': 'Dismissed',
                }.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: Text(context.tr(entry.value)),
                  ),
              ],
              onChanged: saving
                  ? null
                  : (v) {
                      if (v != null) setState(() => state = v);
                    },
            ),
            if (error != null) Text(context.tr(error!)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: Text(context.tr('Cancel')),
        ),
        FilledButton(
          onPressed: saving
              ? null
              : () {
                  final text = note.text.trim();
                  if (text.isEmpty ||
                      text.length > 500 ||
                      RegExp(r'[\x00-\x1f]').hasMatch(text)) {
                    setState(
                      () => error =
                          'Enter an observation of up to 500 characters on one line.',
                    );
                    return;
                  }
                  saveOperation({
                    'observation': text,
                    'state': state,
                  }, widget.onSave);
                },
          child: Text(context.tr('Save reviewed concern')),
        ),
      ],
    ),
  );
}

class _ConflictChange extends StatelessWidget {
  const _ConflictChange({
    required this.operation,
    required this.device,
    required this.saved,
    required this.deviceSnapshot,
    required this.savedSnapshot,
    required this.catalog,
  });
  final Map<String, Object?> operation, deviceSnapshot, savedSnapshot;
  final SafetyDocument device, saved;
  final HomeSafetyCatalog catalog;
  @override
  Widget build(BuildContext context) {
    final roomId = operation['roomId'] ?? (operation['room'] as Map?)?['id'];
    String describe(SafetyDocument doc, Map<String, Object?> snapshot) {
      final room = doc.rooms.where((r) => r.id == roomId).firstOrNull;
      final title =
          room?.name ??
          (room == null
              ? context.tr('Room not present')
              : context.tr(room.type.title));
      if (operation['type'] == 'answer') {
        return '$title · ${context.tr(answerLabel(doc.answer(roomId as String, operation['questionId'] as String)?.value ?? 'unanswered'))}';
      }
      if (operation['type'] == 'review_concern' ||
          operation['type'] == 'assign_finding') {
        final finding = (snapshot['findings'] as List)
            .cast<Map>()
            .where((f) => f['id'] == operation['findingId'])
            .firstOrNull;
        return '$title · ${finding?['observation'] ?? context.tr('Concern not present')}';
      }
      return title;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (operation['questionId'] != null)
          Text(
            context.tr(
              catalog.question(operation['questionId'] as String).prompt,
            ),
          ),
        Text(
          context.tr('Device: {value}', {
            'value': describe(device, deviceSnapshot),
          }),
        ),
        Text(
          context.tr('Saved: {value}', {
            'value': describe(saved, savedSnapshot),
          }),
        ),
      ],
    );
  }
}
