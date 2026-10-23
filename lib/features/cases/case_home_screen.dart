import '../sharing/sharing_screens.dart';
import '../local_help/nationwide_help_browser.dart';
import '../assistant/plan_assistant_screen.dart';
import '../assistant/assistant_app_context.dart';
import '../assistant/assistant_runtime.dart';
import '../../shared/navigation/homi_destination.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import '../../app/live_app.dart';
import '../../shared/models/case_list.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/presentation/sah_floating_nav.dart';
import '../settings/account_settings_screen.dart';
import 'case_display_details.dart';
import 'case_workspace_screen.dart';
import 'plan_deletion_action.dart';
import 'plan_deletion_dialog.dart';
import 'plan_name_dialog.dart';

class CaseHomeScreen extends StatefulWidget {
  const CaseHomeScreen({super.key, required this.services});
  final AppServices services;
  @override
  State<CaseHomeScreen> createState() => _CaseHomeScreenState();
}

class _CaseHomeScreenState extends State<CaseHomeScreen>
    with WidgetsBindingObserver {
  final _cases = <CaseSummary>[];
  List<String> _local = [];
  final _details = <String, CaseDisplayDetails>{};
  String? _cursor, _error;
  bool _discovering = false, _opening = false, _loaded = false;
  bool _refreshQueued = false;
  int _request = 0, _localRequest = 0;
  int _tab = 0;
  bool _managing = false;
  bool _switching = false;
  bool _openingReminder = false;
  var _workspaceKey = GlobalKey<CaseWorkspaceScreenState>();
  String? _workspaceCase;
  int? _workspaceGeneration;
  final _settingsKey = GlobalKey<AccountSettingsScreenState>();
  bool get _canLeave =>
      !_opening &&
      !_switching &&
      !widget.services.coordinator.busy &&
      !_selectionBlocked &&
      _workspaceKey.currentState?.canLeave != false &&
      _settingsKey.currentState?.canLeave != false;

  Future<void> _selectTab(int index) async {
    if ((index == _tab && !_managing) || !_isCurrent) return;
    if (!_canLeave) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('Finish saving before changing sections.')),
        ),
      );
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final generation = widget.services.coordinator.generation;
    setState(() => _switching = true);
    try {
      if (await _workspaceKey.currentState?.prepareToLeave() == false) return;
      await _refreshLocal();
      if (!_isCurrent ||
          generation != widget.services.coordinator.generation ||
          !_removalsReady) {
        return;
      }
      setState(() {
        _tab = index;
        _managing = false;
        _query = '';
        _searchController.clear();
      });
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  void _reminderChanged() {
    if (!mounted || !widget.services.reminderOpen.value) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _openReminder());
  }

  Future<void> _openReminder() async {
    if (!_isCurrent ||
        !widget.services.reminderOpen.value ||
        _openingReminder ||
        ModalRoute.of(context)?.isCurrent != true ||
        !_canLeave) {
      return;
    }
    _openingReminder = true;
    try {
      await _selectTab(3);
      if (_isCurrent && _tab == 3 && !_managing) {
        widget.services.reminderOpen.value = false;
        setState(() {});
      }
    } finally {
      _openingReminder = false;
    }
  }

  void _assistant() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlanAssistantScreen(
          coordinator: widget.services.coordinator,
          model: assistantRuntime(),
          appContextProvider: () =>
              _workspaceKey.currentState?.assistantContext ??
              assistantAppContext(
                widget.services,
                destination: HomiDestination.values[_tab],
              ),
          onTarget: (target) async {
            Navigator.of(context).pop();
            final c = widget.services.coordinator;
            final generation = c.generation;
            final previousDestination = HomiDestination.values[_tab];
            String contextKey() =>
                (_workspaceKey.currentState?.assistantContextAt(
                          previousDestination,
                        ) ??
                        assistantAppContext(
                          widget.services,
                          destination: previousDestination,
                        ))
                    .key;
            final expectedContext = contextKey();
            if (target.caseId != c.draft?.caseId) return;
            await _selectTab(target.destination.index);
            if (!_isCurrent ||
                generation != c.generation ||
                target.caseId != c.draft?.caseId ||
                _tab != target.destination.index ||
                contextKey() != expectedContext) {
              return;
            }
            _workspaceKey.currentState?.openAssistantTarget(target);
          },
          onSection: (index) {
            Navigator.of(context).pop();
            _selectTab(index);
          },
        ),
      ),
    );
  }

  String _query = '';
  final _searchController = TextEditingController();
  Map<String, PlanRemovalStatus> _removals = {};
  bool _removalsReady = false;
  bool _removalsFailed = false;
  bool get _isCurrent => mounted && widget.services.coordinator.isCurrent;
  bool get _selectionBlocked => widget.services.coordinator.hasUndurableEdits;
  void _caseChanged() {
    if (_isCurrent) {
      setState(() {
        final id = widget.services.coordinator.draft?.caseId;
        if (id != _workspaceCase ||
            widget.services.coordinator.generation != _workspaceGeneration) {
          _workspaceCase = id;
          _workspaceGeneration = widget.services.coordinator.generation;
          _workspaceKey = GlobalKey<CaseWorkspaceScreenState>();
        }
        _rememberCurrentDetails();
      });
    }
  }

  void _rememberCurrentDetails() {
    final coordinator = widget.services.coordinator;
    final draft = coordinator.draft;
    if (draft == null) return;
    _details[draft.caseId] = CaseDisplayDetails(
      draft: draft,
      snapshot: coordinator.snapshot,
      uncertain: coordinator.uncertain,
      conflict: coordinator.conflict,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _rememberCurrentDetails();
    widget.services.coordinator.addListener(_caseChanged);
    widget.services.reminderOpen.addListener(_reminderChanged);
    _reminderChanged();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    widget.services.coordinator.removeListener(_caseChanged);
    widget.services.reminderOpen.removeListener(_reminderChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isCurrent) unawaited(_load());
  }

  Future<void> _refreshLocal() async {
    final request = ++_localRequest;
    if (_isCurrent) setState(() => _removalsReady = false);
    try {
      final local = await widget.services.coordinator.localCaseIds();
      final removals = await readPendingPlanRemovals(widget.services);
      if (_isCurrent && request == _localRequest) {
        setState(() {
          _local = local;
          _removals = removals;
          _removalsReady = true;
          _removalsFailed = false;
          _details.removeWhere((id, _) => !local.contains(id));
          _rememberCurrentDetails();
        });
        unawaited(_loadLocalDetails(local, request));
      }
    } catch (_) {
      if (_isCurrent && request == _localRequest) {
        setState(() {
          _removalsReady = false;
          _removalsFailed = true;
        });
      }
    }
  }

  Future<void> _loadLocalDetails(List<String> ids, int request) async {
    for (final id in ids) {
      if (!_isCurrent || request != _localRequest) return;
      if (widget.services.coordinator.draft?.caseId == id) {
        try {
          await widget.services.coordinator.loadPlanName(id);
        } catch (_) {
          // ignore: empty_catches
        }
        continue;
      }
      try {
        await widget.services.coordinator.loadPlanName(id);
        if (!_isCurrent || request != _localRequest) return;
        final record = await widget.services.store.readJson('case.$id');
        if (!_isCurrent || request != _localRequest) return;
        if (record == null) continue;
        final details = CaseDisplayDetails.fromRecord(id, record);
        setState(() {
          _details[id] = details;
          _rememberCurrentDetails();
        });
      } catch (_) {
        // ignore: empty_catches
      }
    }
  }

  Future<void> _load({bool more = false}) async {
    if (!_isCurrent) return;
    unawaited(_refreshLocal());
    if (_discovering) {
      _refreshQueued = true;
      return;
    }
    final request = ++_request;
    bool current() => _isCurrent && request == _request && !_refreshQueued;
    setState(() {
      _discovering = true;
      _error = null;
    });
    try {
      final page = await widget.services.planNames.listCases(
        afterCaseId: more ? _cursor : null,
        isCurrent: current,
      );
      if (!current()) return;
      final summaries = page.cases.map((item) => item.summary).toList();
      widget.services.coordinator.rememberListedCases(summaries);
      await widget.services.coordinator.acceptPlanNames(
        page.cases.map((item) => item.planName),
      );
      if (!current()) return;
      setState(() {
        if (!more) _cases.clear();
        for (final item in summaries) {
          if (!_cases.any((c) => c.caseId == item.caseId)) _cases.add(item);
        }
        _cursor = page.nextAfterCaseId;
        _loaded = true;
      });
      unawaited(_loadOnlineNames(summaries, request));
    } catch (error) {
      if (current()) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (_isCurrent && request == _request) {
        final refresh = _refreshQueued;
        _refreshQueued = false;
        setState(() => _discovering = false);
        if (refresh) unawaited(_load());
      }
    }
  }

  Future<void> _open(
    Future<void> Function() action, {
    bool changesSelection = true,
    String? targetId,
  }) async {
    if (!_isCurrent ||
        _opening ||
        widget.services.coordinator.busy ||
        !_removalsReady ||
        (changesSelection && !_canLeave)) {
      return;
    }
    setState(() => _opening = true);
    try {
      final coordinator = widget.services.coordinator;
      final generation = coordinator.generation;
      final pending = await readPendingPlanRemovals(widget.services);
      if (!_isCurrent ||
          generation != coordinator.generation ||
          coordinator.busy) {
        return;
      }
      setState(() => _removals = pending);
      if (targetId != null && pending.containsKey(targetId)) {
        throw StateError(
          'This plan has a removal to check. Open Plans and choose Check removal.',
        );
      }
      if (changesSelection &&
          await _workspaceKey.currentState?.prepareToLeave() == false) {
        return;
      }
      await action();
      if (!mounted || !_isCurrent || coordinator.busy) return;
      setState(() {
        _managing = false;
        _tab = 0;
      });
    } catch (error) {
      if (mounted && _isCurrent) await showOperationError(context, error);
    } finally {
      if (_isCurrent) {
        setState(() => _opening = false);
        unawaited(_load());
      }
    }
  }

  Future<void> _remove(String id, {int? revision}) async {
    if (!_isCurrent || _opening || _selectionBlocked || !_removalsReady) return;
    if (await _workspaceKey.currentState?.prepareToLeave() == false) return;
    if (!mounted || !_isCurrent) return;
    setState(() => _opening = true);
    try {
      final removed = await showPlanDeletionDialog(
        context: context,
        services: widget.services,
        caseId: id,
        title: _title(id),
        minimumCaseRevision: revision,
      );
      if (!_isCurrent) return;
      if (removed) {
        setState(() {
          _cases.removeWhere((item) => item.caseId == id);
          _local.remove(id);
          _details.remove(id);
          _removals.remove(id);
        });
      }
    } finally {
      if (_isCurrent) {
        await _refreshLocal();
        if (_isCurrent) {
          setState(() => _opening = false);
          unawaited(_load());
        }
      }
    }
  }

  String _title(String id) =>
      widget.services.coordinator.planNameFor(id) ??
      (_details[id] == null
          ? null
          : homePlanTitle(_details[id]!.draft, context: context)) ??
      homePlanTitle(null, context: context);

  Future<void> _loadOnlineNames(List<CaseSummary> cases, int request) async {
    for (final item in cases) {
      if (!_isCurrent || request != _request) return;
      try {
        await widget.services.coordinator.loadPlanName(item.caseId);
        if (widget.services.coordinator.nameSync?.pendingFor(item.caseId) ==
            true) {
          await widget.services.coordinator.syncPlanName(item.caseId);
        }
      } catch (_) {
        // ignore: empty_catches
      }
    }
  }

  Future<void> _create() async {
    if (!_canChoose) return;
    final generation = widget.services.coordinator.generation;
    setState(() => _opening = true);
    final name = await showPlanNameDialog(
      context: context,
      creating: true,
      defaultName: homePlanTitle(null, context: context),
    );
    if (!_isCurrent) return;
    setState(() => _opening = false);
    if (name == null || generation != widget.services.coordinator.generation) {
      return;
    }
    await _open(() async {
      final c = widget.services.coordinator;
      await c.createDraft(name: name);
      try {
        await c.save();
      } catch (_) {
        if (!c.isCurrent) rethrow;
      }
    });
  }

  Future<void> _rename(String id) async {
    final route = ModalRoute.of(context);
    if (!_canChoose || _removals.containsKey(id) || route?.isCurrent != true) {
      return;
    }
    final c = widget.services.coordinator;
    final generation = c.generation;
    setState(() => _opening = true);
    try {
      await c.loadPlanName(id);
      try {
        await c.syncPlanName(id);
      } catch (_) {
        if (!c.isCurrent) rethrow;
      }
      if (!mounted ||
          !_isCurrent ||
          generation != c.generation ||
          route?.isCurrent != true) {
        return;
      }
      await showPlanNameDialog(
        context: context,
        initialName: c.planNameFor(id),
        coordinator: c,
        caseId: id,
        defaultName:
            (_details[id] == null
                ? null
                : homePlanTitle(_details[id]!.draft, context: context)) ??
            homePlanTitle(null, context: context),
        onSave: (value) async {
          if (!_isCurrent || generation != c.generation) {
            throw StateError(
              'The selected account or plan changed. Reopen the name editor.',
            );
          }
          await c.savePlanName(id, value);
        },
      );
    } catch (error) {
      if (mounted && _isCurrent && route?.isCurrent == true) {
        await showOperationError(context, error);
      }
    } finally {
      if (_isCurrent) setState(() => _opening = false);
    }
  }

  bool get _canChoose =>
      _isCurrent &&
      !_opening &&
      !widget.services.coordinator.busy &&
      _canLeave &&
      _removalsReady;

  bool get _hasPlans =>
      _local.isNotEmpty || _cases.isNotEmpty || _removals.isNotEmpty;

  Widget _newPlanButton() => _hasPlans
      ? OutlinedButton.icon(
          key: const ValueKey('case-start'),
          onPressed: _canChoose ? _create : null,
          icon: const Icon(Icons.add_rounded),
          label: Text(context.tr('Start a new plan')),
        )
      : FilledButton.icon(
          key: const ValueKey('case-start'),
          onPressed: _canChoose ? _create : null,
          icon: const Icon(Icons.add_rounded),
          label: Text(context.tr('Start a home plan')),
        );

  List<Widget> _status() => [
    if (_selectionBlocked && widget.services.coordinator.draft != null) ...[
      SahNotice(
        title: context.tr('Finish saving your current plan'),
        message: context.tr('Its device save is pending or failed.'),
        tone: SahNoticeTone.warning,
      ),
      OutlinedButton(
        key: const ValueKey('continue-undurable-case'),
        onPressed:
            !_isCurrent ||
                _opening ||
                !_removalsReady ||
                _removals.containsKey(widget.services.coordinator.draft?.caseId)
            ? null
            : () => _open(
                () async {},
                changesSelection: false,
                targetId: widget.services.coordinator.draft?.caseId,
              ),
        child: Text(context.tr('Continue current plan')),
      ),
      const SizedBox(height: 16),
    ],
    if (_opening)
      TickerMode(
        enabled: ModalRoute.of(context)?.isCurrent ?? true,
        child: Padding(
          padding: EdgeInsets.all(20),
          child: LinearProgressIndicator(
            semanticsLabel: context.tr('Updating your plan'),
          ),
        ),
      ),
    if (_removalsFailed) ...[
      SahNotice(
        title: context.tr('Device plans need checking'),
        message: context.tr(
          'We could not check pending removals. Retry before opening a plan.',
        ),
        tone: SahNoticeTone.warning,
      ),
      TextButton(
        onPressed: _refreshLocal,
        child: Text(context.tr('Retry device plans')),
      ),
    ],
  ];

  bool _matches(String id) {
    final query = _query.trim().toLowerCase();
    return query.isEmpty ||
        '${_title(id)} ${_details[id]?.draft.profile.city ?? ''} ${homePlanReference(id, context: context)} $id'
            .toLowerCase()
            .contains(query);
  }

  Widget _plan(
    String id, {
    CaseSummary? online,
    bool pending = false,
  }) => SahActionTile(
    key: ValueKey(
      pending
          ? 'pending-plan-$id'
          : online == null
          ? 'local-case-$id'
          : 'saved-case-$id',
    ),
    title: _title(id),
    subtitle: pending
        ? context.tr('Removal needs checking · {reference}', {
            'reference': homePlanReference(id, context: context),
          })
        : _details[id]?.description(
                onlineRevision: online?.caseRevision,
                context: context,
              ) ??
              '${online == null ? context.tr('Available on this device') : context.tr('Saved online')} · ${homePlanReference(id, context: context)}',
    status: pending || widget.services.coordinator.planNameStatus(id) == null
        ? null
        : context.tr(widget.services.coordinator.planNameStatus(id)!),
    statusIcon: Icons.label_outline,
    icon: pending
        ? Icons.sync_problem_outlined
        : online == null
        ? Icons.phone_iphone_rounded
        : Icons.cloud_done_outlined,
    onTap: !_canChoose
        ? null
        : pending
        ? () => _remove(id, revision: online?.caseRevision)
        : () => _open(
            () => online == null
                ? widget.services.coordinator.restoreLocal(id)
                : widget.services.coordinator.resume(online),
            targetId: id,
          ),
    trailing: PopupMenuButton<String>(
      key: ValueKey('plan-actions-$id'),
      tooltip: context.tr('Actions for {name}, {reference}', {
        'name': _title(id),
        'reference': homePlanReference(id, context: context),
      }),
      enabled: _canChoose,
      onSelected: (action) => action == 'rename'
          ? _rename(id)
          : _remove(id, revision: online?.caseRevision),
      itemBuilder: (_) => [
        if (!pending)
          PopupMenuItem(
            value: 'rename',
            child: Text(context.tr('Rename plan')),
          ),
        PopupMenuItem(
          value: 'delete',
          child: Text(
            pending ? context.tr('Check removal') : context.tr('Delete plan'),
          ),
        ),
      ],
      icon: const Icon(Icons.more_vert),
    ),
  );

  List<Widget> _plans() {
    final local = _local
        .where(
          (id) =>
              !_cases.any((c) => c.caseId == id) &&
              !_removals.containsKey(id) &&
              _matches(id),
        )
        .toList();
    final online = _cases
        .where(
          (item) =>
              !_removals.containsKey(item.caseId) && _matches(item.caseId),
        )
        .toList();
    final pending = _removals.keys.where(_matches).toList();
    return [
      ..._status(),
      TextField(
        key: const ValueKey('plan-search'),
        controller: _searchController,
        decoration: InputDecoration(
          label: Text(context.tr('Search loaded plans')),
          hintText: context.tr('Name, city or reference'),
          prefixIcon: Icon(Icons.search),
        ),
        onChanged: (value) => setState(() => _query = value),
      ),
      const SizedBox(height: 16),
      _newPlanButton(),
      if (_error != null) ...[
        SahNotice(
          message: context.tr(_error!),
          title: context.tr('Saved cases are unavailable'),
          tone: SahNoticeTone.warning,
        ),
        TextButton(
          onPressed: !_isCurrent || _discovering ? null : () => _load(),
          child: Text(context.tr('Retry saved cases')),
        ),
      ],
      if (pending.isNotEmpty) ...[
        SahSectionHeading(title: context.tr('Removals to check')),
        for (final id in pending) _plan(id, pending: true),
      ],
      if (local.isNotEmpty) ...[
        SahSectionHeading(title: context.tr('On this device')),
        for (final id in local) _plan(id),
      ],
      SahSectionHeading(title: context.tr('Saved online')),
      if (_discovering)
        Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: LinearProgressIndicator(
            semanticsLabel: context.tr('Checking saved cases online'),
          ),
        ),
      if (_loaded &&
          !_discovering &&
          _error == null &&
          online.isEmpty &&
          local.isEmpty &&
          pending.isEmpty)
        SahEmptyState(
          title: _query.trim().isEmpty
              ? context.tr('No home plans yet')
              : context.tr('No loaded plans match'),
          message: _query.trim().isEmpty
              ? null
              : context.tr(
                  'Try another city or reference. More saved plans may be available below.',
                ),
          icon: Icons.cottage_outlined,
        ),
      for (final item in online) _plan(item.caseId, online: item),
      if (_cursor != null)
        OutlinedButton(
          onPressed: !_isCurrent || _discovering
              ? null
              : () => _load(more: true),
          child: Text(context.tr('Load more cases')),
        ),
    ];
  }

  Widget _planSelector() {
    final current = widget.services.coordinator.draft?.caseId;
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 22;
    final ids = {..._local, ..._cases.map((item) => item.caseId), ?current};
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Row(
        children: [
          if (!largeText)
            Text(
              'homi',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          if (widget.services.config.permissionSharingEnabled)
            IconButton(
              tooltip: context.tr('Shared with me'),
              icon: const Icon(Icons.people_outline),
              onPressed: !_canLeave
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            SharedWithMeScreen(services: widget.services),
                      ),
                    ),
            ),
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: PopupMenuButton<String>(
                key: const ValueKey('active-plan-selector'),
                tooltip: context.tr('Switch plan'),
                enabled: _canChoose,
                onSelected: (value) {
                  if (value == 'manage') {
                    setState(() => _managing = true);
                    return;
                  }
                  if (value == 'new') {
                    unawaited(_create());
                    return;
                  }
                  if (value == current) return;
                  final online = _cases
                      .where((item) => item.caseId == value)
                      .firstOrNull;
                  unawaited(
                    _open(
                      () => online == null
                          ? widget.services.coordinator.restoreLocal(value)
                          : widget.services.coordinator.resume(online),
                      targetId: value,
                    ),
                  );
                },
                itemBuilder: (_) => [
                  for (final id in ids)
                    PopupMenuItem(
                      value: id,
                      enabled: !_removals.containsKey(id),
                      child: Text(_title(id)),
                    ),
                  PopupMenuItem(
                    value: 'manage',
                    child: Text(context.tr('Manage plans')),
                  ),
                  PopupMenuItem(
                    value: 'new',
                    child: Text(context.tr('Start a new plan')),
                  ),
                ],
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.swap_horiz, size: 22),
                        const SizedBox(width: 8),
                        Flexible(child: Text(context.tr('Switch plan'))),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.services.coordinator;
    final selected = c.draft != null && !_removals.containsKey(c.draft!.caseId);
    final management = Builder(
      builder: (context) => SahContent(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            key: const PageStorageKey('manage-plans'),
            padding: sahFloatingContentPadding(context),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              if (selected)
                TextButton.icon(
                  onPressed: () => setState(() => _managing = false),
                  icon: const Icon(Icons.arrow_back),
                  label: Text(context.tr('Return to plan')),
                ),
              ..._plans(),
            ],
          ),
        ),
      ),
    );
    return PopScope(
      canPop: _tab == 0 && !_managing && _canLeave,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !_canLeave) return;
        if (_managing) {
          setState(() => _managing = false);
          return;
        }
        if (_workspaceKey.currentState?.handleBack() == true) return;
        if (_tab != 0) unawaited(_selectTab(0));
      },
      child: SahFloatingScaffold(
        selectedIndex: _tab,
        onDestinationSelected: _selectTab,
        onAssistant: _assistant,
        body: Builder(
          builder: (context) => Column(
            children: [
              _planSelector(),
              if (widget.services.reminderOpen.value)
                TextButton(
                  onPressed: _openReminder,
                  child: Text(context.tr('Open tasks')),
                ),
              if (_removalsFailed)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: TextButton(
                    onPressed: _refreshLocal,
                    child: Text(context.tr('Retry device plans')),
                  ),
                ),
              Expanded(
                child: selected
                    ? IndexedStack(
                        index: _managing ? 1 : 0,
                        children: [
                          IgnorePointer(
                            ignoring: !_removalsReady || _switching || _opening,
                            child: CaseWorkspaceScreen(
                              key: _workspaceKey,
                              services: widget.services,
                              embedded: true,
                              destination: _tab,
                              onDestinationSelected: _selectTab,
                            ),
                          ),
                          management,
                        ],
                      )
                    : _managing
                    ? management
                    : _tab == 2 && widget.services.config.localHelpEnabled
                    ? const NationwideHelpBrowser(embedded: true)
                    : _tab == 4
                    ? AccountSettingsScreen(
                        key: _settingsKey,
                        services: widget.services,
                        embedded: true,
                      )
                    : SahContent(
                        child: ListView(
                          padding: sahFloatingContentPadding(context),
                          children: [
                            ..._status(),
                            SahEmptyState(
                              title: context.tr(
                                _hasPlans
                                    ? 'Choose a plan to continue'
                                    : 'Start your first home plan',
                              ),
                              icon: Icons.cottage_outlined,
                            ),
                            _newPlanButton(),
                            if (_hasPlans)
                              TextButton(
                                key: const ValueKey('home-open-plans'),
                                onPressed: () =>
                                    setState(() => _managing = true),
                                child: Text(context.tr('Manage plans')),
                              ),
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
