import '../sharing/sharing_screens.dart';
import '../assistant/plan_assistant_screen.dart';
import '../assistant/assistant_app_context.dart';
import '../assistant/assistant_context_v2.dart';
import '../../shared/navigation/homi_destination.dart';
import '../assistant/assistant_runtime.dart';
import '../settings/account_settings_screen.dart';
import '../../shared/presentation/sah_floating_nav.dart';
import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import '../../app/live_app.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/presentation/sah_components.dart';
import '../programs/live_programs_screen.dart';
import '../tracking/program_progress_screen.dart';
import '../local_help/local_help_screen.dart';
import '../assessment/domain/measurement/measurement_fields.dart';
import '../assessment/domain/home_safety/home_safety.dart';
import '../assessment/presentation/live_assessment_screen.dart';
import '../assessment/presentation/home_safety/home_safety_screen.dart';
import 'case_display_details.dart';
import 'profile_editor_screen.dart';
import 'plan_name_dialog.dart';

class CaseWorkspaceScreen extends StatefulWidget {
  const CaseWorkspaceScreen({
    super.key,
    required this.services,
    this.homeSafetyCatalog,
    this.embedded = false,
    this.destination = 0,
    this.onDestinationSelected,
  });
  final AppServices services;
  final HomeSafetyCatalog? homeSafetyCatalog;
  final bool embedded;
  final int destination;
  final ValueChanged<int>? onDestinationSelected;

  @override
  State<CaseWorkspaceScreen> createState() => CaseWorkspaceScreenState();
}

class CaseWorkspaceScreenState extends State<CaseWorkspaceScreen> {
  AppServices get services => widget.services;
  bool _renaming = false;
  int _standaloneTab = 0;
  int get _tab => widget.embedded ? widget.destination : _standaloneTab;
  final Set<int> _visited = {0};
  bool get canLeave =>
      !services.coordinator.hasUndurableEdits &&
      !services.coordinator.busy &&
      !_renaming &&
      _roomsKey.currentState?.canLeave != false &&
      _tasksKey.currentState?.canLeave != false &&
      _legacyKey.currentState?.canLeave != false &&
      _settingsKey.currentState?.canLeave != false &&
      _programsKey.currentState?.canLeave != false &&
      _localHelpKey.currentState?.canLeave != false;
  bool handleBack() =>
      _tab == 1 &&
      ((_roomsKey.currentState?.handleBack() ?? false) ||
          (_legacyKey.currentState?.handleBack() ?? false));
  Future<bool> prepareToLeave() async =>
      canLeave && (await _legacyKey.currentState?.prepareToLeave() ?? true);
  final _programsKey = GlobalKey<LiveProgramsScreenState>();
  final _localHelpKey = GlobalKey<LocalHelpScreenState>();
  final _legacyKey = GlobalKey<LiveAssessmentScreenState>();
  final _settingsKey = GlobalKey<AccountSettingsScreenState>();
  bool _showLocalHelp = false;
  bool _visitedLocalHelp = false;

  String? _roomId;
  final _roomsKey = GlobalKey<HomeSafetyScreenState>();
  final _tasksKey = GlobalKey<ProgramProgressScreenState>();

