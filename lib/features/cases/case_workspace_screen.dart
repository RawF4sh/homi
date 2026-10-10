import '../sharing/sharing_screens.dart';
import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import '../../app/live_app.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/presentation/sah_components.dart';
import '../programs/live_programs_screen.dart';
import '../tracking/program_progress_screen.dart';
import '../local_help/local_help_screen.dart';
import '../assessment/domain/measurement/measurement_fields.dart';
import '../assessment/presentation/live_assessment_screen.dart';
import '../assessment/presentation/home_safety/home_safety_screen.dart';
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
        defaultName: homePlanTitle(draft, context: context),
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
        return Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(24),
              child: SahEmptyState(
                title: context.tr('This case is no longer selected.'),
                message: context.tr('Return to your cases to open it again.'),
                icon: Icons.folder_open_outlined,
              ),
            ),
          ),
        );
      }
      final profile = draft.profile.toJson();
      final planTitle =
          c.planNameFor(draft.caseId) ?? homePlanTitle(draft, context: context);
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
          title: Text(planTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            if (services.config.permissionSharingEnabled)
              IconButton(
                tooltip: context.tr('People with access'),
                icon: const Icon(Icons.people_outline),
                onPressed: programsBlocked
                    ? null
                    : () => open(PeopleWithAccessScreen(services: services)),
              ),
            IconButton(
              key: const ValueKey('plan-rename'),
              tooltip: context.tr('Rename plan'),
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
                Semantics(
                  header: true,
                  child: Text(
                    planTitle,
                    key: const ValueKey('case-plan-title'),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                const SizedBox(height: 16),
                if (!problem) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SahStatusBadge(
                        key: const ValueKey('case-save-badge'),
                        label: c.snapshot == null
                            ? context.tr('Saved on this device')
                            : c.hasUnsavedChanges
                            ? context.tr('Changes not saved online')
                            : context.tr('Saved online'),
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
                        context.tr(c.notice!),
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
                        ? context.tr('Not saved on this device')
                        : c.localWritePending
                        ? context.tr('Saving on this device')
                        : c.busy
                        ? context.tr('Case update in progress')
                        : c.conflict
                        ? context.tr('Case versions need review')
                        : context.tr('Save confirmation needed'),
                    message: c.localSaveFailed
                        ? context.tr('Keep this case open and retry.')
                        : c.localWritePending
                        ? context.tr('Wait before leaving this case.')
                        : c.busy
                        ? context.tr('Wait for confirmation.')
                        : c.conflict
                        ? context.tr('The saved case and this device differ.')
                        : context.tr(
                            'A save may already have worked. Check before saving again.',
                          ),
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
                      context.tr(c.notice!),
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
                      label: Text(context.tr('Retry saving on this device')),
                    ),
                  if (c.busy)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: LinearProgressIndicator(
                        semanticsLabel: context.tr('Updating saved case'),
                      ),
                    ),
                  if (c.conflict) ...[
                    ExpansionTile(
                      title: Text(context.tr('Compare versions')),
                      children: [
                        _CaseVersionSummary(
                          title: context.tr('Saved online'),
                          draft: c.snapshot == null
                              ? null
                              : CaseDraft.fromSnapshot(c.snapshot!),
                        ),
                        _CaseVersionSummary(
                          title: context.tr('On this device'),
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
                      child: Text(context.tr('Use the saved version')),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: c.busy
                          ? null
                          : () => _run(
                              context,
                              () => c.resolveConflict(keepLocal: true),
                            ),
                      child: Text(context.tr('Keep my edits for another save')),
                    ),
                  ],
                  const SizedBox(height: 8),
                  if (c.uncertain) ...[
                    FilledButton(
                      key: const ValueKey('case-check-saved-state'),
                      onPressed: c.busy
                          ? null
                          : () => _run(context, c.reconcile),
                      child: Text(context.tr('Check saved state')),
                    ),
                    const SizedBox(height: 10),
                  ],
                  FilledButton.icon(
                    key: const ValueKey('case-save-online'),
                    onPressed: c.busy || c.uncertain || c.conflict
                        ? null
                        : () => _run(context, c.save),
                    icon: const Icon(Icons.cloud_upload_outlined),
                    label: Text(context.tr('Retry sync')),
                  ),
                  if (!c.uncertain)
                    TextButton(
                      key: const ValueKey('case-check-saved-state'),
                      onPressed: c.busy
                          ? null
                          : () => _run(context, c.reconcile),
                      child: Text(context.tr('Check saved state')),
                    ),
                ],
                if (services.config.localHelpEnabled)
                  SahActionTile(
                    key: const ValueKey('case-local-help'),
                    title: context.tr('Find local help'),
                    subtitle: context.tr(
                      'Official referrals, saved contacts and follow-ups',
                    ),
                    icon: Icons.support_agent,
                    onTap: c.busy || c.hasUndurableEdits
                        ? null
                        : () => open(LocalHelpScreen(services: services)),
                  ),
                SahSectionHeading(title: context.tr('Your plan')),
                SahActionTile(
                  key: const ValueKey('case-profile'),
                  overline: context.tr('Step 1 · Resident'),
                  title: context.tr('Resident details'),
                  subtitle: answered == 0
                      ? null
                      : '${draft.profile.city ?? context.tr('City not provided')} · ${draft.profile.healthPlan ?? context.tr('Health plan not provided')}',
                  status: answered == 0
                      ? context.tr('Not started')
                      : context.tr('{count} of {total} answered', {
                          'count': answered,
                          'total': profile.length,
                        }),
                  statusIcon: answered == 0
                      ? Icons.radio_button_unchecked_rounded
                      : Icons.edit_note_rounded,
                  icon: Icons.person_outline_rounded,
                  onTap: c.busy
                      ? null
                      : () => open(ProfileEditorScreen(services: services)),
                ),
                if (services.config.homeSafetyEnabled)
                  SahActionTile(
                    key: const ValueKey('case-rooms-checklist'),
                    title: context.tr('Rooms and checklist'),
                    subtitle: context.tr(
                      'Name each room and review home safety questions. Photos are optional.',
                    ),
                    icon: Icons.checklist_rounded,
                    onTap: c.busy || c.snapshot == null
                        ? null
                        : () => open(HomeSafetyScreen(services: services)),
                  ),
                SahActionTile(
                  key: const ValueKey('case-assessment'),
                  overline: context.tr('Step 2 · Rooms and concerns'),
                  title: context.tr('Home assessment'),
                  subtitle: c.snapshot == null
                      ? context.tr('Save online first.')
                      : context.tr(
                          'Choose a room or area. Record what is difficult with a scan, photos or notes.',
                        ),
                  status: c.snapshot == null
                      ? context.tr('Cannot start yet')
                      : saved.isEmpty
                      ? context.tr('No findings saved online yet')
                      : toReview == 0
                      ? context.tr('{count} saved online · none to review', {
                          'count': saved.length,
                        })
                      : context.tr(
                          '{count} saved online · {review} to review',
                          {'count': saved.length, 'review': toReview},
                        ),
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
                              SnackBar(
                                content: Text(
                                  context.tr(
                                    'Save this case online once to start the assessment. After that it also works offline.',
                                  ),
                                ),
                              ),
                            );
                            return;
                          }
                          open(LiveAssessmentScreen(services: services));
                        },
                ),
                if (services.config.trackingEnabled)
                  SahActionTile(
                    key: const ValueKey('case-next-steps'),
                    title: context.tr('My next steps'),
                    subtitle: context.tr(
                      'Program progress, tasks, and device reminders',
                    ),
                    icon: Icons.checklist_rounded,
                    onTap: programsBlocked
                        ? null
                        : () => open(
                            ProgramProgressScreen(
                              services: services,
                              tasksFirst: true,
                            ),
                          ),
                  ),
                SahActionTile(
                  key: const ValueKey('case-programs'),
                  overline: context.tr('Step 3 · Improvements and assistance'),
                  title: context.tr('Possible assistance and drafts'),
                  subtitle: programsBlocked
                      ? context.tr('Save online first.')
                      : null,
                  status: programsBlocked
                      ? context.tr('Cannot start yet')
                      : context.tr('Ready to check'),
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
      context.tr('Add resident details'),
      context.tr('Skip anything you don’t know.'),
      FilledButton.icon(
        key: const ValueKey('case-next-profile'),
        onPressed: onProfile,
        icon: const Icon(Icons.person_outline_rounded),
        label: Text(context.tr('Add details')),
      ),
    ),
    _ when unsaved => (
      context.tr('Changes waiting to sync'),
      neverSaved
          ? context.tr(
              'Your details are on this device. Connect to finish syncing and start the assessment.',
            )
          : context.tr(
              'Your edits are on this device. Connect to sync them before checking programs.',
            ),
      FilledButton.icon(
        key: const ValueKey('case-save-online'),
        onPressed: onSave,
        icon: const Icon(Icons.cloud_upload_outlined),
        label: Text(context.tr('Retry sync')),
      ),
    ),
    _ when savedFindings == 0 => (
      context.tr('Assess the home'),
      context.tr(
        'Describe where getting around is difficult. Scan the bathroom or add notes and photos from any area.',
      ),
      FilledButton.icon(
        key: const ValueKey('case-next-assessment'),
        onPressed: onAssessment,
        icon: const Icon(Icons.home_outlined),
        label: Text(context.tr('Open assessment')),
      ),
    ),
    _ when toReview > 0 => (
      context.tr('Review your findings'),
      toReview == 1
          ? context.tr('{count} saved finding needs your check.', {
              'count': toReview,
            })
          : context.tr('{count} saved findings need your check.', {
              'count': toReview,
            }),
      FilledButton.icon(
        key: const ValueKey('case-next-assessment'),
        onPressed: onAssessment,
        icon: const Icon(Icons.rate_review_outlined),
        label: Text(context.tr('Open assessment')),
      ),
    ),
    _ => (
      context.tr('Check possible assistance'),
      context.tr('See which programs may fit and what is still unknown.'),
      FilledButton.icon(
        key: const ValueKey('case-next-programs'),
        onPressed: onPrograms,
        icon: const Icon(Icons.arrow_forward_rounded),
        label: Text(context.tr('See programs')),
      ),
    ),
  };
  return SahFeaturePanel(
    key: const ValueKey('case-next-step'),
    eyebrow: context.tr('NEXT STEP'),
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
    if (value == null) {
      return Text(context.tr('{title}: no saved case', {'title': title}));
    }
    final names = {
      'city': context.tr('City'),
      'county': context.tr('County'),
      'healthPlan': context.tr('Health plan'),
      'tenure': context.tr('Housing'),
      'ageYears': context.tr('Age'),
      'householdSize': context.tr('Household size'),
      'annualIncomeUsd': context.tr('Annual household income (USD)'),
      'ownerConsentReported': context.tr('Owner consent reported'),
    };
    String display(String field, Object? item) => switch (item) {
      null => context.tr('Not provided'),
      true => context.tr('Yes'),
      false => context.tr('No'),
      'owner' when field == 'tenure' => context.tr('Owner'),
      'renter' when field == 'tenure' => context.tr('Renter'),
      _ => item.toString(),
    };
    String roomLabel(String value) => switch (value) {
      'bathroom' => context.tr('Bathroom'),
      'entrance' => context.tr('Entrance'),
      'other' => context.tr('Other area'),
      _ => value,
    };
    String reviewLabel(String value) => switch (value) {
      'confirmed' => context.tr('Confirmed by you'),
      'needs_review' => context.tr('Needs your review'),
      'dismissed' => context.tr('Dismissed'),
      _ => value,
    };
    String methodLabel(String value) => switch (value) {
      'manual' => context.tr('Measured'),
      'estimated' => context.tr('Your estimate'),
      _ => value,
    };
    String words(String text) => text
        .replaceAll('_', ' ')
        .replaceAllMapped(
          RegExp(r'([a-z])([A-Z])'),
          (m) => '${m[1]} ${m[2]!.toLowerCase()}',
        );
    String measurementLabel(String type) {
      final label = measurementFieldSpecFor(type)?.label;
      return label == null ? words(type) : context.tr(label);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            for (final entry in value.profile.toJson().entries)
              Text('${names[entry.key]}: ${display(entry.key, entry.value)}'),
            const SizedBox(height: 8),
            Text(
              context.tr('{count} home findings', {
                'count': value.findings.length,
              }),
            ),
            for (final finding in value.findings)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  '${roomLabel(finding.room)} · ${reviewLabel(finding.reviewState)}\n'
                  '${finding.observation}\n'
                  '${context.tr('{count} photos', {'count': finding.evidenceIds.length})}'
                  '${finding.measurements.isEmpty ? '' : '\n${finding.measurements.map((m) => '${measurementLabel(m.type)}: ${m.value} mm (${methodLabel(m.method)}, ${m.confirmed ? context.tr('confirmed') : context.tr('needs review')})').join('; ')}'}',
                ),
              ),
            if (value.unresolvedFields.isNotEmpty)
              Text(
                context.tr('Still to answer: {fields}', {
                  'fields': value.unresolvedFields
                      .map((field) => names[field] ?? words(field))
                      .join(', '),
                }),
              ),
          ],
        ),
      ),
    );
  }
}
