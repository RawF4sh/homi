import 'dart:async';
import 'package:flutter/material.dart';
import '../../app/live_app.dart';
import '../../shared/models/case_list.dart';
import '../../shared/presentation/sah_components.dart';
import '../settings/account_settings_screen.dart';
import 'case_display_details.dart';
import 'case_workspace_screen.dart';
import 'home_plan_journey.dart';
import 'plan_deletion_action.dart';
import 'plan_deletion_dialog.dart';

class CaseHomeScreen extends StatefulWidget {
  const CaseHomeScreen({super.key, required this.services});
  final AppServices services;
  @override
  State<CaseHomeScreen> createState() => _CaseHomeScreenState();
}

class _CaseHomeScreenState extends State<CaseHomeScreen> {
  final _cases = <CaseSummary>[];
  List<String> _local = [];
  final _details = <String, CaseDisplayDetails>{};
  String? _cursor, _error;
  bool _discovering = false, _opening = false, _loaded = false;
  bool _refreshQueued = false;
  int _request = 0, _localRequest = 0;
  int _tab = 0;
  String _query = '';
  Map<String, PlanRemovalStatus> _removals = {};
  bool _removalsReady = false;
  bool _removalsFailed = false;
  bool get _isCurrent => mounted && widget.services.coordinator.isCurrent;
  bool get _selectionBlocked => widget.services.coordinator.hasUndurableEdits;
  void _caseChanged() {
    if (_isCurrent) setState(_rememberCurrentDetails);
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
    _rememberCurrentDetails();
    widget.services.coordinator.addListener(_caseChanged);
    _load();
  }

