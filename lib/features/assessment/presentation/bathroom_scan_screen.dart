import 'dart:async';
import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../../../shared/presentation/sah_components.dart';

import '../application/bathroom_scan_adapter.dart';
import '../application/bathroom_scan_session.dart';
import '../domain/scan/bathroom_scan_scene.dart';
import '../domain/scan/scan_suggestions.dart';
import 'bathroom_model_view.dart';

class BathroomScanScreen extends StatefulWidget {
  const BathroomScanScreen({
    super.key,
    required this.session,
    required this.onImport,
    required this.importedFinding,
    this.activeImports,
    this.scope,
    this.onContinue,
    this.onAddOtherConcern,
    this.onUsePhotos,
  });
  final BathroomScanSession session;
  final Future<String> Function(ScanSuggestion) onImport;
  final String? Function(String) importedFinding;

  final Set<String> Function()? activeImports;
  final Listenable? scope;
  final ValueChanged<String?>? onContinue;
  final VoidCallback? onAddOtherConcern;
  final VoidCallback? onUsePhotos;
  @override
  State<BathroomScanScreen> createState() => _BathroomScanScreenState();
}

class _BathroomScanScreenState extends State<BathroomScanScreen> {
  BathroomScanSession get scan => widget.session;
  late final Future<void> ready;
  bool busy = false, canPop = false;
  bool confirming = false;
  BuildContext? dialogContext;
  String? selectedId, notice, latestImportedFindingId;
  bool get enabled => !busy && !scan.busy && scan.isCurrent();
  String? get currentReviewFindingId {
    final active = widget.activeImports?.call();
    final current = suggestions
        .where((item) => active == null || active.contains(item.id))
        .map((item) => widget.importedFinding(item.id))
        .whereType<String>()
        .toList();
    return current.contains(latestImportedFindingId)
        ? latestImportedFindingId
        : current.firstOrNull;
  }