  void _selectTab(int value) {
    if (value == _tab || !services.coordinator.isCurrent) return;
    if (!canLeave) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('Finish saving before changing sections.')),
        ),
      );
      return;
    }
    if (_roomsKey.currentState != null) {
      _roomId = _roomsKey.currentState!.selectedRoom;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    if (widget.onDestinationSelected != null) {
      widget.onDestinationSelected!(value);
    } else {
      setState(() => _standaloneTab = value);
    }
  }

  AssistantContextV2 get assistantContext =>
      assistantContextAt(HomiDestination.values[_tab]);

  AssistantContextV2 assistantContextAt(HomiDestination destination) =>
      assistantAppContext(
        services,
        destination: destination,
        rooms: _roomsKey.currentState?.session,
        matches: _programsKey.currentState?.assistantMatches,
      );

  /// Called only after the chat decoder resolves an allowlisted source. Check
  /// the current case again because changing the shell can await a save guard.
  void openAssistantTarget(HomiTarget target) {
    if (!mounted ||
        !services.coordinator.isCurrent ||
        target.caseId != services.coordinator.draft?.caseId ||
        !canLeave) {
      return;
    }
    final previousDestination = HomiDestination.values[_tab];
    final expectedContext = assistantContextAt(previousDestination).key;
    if (target.destination == HomiDestination.help) {
      setState(() => _showLocalHelp = false);
    }
    _selectTab(target.destination.index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !services.coordinator.isCurrent ||
          target.caseId != services.coordinator.draft?.caseId ||
          _tab != target.destination.index ||
          assistantContextAt(previousDestination).key != expectedContext) {
        return;
      }
      if (target.roomId != null) {
        _roomsKey.currentState?.openAssistantRoom(
          target.roomId!,
          findingId: target.findingId,
        );
      }
      if (target.taskId != null) {
        _tasksKey.currentState?.openAssistantTask(target.taskId!);
      }
      if (target.programId != null) {
        _programsKey.currentState?.openAssistantProgram(target.programId!);
      }
    });
  }

  void _assistant() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlanAssistantScreen(
          coordinator: services.coordinator,
          model: assistantRuntime(),
          appContextProvider: () => assistantContext,
          onTarget: (target) {
            Navigator.of(context).pop();
            openAssistantTarget(target);
          },
          onSection: (section) {
            Navigator.of(context).pop();
            _selectTab(section);
          },
        ),
      ),
    );
  }

  Widget _helpLinks(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      TextButton(
        onPressed: () => setState(() => _showLocalHelp = false),
        child: Text(context.tr('Assistance programs')),
      ),
      if (services.config.localHelpEnabled)
        TextButton.icon(
          key: const ValueKey('case-local-help'),
          onPressed: services.coordinator.hasUndurableEdits
              ? null
              : () => setState(() {
                  _showLocalHelp = true;
                  _visitedLocalHelp = true;
                }),
          icon: const Icon(Icons.location_on_outlined),
          label: Text(context.tr('Local providers')),
        ),
    ],
  );

  Widget _unavailableSection(
    BuildContext context, {
    required String title,
    required String message,
    bool help = false,
  }) => SahContent(
    child: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (help) _helpLinks(context),
        SahNotice(message: context.tr(message)),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => _selectTab(0),
          child: Text(context.tr('Return to plan')),
        ),
      ],
    ),
  );

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
    listenable: Listenable.merge([
      services.coordinator,
      if (services.progress != null) services.progress!,
    ]),
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
      final progress = services.progress;
      final savedProgress = progress?.cached[draft.caseId];
      final today = DateTime.now().toIso8601String().substring(0, 10);
      final due =
          savedProgress?.caseRevision == c.snapshot?.revision &&
              progress?.pending.containsKey(draft.caseId) != true
          ? savedProgress?.tasks
                .where(
                  (t) =>
                      t.open &&
                      t.state != 'blocked' &&
                      !t.needsReview &&
                      t.dueOn != null &&
                      t.dueOn!.compareTo(today) <= 0,
                )
                .toList()
          : null;
      due?.sort((a, b) => a.dueOn!.compareTo(b.dueOn!));
      final next = _nextStep(
        context,
        taskTitle: due?.firstOrNull?.title,
        onTasks: () => _selectTab(3),
        answered: answered,
        unsaved: c.snapshot == null || c.hasUnsavedChanges,
        neverSaved: c.snapshot == null,
        savedFindings: saved.length,
        toReview: toReview,
        onProfile: () => open(ProfileEditorScreen(services: services)),
        onSave: () => _run(context, c.save),
        onAssessment: () => _selectTab(1),
        onPrograms: () => _selectTab(2),
      );
      final overview = SafeArea(
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
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    key: const ValueKey('plan-rename'),
                    onPressed: _renaming || c.busy || c.hasUndurableEdits
                        ? null
                        : _rename,
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(context.tr('Rename plan')),
                  ),
                  if (services.config.permissionSharingEnabled)
                    TextButton.icon(
                      onPressed: programsBlocked
                          ? null
                          : () => open(
                              PeopleWithAccessScreen(services: services),
                            ),
                      icon: const Icon(Icons.people_outline),
                      label: Text(context.tr('People with access')),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (!problem) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      c.snapshot == null
                          ? context.tr('Saved on this device')
                          : c.hasUnsavedChanges
                          ? context.tr('Changes not saved online')
                          : context.tr('Saved online'),
                      key: const ValueKey('case-save-badge'),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
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
                    onPressed: c.busy ? null : () => _run(context, c.reconcile),
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
                    onPressed: c.busy ? null : () => _run(context, c.reconcile),
                    child: Text(context.tr('Check saved state')),
                  ),
              ],
              SahSectionHeading(title: context.tr('Your plan')),
              SahActionTile(
                key: const ValueKey('case-profile'),
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
              SahActionTile(
                key: const ValueKey('case-rooms'),
                title: context.tr('Rooms'),
                subtitle: context.tr('Scans, photos and measurements'),
                icon: Icons.grid_view_outlined,
                onTap: () => _selectTab(1),
              ),
              SahActionTile(
                key: const ValueKey('case-programs'),
                title: context.tr('Assistance programs'),
                icon: Icons.support_agent_outlined,
                onTap: () => _selectTab(2),
              ),
              SahActionTile(
                key: const ValueKey('case-tasks'),
                title: context.tr('Tasks'),
                icon: Icons.checklist,
                onTap: () => _selectTab(3),
              ),
              SahActionTile(
                key: const ValueKey('case-documents'),
                title: context.tr('Sharing and documents'),
                subtitle: context.tr(
                  'Review draft documents in Assistance programs',
                ),
                icon: Icons.description_outlined,
                onTap: () => _selectTab(2),
              ),
            ],
          ),
        ),
      );
      Widget section(int tab) => switch (tab) {
        1 when c.snapshot != null && services.config.homeSafetyEnabled =>
          HomeSafetyScreen(
            key: _roomsKey,
            catalog: widget.homeSafetyCatalog,
            services: services,
            workspaceMode: true,
            embedded: true,
            initialRoomId: _roomId,
          ),
        1 when c.snapshot != null => LiveAssessmentScreen(
          key: _legacyKey,
          services: services,
          embedded: true,
        ),
        1 => _unavailableSection(
          context,
          title: 'Rooms',
          message:
              'Sync this plan once to start. Saved rooms can then be edited offline.',
        ),
        2 => Column(
          children: [
            _helpLinks(context),
            Expanded(
              child: IndexedStack(
                index: _showLocalHelp ? 1 : 0,
                children: [
                  c.snapshot != null
                      ? LiveProgramsScreen(
                          key: _programsKey,
                          services: services,
                          workspaceMode: true,
                          embedded: true,
                        )
                      : _unavailableSection(
                          context,
                          title: 'Help',
                          message:
                              'Sync your plan before checking assistance. Local contacts are still available.',
                        ),
                  _visitedLocalHelp
                      ? LocalHelpScreen(
                          key: _localHelpKey,
                          services: services,
                          embedded: true,
                        )
                      : const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
        3 when c.snapshot != null && services.config.trackingEnabled =>
          ProgramProgressScreen(
            key: _tasksKey,
            services: services,
            tasksFirst: true,
            workspaceMode: true,
            embedded: true,
          ),
        3 => _unavailableSection(
          context,
          title: 'Tasks',
          message: services.config.trackingEnabled
              ? 'Sync your plan before updating tasks.'
              : 'Tasks are disabled in this build. Check feature availability in Settings.',
        ),
        4 => AccountSettingsScreen(
          key: _settingsKey,
          services: services,
          embedded: true,
        ),
        _ => overview,
      };
      _visited.add(_tab);
      final body = IndexedStack(
        index: _tab,
        children: [
          for (var index = 0; index < 5; index++)
            _visited.contains(index)
                ? TickerMode(enabled: index == _tab, child: section(index))
                : const SizedBox.shrink(),
        ],
      );
      if (widget.embedded) return body;
      return Scaffold(
        body: SafeArea(child: body),
        bottomNavigationBar: MediaQuery.viewInsetsOf(context).bottom > 0
            ? null
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton.icon(
                    key: const ValueKey('ask-homi'),
                    onPressed: _assistant,
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: Text(
                      context.tr('Ask Homi'),
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  SahFloatingNavBar(
                    selectedIndex: _tab,
                    onDestinationSelected: _selectTab,
                    destinations: homiDestinations(context),
                  ),
                ],
              ),
      );
    },
  );
}

Widget _nextStep(
  BuildContext context, {
  String? taskTitle,
  required VoidCallback onTasks,
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
    _ when taskTitle != null => (
      context.tr('Review your next task'),
      taskTitle,
      FilledButton.icon(
        key: const ValueKey('case-next-task'),
        onPressed: onTasks,
        icon: const Icon(Icons.checklist_rounded),
        label: Text(context.tr('Open tasks')),
      ),
    ),
    _ when savedFindings == 0 => (
      context.tr('Start with a room'),
      context.tr('Choose a room, then scan or answer a few questions.'),
      FilledButton.icon(
        key: const ValueKey('case-next-assessment'),
        onPressed: onAssessment,
        icon: const Icon(Icons.home_outlined),
        label: Text(context.tr('Open rooms')),
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
        label: Text(context.tr('Open rooms')),
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
    neutral: true,
    eyebrow: context.tr('Suggested next step'),
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