  @override
  void dispose() {
    widget.services.coordinator.removeListener(_caseChanged);
    super.dispose();
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
      if (widget.services.coordinator.draft?.caseId == id) continue;
      try {
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
      final page = await widget.services.discovery.listCases(
        afterCaseId: more ? _cursor : null,
        isCurrent: current,
      );
      if (!current()) return;
      setState(() {
        if (!more) _cases.clear();
        for (final item in page.cases) {
          if (!_cases.any((c) => c.caseId == item.caseId)) _cases.add(item);
        }
        _cursor = page.nextAfterCaseId;
        _loaded = true;
      });
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
        (changesSelection && _selectionBlocked)) {
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
      await action();
      if (!mounted || !_isCurrent || coordinator.busy) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CaseWorkspaceScreen(services: widget.services),
        ),
      );
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
    setState(() => _opening = true);
    try {
      final removed = await showPlanDeletionDialog(
        context: context,
        services: widget.services,
        caseId: id,
        title: _details[id]?.title ?? homePlanTitle(null),
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

  bool get _canChoose =>
      _isCurrent &&
      !_opening &&
      !widget.services.coordinator.busy &&
      !_selectionBlocked &&
      _removalsReady;

  Widget _newPlanButton() => FilledButton.icon(
    key: const ValueKey('case-start'),
    onPressed: _canChoose
        ? () => _open(widget.services.coordinator.createDraft)
        : null,
    icon: const Icon(Icons.add_rounded),
    label: const Text('Start a home plan'),
  );

  List<Widget> _status() => [
    if (_selectionBlocked && widget.services.coordinator.draft != null) ...[
      const SahNotice(
        title: 'Finish saving your current plan',
        message: 'Its device save is pending or failed.',
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
        child: const Text('Continue current plan'),
      ),
      const SizedBox(height: 16),
    ],
    if (_opening)
      const Padding(
        padding: EdgeInsets.all(20),
        child: LinearProgressIndicator(semanticsLabel: 'Updating your plan'),
      ),
    if (_removalsFailed) ...[
      const SahNotice(
        title: 'Device plans need checking',
        message:
            'We could not check pending removals. Retry before opening a plan.',
        tone: SahNoticeTone.warning,
      ),
      TextButton(
        onPressed: _refreshLocal,
        child: const Text('Retry device plans'),
      ),
    ],
  ];

  List<Widget> _home() {
    final draft = widget.services.coordinator.draft;
    final pending = draft != null && _removals.containsKey(draft.caseId);
    final hasPlans =
        _local.isNotEmpty || _cases.isNotEmpty || _removals.isNotEmpty;
    return [
      const SahPageHeader(title: 'A safer home, one step at a time'),
      ..._status(),
      SahFeaturePanel(
        title: draft != null ? homePlanTitle(draft) : 'Your home safety plan',
        description: pending
            ? 'Check the removal of this plan before continuing.'
            : draft != null
            ? 'Continue with your saved details, rooms and possible improvements.'
            : 'Tell us what is difficult at home, record the areas that matter, and explore possible support.',
        illustration: const SahHomeIllustration(),
        action: draft != null
            ? FilledButton.icon(
                key: const ValueKey('home-continue-plan'),
                onPressed:
                    !_isCurrent ||
                        _opening ||
                        widget.services.coordinator.busy ||
                        !_removalsReady
                    ? null
                    : pending
                    ? () => _remove(draft.caseId)
                    : () => _open(
                        () async {},
                        changesSelection: false,
                        targetId: widget.services.coordinator.draft?.caseId,
                      ),
                icon: Icon(pending ? Icons.sync_problem : Icons.arrow_forward),
                label: Text(pending ? 'Check removal' : 'Continue this plan'),
              )
            : hasPlans
            ? FilledButton.icon(
                key: const ValueKey('home-open-plans'),
                onPressed: () => setState(() => _tab = 1),
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('Open a saved plan'),
              )
            : _newPlanButton(),
      ),
      if (draft != null || hasPlans) ...[
        const SizedBox(height: 12),
        Align(alignment: Alignment.centerLeft, child: _newPlanButton()),
      ],
      const SahSectionHeading(title: 'How your plan comes together'),
      const HomePlanJourney(),
      const SizedBox(height: 16),
      const SahNotice(
        title: 'Start where you need help',
        message:
            'Bathroom, entrance, stairs, hallways and living spaces, bedroom, kitchen, or outdoor paths. You do not need to check every room. Bathroom 3D scanning is available on supported phones; use photos and notes anywhere.',
      ),
      const SizedBox(height: 16),
      const SahStatusBadge(
        label: 'Private team beta · Fictional information only',
        icon: Icons.lock_outline_rounded,
      ),
    ];
  }

  bool _matches(String id) {
    final query = _query.trim().toLowerCase();
    return query.isEmpty ||
        '${_details[id]?.title ?? homePlanTitle(null)} ${homePlanReference(id)} $id'
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
    title: _details[id]?.title ?? homePlanTitle(null),
    subtitle: pending
        ? 'Removal needs checking · ${homePlanReference(id)}'
        : _details[id]?.description(onlineRevision: online?.caseRevision) ??
              '${online == null ? 'Available on this device' : 'Saved online'} · ${homePlanReference(id)}',
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
      tooltip:
          'Actions for ${_details[id]?.title ?? homePlanTitle(null)}, ${homePlanReference(id)}',
      enabled: _canChoose,
      onSelected: (_) => _remove(id, revision: online?.caseRevision),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'delete',
          child: Text(pending ? 'Check removal' : 'Delete plan'),
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
      const SahPageHeader(title: 'Your home plans'),
      ..._status(),
      const Text('Open a plan to continue. Use its ⋮ menu to delete it.'),
      const SizedBox(height: 16),
      TextField(
        key: const ValueKey('plan-search'),
        decoration: const InputDecoration(
          labelText: 'Search loaded plans',
          hintText: 'City or reference',
          prefixIcon: Icon(Icons.search),
        ),
        onChanged: (value) => setState(() => _query = value),
      ),
      const SizedBox(height: 16),
      _newPlanButton(),
      if (_error != null) ...[
        SahNotice(
          message: _error!,
          title: 'Saved cases are unavailable',
          tone: SahNoticeTone.warning,
        ),
        TextButton(
          onPressed: !_isCurrent || _discovering ? null : () => _load(),
          child: const Text('Retry saved cases'),
        ),
      ],
      if (pending.isNotEmpty) ...[
        const SahSectionHeading(title: 'Removals to check'),
        for (final id in pending) _plan(id, pending: true),
      ],
      if (local.isNotEmpty) ...[
        const SahSectionHeading(title: 'On this device'),
        for (final id in local) _plan(id),
      ],
      const SahSectionHeading(title: 'Saved online'),
      if (_discovering)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: LinearProgressIndicator(
            semanticsLabel: 'Checking saved cases online',
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
              ? 'No home plans yet'
              : 'No loaded plans match',
          message: _query.trim().isEmpty
              ? 'Start a home plan to record what matters to you.'
              : 'Try another city or reference. More saved plans may be available below.',
          icon: Icons.cottage_outlined,
        ),
      for (final item in online) _plan(item.caseId, online: item),
      if (_cursor != null)
        OutlinedButton(
          onPressed: !_isCurrent || _discovering
              ? null
              : () => _load(more: true),
          child: const Text('Load more cases'),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: _tab == 2
        ? null
        : AppBar(
            title: Row(
              children: [
                const SahBrandMark(size: 32),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Safe at Home',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
          ),
    body: _tab == 2
        ? AccountSettingsScreen(services: widget.services)
        : SafeArea(
            child: SahContent(
              child: RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  key: ValueKey('root-tab-$_tab'),
                  padding: const EdgeInsets.all(20),
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: _tab == 0 ? _home() : _plans(),
                ),
              ),
            ),
          ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _tab,
      onDestinationSelected: (index) {
        if (index == _tab || _opening || !_isCurrent) return;
        FocusManager.instance.primaryFocus?.unfocus();
        setState(() {
          _tab = index;
          _query = '';
        });
        if (index != 2) unawaited(_refreshLocal());
      },
      destinations: const [
        NavigationDestination(
          key: ValueKey('nav-home'),
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: 'Home',
        ),
        NavigationDestination(
          key: ValueKey('nav-plans'),
          icon: Icon(Icons.folder_outlined),
          selectedIcon: Icon(Icons.folder),
          label: 'Plans',
        ),
        NavigationDestination(
          key: ValueKey('nav-settings'),
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: 'Settings',
        ),
      ],
    ),
  );
}