  @override
  void initState() {
    super.initState();
    scan.addListener(changed);
    widget.scope?.addListener(scopeChanged);
    ready = scan.initialize();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  void scopeChanged() {
    if (!scan.isCurrent()) {
      unawaited(scan.cancelCapture().catchError((Object _) {}));
      final dialog = dialogContext;
      if (dialog != null && dialog.mounted) {
        dialogContext = null;
        final navigator = Navigator.of(dialog);
        final route = ModalRoute.of(dialog);
        if (route?.isCurrent == true) {
          navigator.pop(false);
        } else if (route?.isActive == true) {
          navigator.removeRoute(route!, false);
        }
      }
    }
    changed();
  }

  @override
  void dispose() {
    scan.removeListener(changed);
    widget.scope?.removeListener(scopeChanged);
    scan.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    if (!enabled) return;
    setState(() {
      busy = true;
      notice = null;
    });
    try {
      await action();
    } on ScanScopeExpired {
      if (mounted) {
        notice =
            'This case or session has changed. Return to the case to continue.';
      }
    } catch (_) {
      if (mounted) {
        notice = scan.dirty
            ? null
            : 'This step could not finish. Review the saved state before trying again.';
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> confirm(String title, String message, String action) async {
    if (confirming || !mounted || !scan.isCurrent()) return false;
    confirming = true;
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) {
          dialogContext = context;
          return ListenableBuilder(
            listenable: widget.scope ?? scan,
            builder: (context, _) => !scan.isCurrent()
                ? const SizedBox.shrink()
                : Dialog(
                    insetPadding: const EdgeInsets.all(16),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Semantics(
                              namesRoute: true,
                              header: true,
                              child: Text(
                                title,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(message),
                            const SizedBox(height: 20),
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: Text(context.tr('Cancel')),
                            ),
                            const SizedBox(height: 8),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: Text(action),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
          );
        },
      );
      return mounted && scan.isCurrent() && accepted == true;
    } finally {
      dialogContext = null;
      confirming = false;
    }
  }

  Future<void> close({
    bool continueToReview = false,
    bool addOther = false,
    bool usePhotos = false,
  }) async {
    if (busy || scan.busy) return;
    final route = ModalRoute.of(context);
    if (scan.initialized && scan.dirty && scan.isCurrent()) {
      if (!await confirm(
        context.tr('Device changes are not saved'),
        context.tr(
          'Retry saving to keep this model and review. Discarding returns to the last saved device version.',
        ),
        context.tr('Discard unsaved changes'),
      )) {
        return;
      }
      try {
        await scan.discardUnsaved();
      } catch (_) {
        return;
      }
    }
    if (!mounted ||
        route?.isCurrent != true ||
        !identical(route, ModalRoute.of(context))) {
      return;
    }
    try {
      if (scan.isCurrent()) {
        if (usePhotos) {
          widget.onUsePhotos?.call();
        } else if (addOther) {
          widget.onAddOtherConcern?.call();
        } else if (continueToReview) {
          widget.onContinue?.call(currentReviewFindingId);
        }
      }
    } catch (_) {
      setState(
        () => notice =
            'This case or session has changed. Return to the case to continue.',
      );
      return;
    }
    setState(() => canPop = true);
    Navigator.of(context).pop();
  }

  Future<void> capture() => run(() async {
    if (scan.review.scene != null &&
        !await confirm(
          context.tr('Replace the device model?'),
          context.tr(
            'Your current model and feature reviews stay until a new scan finishes. Observations already added to the assessment remain there.',
          ),
          context.tr('Start new scan'),
        )) {
      return;
    }
    await scan.capture();
    selectedId = null;
  });

  List<ScanSuggestionCandidate> get suggestions => scan.suggestedImprovements;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: canPop,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) close();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(context.tr('Bathroom in 3D')),
        leading: BackButton(onPressed: close),
      ),
      bottomNavigationBar:
          scan.initialized && scan.review.scene != null && scan.isCurrent()
          ? SafeArea(
              minimum: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: FilledButton(
                key: const ValueKey('bathroom-continue'),
                onPressed: enabled
                    ? () => currentReviewFindingId != null
                          ? close(continueToReview: true)
                          : close(
                              addOther: widget.onAddOtherConcern != null,
                              continueToReview:
                                  widget.onAddOtherConcern == null,
                            )
                    : null,
                child: Text(
                  context.tr(
                    currentReviewFindingId != null ? 'Continue' : 'Add a note',
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : null,
      body: SafeArea(
        child: FutureBuilder<void>(
          future: ready,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _body([
                Text(
                  context.tr(
                    'The private model could not be opened. The original encrypted record has been kept.',
                  ),
                ),
                OutlinedButton(
                  onPressed: close,
                  child: Text(context.tr('Back to assessment')),
                ),
              ]);
            }
            if (snapshot.connectionState != ConnectionState.done) {
              return Center(
                child: CircularProgressIndicator(
                  semanticsLabel: context.tr('Opening private bathroom scan'),
                ),
              );
            }
            return _body(content(context));
          },
        ),
      ),
    ),
  );

  Widget _body(List<Widget> children) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          for (final child in children) ...[child, const SizedBox(height: 16)],
        ],
      ),
    ),
  );

  List<Widget> content(BuildContext context) {
    if (!scan.isCurrent()) {
      return [
        Text(
          context.tr(
            'This case or account has changed. Return to the assessment.',
          ),
        ),
        OutlinedButton(
          onPressed: close,
          child: Text(context.tr('Back to assessment')),
        ),
      ];
    }
    final scene = scan.review.scene;
    final prompts = suggestions;
    final earlier = (widget.activeImports?.call() ?? const <String>{})
        .difference(scan.currentReviewedSuggestionIds);
    final capability = scan.capabilities;
    final selected =
        scene?.elementById(selectedId ?? '') ?? scene?.elements.firstOrNull;
    final scanSupported = capability?.canRequestCapture == true;
    final canStart = enabled && !scan.dirty && scanSupported;
    final needsSetup =
        capability?.source == 'arcore' &&
        {
          'services_missing',
          'services_update_required',
          'permission_denied',
        }.contains(capability?.reason);
    return [
      Text(
        scene == null
            ? context.tr('Scan your bathroom')
            : context.tr('Your 3D bathroom'),
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      Text(
        scene == null
            ? context.tr(
                'Scan the layout, tell us what feels difficult, then choose the improvements to explore.',
              )
            : context.tr(
                'Choose the help you need, then add the concerns that fit.',
              ),
      ),
      if (!scan.isCurrent())
        Text(
          context.tr(
            'This case or account has changed. Return to the assessment.',
          ),
        ),
      if (notice != null) _notice(notice!),
      if (scan.notice != null) _notice(scan.notice!),
      if (earlier.isNotEmpty)
        _notice(
          earlier.length == 1
              ? context.tr(
                  '{count} earlier scan observation is still in the assessment, unchanged. Review it there.',
                  {'count': earlier.length},
                )
              : context.tr(
                  '{count} earlier scan observations are still in the assessment, unchanged. Review them there.',
                  {'count': earlier.length},
                ),
        ),
      if (scan.dirty)
        FilledButton(
          onPressed: enabled ? () => run(scan.retrySave) : null,
          child: Text(context.tr('Retry device save')),
        ),
      if (scan.busy || busy)
        LinearProgressIndicator(
          semanticsLabel: context.tr('Processing scan step'),
        ),
      if (scan.canCancelCapture)
        OutlinedButton(
          onPressed: () => scan.cancelCapture(),
          child: Text(context.tr('Cancel scan')),
        ),
      if (!scan.busy && !busy && (scene == null || !scanSupported))
        Semantics(
          liveRegion: true,
          child: Text(context.tr(_readiness(capability))),
        ),
      if (scene != null && !scanSupported)
        Text(
          context.tr(
            'Your saved model is still available to review. You can also continue with photos and measurements.',
          ),
        ),
      if (scene == null)
        _card([
          Text(
            context.tr('Before you scan'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          Text(
            context.tr('Lights on, clear path, move slowly. Up to 3 minutes.'),
          ),
          Text(
            context.tr(
              'Stop if moving feels unsafe. Someone else can scan for you.',
            ),
          ),
          SahMoreInfo(
            details: [
              context.tr(
                'Include the entry, floor, bath, toilet and sink from several angles. Stay on dry, stable ground.',
              ),
              context.tr(
                'Mirrors, glass, small fittings and hidden areas may be missed.',
              ),
              capability?.source == 'arcore'
                  ? context.tr(
                      'Android uses ARCore surfaces and available depth samples. You identify what a surface represents; the scanner does not recognize bathroom fixtures.',
                    )
                  : context.tr(
                      'iPhone uses RoomPlan on supported LiDAR devices with iOS 16 or later. Other devices keep the photo and manual assessment flow.',
                    ),
            ],
          ),
        ]),
      if (scene == null)
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              key: const ValueKey('bathroom-start-scan'),
              onPressed: canStart ? capture : null,
              icon: const Icon(Icons.view_in_ar),
              label: Text(
                needsSetup
                    ? context.tr('Set up 3D scanning')
                    : scene == null
                    ? context.tr('Scan bathroom')
                    : context.tr('Scan again'),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('bathroom-use-manual'),
              onPressed: busy || scan.busy
                  ? null
                  : () => close(usePhotos: true),
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(context.tr('Use photos and measurements')),
            ),
            TextButton(
              onPressed: enabled ? () => run(scan.refreshCapabilities) : null,
              child: Text(context.tr('Check device')),
            ),
          ],
        ),
      if (scene != null) ...[
        BathroomModelView(
          key: ValueKey(scene.fingerprint),
          scene: scene,
          selectedId: selected?.id,
          selectedLabel: selected == null
              ? null
              : '${scene.elements.indexOf(selected) + 1}. ${context.tr((scan.review.labels[selected.id] ?? selected.kind).label)}',
          onSelect: (id) => setState(() => selectedId = id),
        ),
        Text(
          context.tr('What would you like help with?'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        Text(
          context.tr(
            'Choose what feels difficult. Leave anything unanswered if you are not sure.',
          ),
        ),
        for (final difficulty in ScanDifficulty.values)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(context.tr(difficulty.label)),
            value: scan.review.difficulties.contains(difficulty),
            onChanged: enabled
                ? (value) => run(() => scan.setDifficulty(difficulty, value!))
                : null,
          ),
        if (widget.onAddOtherConcern != null)
          OutlinedButton.icon(
            key: const ValueKey('bathroom-other-concern'),
            onPressed: enabled ? () => close(addOther: true) : null,
            icon: const Icon(Icons.edit_note),
            label: Text(
              context.tr('Something else — add a note'),
              textAlign: TextAlign.center,
            ),
          ),
        Text(
          context.tr('Improvements to explore'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (prompts.length >= 20)
          Text(
            context.tr(
              'Showing the first 20 suggestions. This is not a complete assessment; add other concerns with photos or notes.',
            ),
          ),
        if (prompts.isEmpty)
          Text(
            scan.review.difficulties.isEmpty
                ? context.tr(
                    'Choose a difficulty above to get started. You do not need to check room dimensions.',
                  )
                : context.tr(
                    'The scan has not identified a matching feature yet. You can label it in the optional model review below, or add this concern with a photo or note in the assessment.',
                  ),
          ),
        for (final suggestion in prompts) _suggestion(context, suggestion),
        SahMoreInfo(
          details: [
            context.tr(
              'No suggestions does not mean the room is safe. You can add a concern even when the scanner misses it.',
            ),
          ],
        ),
        ExpansionTile(
          key: const PageStorageKey('scan-model-details'),
          tilePadding: EdgeInsets.zero,
          title: Text(context.tr('Explore or correct the 3D model')),
          subtitle: Text(context.tr('Optional · no dimension checks required')),
          children: [
            Text(
              context.tr(
                'This is a rough layout, not a construction plan. Drag to turn it, pinch to zoom, or tap a feature to see its label. Use the list below if tapping is difficult.',
              ),
            ),
            const SizedBox(height: 12),
            if (scene.warnings.isNotEmpty)
              _notice(
                scene.warnings
                    .map((code) => context.tr(_warning(code)))
                    .join('\n'),
              ),
            if (selected != null) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: ValueKey('scan-selection-${selected.id}'),
                initialValue: selected.id,
                isExpanded: true,
                isDense: false,
                decoration: InputDecoration(
                  labelText: context.tr('Detected feature'),
                ),
                items: [
                  for (var i = 0; i < scene.elements.length; i++)
                    DropdownMenuItem(
                      value: scene.elements[i].id,
                      child: Text(
                        '${i + 1}. ${context.tr((scan.review.labels[scene.elements[i].id] ?? scene.elements[i].kind).label)}',
                      ),
                    ),
                ],
                onChanged: enabled
                    ? (id) => setState(() => selectedId = id)
                    : null,
              ),
              _feature(context, selected),
            ] else
              Text(
                context.tr(
                  'This capture contains point samples only. Add photos or notes for anything the scan missed.',
                ),
              ),
            Text(
              context.tr('{source} · {features} features · {samples} samples', {
                'source': scene.sourceLabel,
                'features': scene.elements.length,
                'samples': scene.points.length,
              }),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 16),
          ],
        ),
        ExpansionTile(
          key: const PageStorageKey('scan-options'),
          tilePadding: EdgeInsets.zero,
          title: Text(context.tr('Scan options')),
          children: [
            if (currentReviewFindingId == null)
              TextButton(
                onPressed: enabled ? close : null,
                child: Text(
                  context.tr('Finish without adding a concern'),
                  textAlign: TextAlign.center,
                ),
              ),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const ValueKey('bathroom-start-scan'),
                onPressed: canStart ? capture : null,
                icon: const Icon(Icons.view_in_ar),
                label: Text(
                  context.tr(needsSetup ? 'Set up 3D scanning' : 'Scan again'),
                ),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const ValueKey('bathroom-use-manual'),
                onPressed: enabled ? () => close(usePhotos: true) : null,
                icon: const Icon(Icons.photo_camera_outlined),
                label: Text(
                  context.tr('Use photos and measurements'),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: enabled ? () => run(scan.refreshCapabilities) : null,
                child: Text(context.tr('Check device')),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: enabled
                    ? () => run(() async {
                        if (await confirm(
                          context.tr('Remove the device model?'),
                          context.tr(
                            'The 3D model and feature reviews will be removed. Any observations already in the assessment remain there.',
                          ),
                          context.tr('Remove model'),
                        )) {
                          await scan.clearModel();
                          selectedId = null;
                        }
                      })
                    : null,
                icon: const Icon(Icons.delete_outline),
                label: Text(context.tr('Remove device model')),
              ),
            ),
          ],
        ),
      ],
      Text(context.tr('The 3D model stays encrypted on this device.')),
      SahMoreInfo(
        label: context.tr('Privacy and saving'),
        details: [
          context.tr(
            'The scanner does not save raw video. Continue from the assessment to save your findings to your account. The 3D model stays on this device; it is not included in cloud backups or PDFs.',
          ),
          context.tr(
            'Use the photo and measurement tools for close-up evidence and verified dimensions.',
          ),
        ],
      ),
    ];
  }

  Widget _feature(BuildContext context, ScanElement element) {
    final label = scan.review.labels[element.id] ?? element.kind;
    final reviewed = scan.review.reviewed.contains(element.id);
    final dims = element.dimensions;
    return _card([
      DropdownButtonFormField<ScanElementKind>(
        key: ValueKey('${element.id}-${label.name}'),
        initialValue: label,
        isExpanded: true,
        isDense: false,
        decoration: InputDecoration(labelText: context.tr('This feature is')),
        items: [
          for (final kind in ScanElementKind.values)
            DropdownMenuItem(value: kind, child: Text(context.tr(kind.label))),
        ],
        onChanged: enabled
            ? (kind) => run(
                () => scan.reviewElement(
                  element.id,
                  confirmed: false,
                  label: kind,
                ),
              )
            : null,
      ),
      Text(
        context.tr('Scanner says: {kind} ({confidence} confidence)', {
          'kind': context.tr(element.kind.label),
          'confidence': context.tr(element.classificationConfidence.name),
        }),
      ),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(context.tr('Approximate model dimensions')),
        subtitle: Text(context.tr('Optional technical detail')),
        children: [
          Text(
            context.tr('About {x} × {y} × {z} m · not a verified measurement', {
              'x': dims.x.toStringAsFixed(2),
              'y': dims.y.toStringAsFixed(2),
              'z': dims.z.toStringAsFixed(2),
            }),
          ),
          Text(
            context.tr(
              'These bounds draw the 3D model. You do not need to verify toilet size, wall dimensions or ceiling height to ask about support. Only take a specific measurement if it helps assess a concern.',
            ),
          ),
          SahMoreInfo(
            details: [
              context.tr(
                'Confidence is about the label, not measurement accuracy.',
              ),
              context.tr(
                'Sizes are local-axis bounds, not verified height or clear opening. A zero axis means a flat surface with unknown thickness.',
              ),
            ],
          ),
        ],
      ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: reviewed,
        title: Text(context.tr('I checked this feature’s identity')),
        subtitle: Text(
          context.tr('Optional. This does not verify its dimensions.'),
        ),
        onChanged: enabled
            ? (value) =>
                  run(() => scan.reviewElement(element.id, confirmed: value!))
            : null,
      ),
    ]);
  }

  Widget _suggestion(BuildContext context, ScanSuggestionCandidate suggestion) {
    final added = widget.importedFinding(suggestion.id) != null;
    final active =
        widget.activeImports?.call().contains(suggestion.id) ?? added;
    final dismissed = scan.review.dismissed.contains(suggestion.id);
    return _card([
      Text(
        context.tr(suggestion.title),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      if (added && busy)
        Text(context.tr('Saving this concern on your device…'))
      else if (added)
        Text(
          active
              ? context.tr(
                  'Previously added. Review its current status in the assessment.',
                )
              : context.tr(
                  'Previously added, then dismissed or removed in the assessment. It will not be added again from here; change it in the assessment if it still applies.',
                ),
        )
      else if (dismissed)
        Text(context.tr('Dismissed for this review.'))
      else ...[
        Text(context.tr(suggestion.nextAction)),
        SahMoreInfo(
          label: context.tr('Why this is suggested'),
          details: [
            context.tr(
              'Based on the resident’s answers and proposed scan features. Confirm that these describe the room before adding the concern.',
            ),
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(context.tr('Observation to add')),
          children: [
            Text(_suggestionDetail(context, suggestion)),
            const SizedBox(height: 12),
          ],
        ),
        FilledButton(
          onPressed: enabled && !scan.dirty
              ? () => run(() async {
                  if (!await confirm(
                    context.tr('Confirm this observation?'),
                    '${_suggestionDetail(context, suggestion)}\n\n${context.tr('Confirm that this describes the resident and the named feature in the room. This adds one concern; it does not verify dimensions or approve an installation.')}',
                    context.tr('Confirm and add'),
                  )) {
                    return;
                  }
                  final confirmed = await scan.confirmImprovement(suggestion);
                  latestImportedFindingId = await widget.onImport(confirmed);
                  if (mounted) {
                    notice =
                        'Added to your assessment. Add another concern or continue.';
                  }
                })
              : null,
          child: Text(context.tr('Review and add observation')),
        ),
        TextButton(
          onPressed: enabled
              ? () => run(() => scan.dismiss(suggestion.id))
              : null,
          child: Text(context.tr('Dismiss suggestion')),
        ),
      ],
    ]);
  }

  Widget _card(List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            children[i],
          ],
        ],
      ),
    ),
  );
  Widget _notice(String text) =>
      Semantics(liveRegion: true, child: _card([Text(context.tr(text))]));
}

