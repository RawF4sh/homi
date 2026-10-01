import 'package:flutter/material.dart';
import '../../app/live_app.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/presentation/sah_components.dart';
import '../programs/live_programs_screen.dart';
import '../assessment/presentation/live_assessment_screen.dart';
import 'case_display_details.dart';
import 'profile_editor_screen.dart';
import 'plan_name_dialog.dart';

class CaseWorkspaceScreen extends StatefulWidget {
  const CaseWorkspaceScreen({super.key, required this.services});
  final AppServices services;

  @override
  State<CaseWorkspaceScreen> createState() => _CaseWorkspaceScreenState();
}

class _CaseWorkspaceScreenState extends State<CaseWorkspaceScreen> {
  AppServices get services => widget.services;
  bool _renaming = false;

  Future<void> _rename() async {
    final c = services.coordinator;
    final draft = c.draft;
    final route = ModalRoute.of(context);
    if (_renaming ||
        draft == null ||
        c.busy ||
        c.hasUndurableEdits ||
        !c.isCurrent ||
        route?.isCurrent != true) {
      return;
    }
    final generation = c.generation;
    setState(() => _renaming = true);
    try {
      await c.loadPlanName(draft.caseId);
      try {
        await c.syncPlanName(draft.caseId);
      } catch (_) {
        if (!c.isCurrent) rethrow;
      }
      if (!mounted ||
          !c.isCurrent ||
          generation != c.generation ||
          route?.isCurrent != true) {
        return;
      }
      await showPlanNameDialog(
        context: context,
        initialName: c.planNameFor(draft.caseId),
        coordinator: c,
        caseId: draft.caseId,
        defaultName: homePlanTitle(draft),
        onSave: (value) async {
          if (!c.isCurrent || generation != c.generation) {
            throw StateError(
              'The selected account or plan changed. Reopen the name editor.',
            );
          }
          await c.savePlanName(draft.caseId, value);
        },
      );
    } catch (error) {
      if (mounted && route?.isCurrent == true && c.isCurrent) {
        await showOperationError(context, error);
      }
    } finally {
      if (mounted) setState(() => _renaming = false);
    }
  }

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      if (context.mounted) await showOperationError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: services.coordinator,
    builder: (context, _) {
      final c = services.coordinator;
      final draft = c.draft;
      if (draft == null) {
        return const Scaffold(
          body: SafeArea(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: SahEmptyState(
                title: 'This case is no longer selected.',
                message: 'Return to your cases to open it again.',
                icon: Icons.folder_open_outlined,
              ),
            ),
          ),
        );
      }
      final profile = draft.profile.toJson();
      final answered = profile.values.where((v) => v != null).length;
      final saved = draft.findings
          .where((f) => f.reviewState != 'dismissed')
          .toList();
      final toReview = saved
          .where((f) => f.reviewState == 'needs_review')
          .length;
      final programsBlocked =
          c.busy ||
          c.snapshot == null ||
          c.hasUnsavedChanges ||
          c.uncertain ||
          c.conflict;
      final problem =
          c.localSaveFailed ||
          c.localWritePending ||
          c.busy ||
          c.conflict ||
          c.uncertain;
      void open(Widget screen) => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => screen));
      final next = _nextStep(
        context,
        answered: answered,
        unsaved: c.snapshot == null || c.hasUnsavedChanges,
        neverSaved: c.snapshot == null,
        savedFindings: saved.length,
        toReview: toReview,
        onProfile: () => open(ProfileEditorScreen(services: services)),
        onSave: () => _run(context, c.save),
        onAssessment: () => open(LiveAssessmentScreen(services: services)),
        onPrograms: () => open(LiveProgramsScreen(services: services)),
      );
      return Scaffold(
        appBar: AppBar(
          title: Text(
            c.planNameFor(draft.caseId) ?? homePlanTitle(draft),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              key: const ValueKey('plan-rename'),
              tooltip: 'Rename plan',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _renaming || c.busy || c.hasUndurableEdits
                  ? null
                  : _rename,
            ),
          ],
        ),
        body: SafeArea(
          child: SahContent(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (!problem) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SahStatusBadge(
                        key: const ValueKey('case-save-badge'),
                        label: c.snapshot == null
                            ? 'Saved on this device'
                            : c.hasUnsavedChanges
                            ? 'Changes not saved online'
                            : 'Saved online',
                        icon: c.snapshot == null || c.hasUnsavedChanges
                            ? Icons.phone_iphone_rounded
                            : Icons.cloud_done_outlined,
                        tone: c.snapshot == null || c.hasUnsavedChanges
                            ? SahNoticeTone.info
                            : SahNoticeTone.success,
                      ),
                    ],
                  ),
                  if (c.notice != null && !c.notice!.startsWith('Saved'))
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        c.notice!,
                        key: const ValueKey('case-latest-update'),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  next,
                ] else ...[
                  SahNotice(
                    key: const ValueKey('case-save-status'),
                    title: c.localSaveFailed
                        ? 'Not saved on this device'
                        : c.localWritePending
                        ? 'Saving on this device'
                        : c.busy
                        ? 'Case update in progress'
                        : c.conflict
                        ? 'Case versions need review'
                        : 'Save confirmation needed',
                    message: c.localSaveFailed
                        ? 'Keep this case open and retry.'
                        : c.localWritePending
                        ? 'Wait before leaving this case.'
                        : c.busy
                        ? 'Wait for confirmation.'
                        : c.conflict
                        ? 'The saved case and this device differ.'
                        : 'A save may already have worked. Check before saving again.',
                    icon: c.localSaveFailed
                        ? Icons.error_outline
                        : c.localWritePending || c.busy
                        ? Icons.sync_rounded
                        : Icons.sync_problem_outlined,
                    tone: c.localSaveFailed
                        ? SahNoticeTone.error
                        : c.uncertain || c.conflict
                        ? SahNoticeTone.warning
                        : SahNoticeTone.info,
                  ),
                  if (c.notice != null)
                    Text(
                      c.notice!,
                      key: const ValueKey('case-latest-update'),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  if (c.localSaveFailed)
                    OutlinedButton.icon(
                      key: const ValueKey('case-retry-device-save'),
                      onPressed: c.busy || c.localWritePending
                          ? null
                          : () => _run(context, c.retryDeviceSave),
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Retry saving on this device'),
                    ),
                  if (c.busy)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: LinearProgressIndicator(
                        semanticsLabel: 'Updating saved case',
                      ),
                    ),
                  if (c.conflict) ...[
                    ExpansionTile(
                      title: const Text('Compare versions'),
                      children: [
                        _CaseVersionSummary(
                          title: 'Saved online',
                          draft: c.snapshot == null
                              ? null
                              : CaseDraft.fromSnapshot(c.snapshot!),
                        ),
                        _CaseVersionSummary(
                          title: 'On this device',
                          draft: draft,
                        ),
                      ],
                    ),
                    OutlinedButton(
                      onPressed: c.busy
                          ? null
                          : () => _run(
                              context,
                              () => c.resolveConflict(keepLocal: false),
                            ),
                      child: const Text('Use the saved version'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: c.busy
                          ? null
                          : () => _run(
                              context,
                              () => c.resolveConflict(keepLocal: true),
                            ),
                      child: const Text('Keep my edits for another save'),
                    ),
                  ],
                  const SizedBox(height: 8),
                  if (c.uncertain) ...[
                    FilledButton(
                      key: const ValueKey('case-check-saved-state'),
                      onPressed: c.busy
                          ? null
                          : () => _run(context, c.reconcile),
                      child: const Text('Check saved state'),
                    ),
                    const SizedBox(height: 10),
                  ],
                  FilledButton.icon(
                    key: const ValueKey('case-save-online'),
                    onPressed: c.busy || c.uncertain || c.conflict
                        ? null
                        : () => _run(context, c.save),
                    icon: const Icon(Icons.cloud_upload_outlined),
                    label: const Text('Retry sync'),
                  ),
                  if (!c.uncertain)
                    TextButton(
                      key: const ValueKey('case-check-saved-state'),
                      onPressed: c.busy
                          ? null
                          : () => _run(context, c.reconcile),
                      child: const Text('Check saved state'),
                    ),
                ],
                const SahSectionHeading(title: 'Your plan'),
                SahActionTile(
                  key: const ValueKey('case-profile'),
                  overline: 'Step 1 · Resident',
                  title: 'Resident details',
                  subtitle: answered == 0
                      ? null
                      : '${draft.profile.city ?? 'City not provided'} · ${draft.profile.healthPlan ?? 'Health plan not provided'}',
                  status: answered == 0
                      ? 'Not started'
                      : '$answered of ${profile.length} answered',
                  statusIcon: answered == 0
                      ? Icons.radio_button_unchecked_rounded
                      : Icons.edit_note_rounded,
                  icon: Icons.person_outline_rounded,
                  onTap: c.busy
                      ? null
                      : () => open(ProfileEditorScreen(services: services)),
                ),
                SahActionTile(
                  key: const ValueKey('case-assessment'),
                  overline: 'Step 2 · Rooms and concerns',
                  title: 'Home assessment',
                  subtitle: c.snapshot == null
                      ? 'Save online first.'
                      : 'Choose a room or area. Record what is difficult with a scan, photos or notes.',
                  status: c.snapshot == null
                      ? 'Cannot start yet'
                      : saved.isEmpty
                      ? 'No findings saved online yet'
                      : '${saved.length} saved online · '
                            '${toReview == 0 ? 'none to review' : '$toReview to review'}',
                  statusIcon: c.snapshot == null
                      ? Icons.lock_outline_rounded
                      : saved.isEmpty
                      ? Icons.radio_button_unchecked_rounded
                      : Icons.cloud_done_outlined,
                  icon: Icons.home_outlined,
                  onTap: c.busy
                      ? null
                      : () async {
                          if (c.snapshot == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Save this case online once to start the assessment. After that it also works offline.',
                                ),
                              ),
                            );
                            return;
                          }
                          open(LiveAssessmentScreen(services: services));
                        },
                ),
                SahActionTile(
                  key: const ValueKey('case-programs'),
                  overline: 'Step 3 · Improvements and assistance',
                  title: 'Possible assistance and drafts',
                  subtitle: programsBlocked ? 'Save online first.' : null,
                  status: programsBlocked
                      ? 'Cannot start yet'
                      : 'Ready to check',
                  statusIcon: programsBlocked
                      ? Icons.lock_outline_rounded
                      : Icons.arrow_forward_rounded,
                  icon: Icons.article_outlined,
                  onTap: programsBlocked
                      ? null
                      : () => open(LiveProgramsScreen(services: services)),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

Widget _nextStep(
  BuildContext context, {
  required int answered,
  required bool unsaved,
  required bool neverSaved,
  required int savedFindings,
  required int toReview,
  required VoidCallback onProfile,
  required VoidCallback onSave,
  required VoidCallback onAssessment,
  required VoidCallback onPrograms,
}) {
  final (String title, String description, Widget action) = switch (null) {
    _ when neverSaved && answered == 0 => (
      'Add resident details',
      'Skip anything you don’t know.',
      FilledButton.icon(
        key: const ValueKey('case-next-profile'),
        onPressed: onProfile,
        icon: const Icon(Icons.person_outline_rounded),
        label: const Text('Add details'),
      ),
    ),
    _ when unsaved => (
      'Changes waiting to sync',
      neverSaved
          ? 'Your details are on this device. Connect to finish syncing and start the assessment.'
          : 'Your edits are on this device. Connect to sync them before checking programs.',
      FilledButton.icon(
        key: const ValueKey('case-save-online'),
        onPressed: onSave,
        icon: const Icon(Icons.cloud_upload_outlined),
        label: const Text('Retry sync'),
      ),
    ),
    _ when savedFindings == 0 => (
      'Assess the home',
      'Describe where getting around is difficult. Scan the bathroom or add notes and photos from any area.',
      FilledButton.icon(
        key: const ValueKey('case-next-assessment'),
        onPressed: onAssessment,
        icon: const Icon(Icons.home_outlined),
        label: const Text('Open assessment'),
      ),
    ),
    _ when toReview > 0 => (
      'Review your findings',
      '$toReview saved ${toReview == 1 ? 'finding needs' : 'findings need'} your check.',
      FilledButton.icon(
        key: const ValueKey('case-next-assessment'),
        onPressed: onAssessment,
        icon: const Icon(Icons.rate_review_outlined),
        label: const Text('Open assessment'),
      ),
    ),
    _ => (
      'Check possible assistance',
      'See which programs may fit and what is still unknown.',
      FilledButton.icon(
        key: const ValueKey('case-next-programs'),
        onPressed: onPrograms,
        icon: const Icon(Icons.arrow_forward_rounded),
        label: const Text('See programs'),
      ),
    ),
  };
  return SahFeaturePanel(
    key: const ValueKey('case-next-step'),
    eyebrow: 'NEXT STEP',
    title: title,
    description: description,
    action: action,
  );
}

class _CaseVersionSummary extends StatelessWidget {
  const _CaseVersionSummary({required this.title, required this.draft});
  final String title;
  final CaseDraft? draft;
  @override
  Widget build(BuildContext context) {
    final value = draft;
    if (value == null) return Text('$title: no saved case');
    const names = {
      'city': 'City',
      'county': 'County',
      'healthPlan': 'Health plan',
      'tenure': 'Housing',
      'ageYears': 'Age',
      'householdSize': 'Household size',
      'annualIncomeUsd': 'Annual household income (USD)',
      'ownerConsentReported': 'Owner consent reported',
    };
    String display(Object? item) => switch (item) {
      null => 'Not provided',
      true => 'Yes',
      false => 'No',
      'owner' => 'Owner',
      'renter' => 'Renter',
      _ => item.toString(),
    };
    String words(String text) => text
        .replaceAll('_', ' ')
        .replaceAllMapped(
          RegExp(r'([a-z])([A-Z])'),
          (m) => '${m[1]} ${m[2]!.toLowerCase()}',
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            for (final entry in value.profile.toJson().entries)
              Text('${names[entry.key]}: ${display(entry.value)}'),
            const SizedBox(height: 8),
            Text('${value.findings.length} home findings'),
            for (final finding in value.findings)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  '${words(finding.room)} · ${words(finding.reviewState)}\n'
                  '${finding.observation}\n'
                  '${finding.evidenceIds.length} photos'
                  '${finding.measurements.isEmpty ? '' : '\n${finding.measurements.map((m) => '${words(m.type)}: ${m.value} mm (${m.method}, ${m.confirmed ? 'confirmed' : 'needs review'})').join('; ')}'}',
                ),
              ),
            if (value.unresolvedFields.isNotEmpty)
              Text(
                'Still to answer: ${value.unresolvedFields.map(words).join(', ')}',
              ),
          ],
        ),
      ),
    );
  }
}