String _suggestionDetail(
  BuildContext context,
  ScanSuggestionCandidate candidate,
) {
  const prefix = 'The partial model places a reviewed ';
  const suffix =
      ' across part of a reviewed doorway span. This modeled overlap needs an in-person check and may reflect scan approximation.';
  for (final kind in ScanElementKind.values) {
    if (candidate.detail == '$prefix${kind.label.toLowerCase()}$suffix') {
      return context.tr(
        'The partial model places a reviewed {feature} across part of a reviewed doorway span. This modeled overlap needs an in-person check and may reflect scan approximation.',
        {'feature': context.tr(kind.label)},
      );
    }
  }
  return context.tr(candidate.detail);
}

String _readiness(BathroomScanCapabilities? capability) {
  if (capability == null) {
    return 'Scanner availability could not be confirmed. Check device, or use photos and measurements.';
  }
  return switch (capability.reason) {
    'available' when capability.supported =>
      capability.source == 'roomplan'
          ? 'LiDAR scanning is ready on this iPhone. RoomPlan builds an approximate model for you to review.'
          : 'ARCore scanning is ready on this phone. It maps surfaces; you identify the bathroom features during review.',
    'permission_denied' when capability.source == 'roomplan' =>
      'Camera access is blocked. Review Camera access for Safe at Home in iPhone Settings, then return and choose Check device. Photos and manual measurements remain available.',
    'permission_denied' =>
      'Camera access is needed for 3D scanning. Choose Set up 3D scanning to continue. If access is blocked, allow Camera for Safe at Home in Settings, then check device again.',
    'services_missing' =>
      'This phone supports ARCore. Choose Set up 3D scanning to review the Google Play Services for AR installation prompt.',
    'services_update_required' =>
      'Google Play Services for AR needs an update. Choose Set up 3D scanning to review the update prompt.',
    'simulator' =>
      'The simulator cannot capture LiDAR. Use a supported physical iPhone to scan, or continue with photos and measurements.',
    'checking' =>
      'Device support is still being checked. Try Check device again, or continue with photos and measurements.',
    'unsupported_os' when capability.source == 'roomplan' =>
      'Room scanning requires iOS 16 or later on a supported LiDAR device. Photos and measurements are available here.',
    _ =>
      '3D scanning is unavailable on this phone. Continue with photos and manual measurements.',
  };
}

String _warning(String code) => switch (code) {
  'curved_surfaces_approximated' => 'Curved surfaces are only approximated.',
  'geometry_omitted' => 'Some detected geometry could not be included.',
  'depth_unavailable' =>
    'Depth is unavailable; this model uses tracked surfaces and feature samples.',
  'depth_partial' => 'Depth samples cover only part of the room.',
  'tracking_limited' =>
    'Tracking was limited during part of this scan. Check positions carefully.',
  'count_limit' =>
    'The model reached a capture bound. Some geometry is omitted.',
  _ => 'This capture has limitations; review it carefully.',
};
