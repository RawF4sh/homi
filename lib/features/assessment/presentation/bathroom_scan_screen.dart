import 'dart:async';
import 'package:flutter/material.dart';

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
  });
  final BathroomScanSession session;
  final Future<String> Function(ScanSuggestion) onImport;
  final String? Function(String) importedFinding;

  final Set<String> Function()? activeImports;
  final Listenable? scope;
  @override
  State<BathroomScanScreen> createState() => _BathroomScanScreenState();
}

class _BathroomScanScreenState extends State<BathroomScanScreen> {
  BathroomScanSession get scan => widget.session;
  late final Future<void> ready;
  bool busy = false, canPop = false;
  bool confirming = false;
  BuildContext? dialogContext;
  String? selectedId, notice;
  bool get enabled => !busy && !scan.busy && scan.isCurrent();

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
                              child: const Text('Cancel'),
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

  Future<void> close() async {
    if (busy || scan.busy) return;
    if (scan.initialized && scan.dirty && scan.isCurrent()) {
      if (!await confirm(
        'Device changes are not saved',
        'Retry saving to keep this model and review. Discarding returns to the last saved device version.',
        'Discard unsaved changes',
      )) {
        return;
      }
      try {
        await scan.discardUnsaved();
      } catch (_) {
        return;
      }
    }
    if (!mounted) return;
    setState(() => canPop = true);
    Navigator.of(context).pop();
  }

  Future<void> capture() => run(() async {
    if (scan.review.scene != null &&
        !await confirm(
          'Replace the device model?',
          'Your current model and feature reviews stay until a new scan finishes. Observations already added to the assessment remain there.',
          'Start new scan',
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
        title: const Text('Bathroom in 3D'),
        leading: BackButton(onPressed: close),
      ),
      body: SafeArea(
        child: FutureBuilder<void>(
          future: ready,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _body([
                const Text(
                  'The private model could not be opened. The original encrypted record has been kept.',
                ),
                OutlinedButton(
                  onPressed: close,
                  child: const Text('Back to assessment'),
                ),
              ]);
            }
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(
                child: CircularProgressIndicator(
                  semanticsLabel: 'Opening private bathroom scan',
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
        const Text(
          'This case or account has changed. Return to the assessment.',
        ),
        OutlinedButton(
          onPressed: close,
          child: const Text('Back to assessment'),
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
            ? 'Scan your bathroom'
            : 'Make the bathroom easier to use',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      Text(
        scene == null
            ? 'Scan the layout, tell us what feels difficult, then choose the improvements to explore.'
            : 'Start with what the resident needs help doing. You only confirm the concerns you want to add—not every object or dimension.',
      ),
      if (!scan.isCurrent())
        const Text(
          'This case or account has changed. Return to the assessment.',
        ),
      if (notice != null) _notice(notice!),
      if (scan.notice != null) _notice(scan.notice!),
      if (earlier.isNotEmpty)
        _notice(
          earlier.length == 1
              ? '1 earlier scan observation is still in the assessment, '
                    'unchanged. Review it there.'
              : '${earlier.length} earlier scan observations are still in the '
                    'assessment, unchanged. Review them there.',
        ),
      if (scan.dirty)
        FilledButton(
          onPressed: enabled ? () => run(scan.retrySave) : null,
          child: const Text('Retry device save'),
        ),
      if (scan.busy || busy)
        const LinearProgressIndicator(semanticsLabel: 'Processing scan step'),
      if (!scan.busy && !busy)
        Semantics(liveRegion: true, child: Text(_readiness(capability))),
      if (scene != null && !scanSupported)
        const Text(
          'Your saved model is still available to review. You can also continue with photos and measurements.',
        ),
      if (scene == null)
        _card([
          Text(
            'Before you scan',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const Text('Lights on, clear path, move slowly. Up to 3 minutes.'),
          const Text(
            'Stop if moving feels unsafe. Someone else can scan for you.',
          ),
          SahMoreInfo(
            details: [
              'Include the entry, floor, bath, toilet and sink from several angles. Stay on dry, stable ground.',
              'Mirrors, glass, small fittings and hidden areas may be missed.',
              capability?.source == 'arcore'
                  ? 'Android uses ARCore surfaces and available depth samples. You identify what a surface represents; the scanner does not recognize bathroom fixtures.'
                  : 'iPhone uses RoomPlan on supported LiDAR devices with iOS 16 or later. Other devices keep the photo and manual assessment flow.',
            ],
          ),
        ]),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            key: const ValueKey('bathroom-start-scan'),
            onPressed: canStart ? capture : null,
            icon: const Icon(Icons.view_in_ar),
            label: Text(
              needsSetup
                  ? 'Set up 3D scanning'
                  : scene == null
                  ? 'Scan bathroom'
                  : 'Scan again',
            ),
          ),
          OutlinedButton.icon(
            key: const ValueKey('bathroom-use-manual'),
            onPressed: busy || scan.busy ? null : close,
            icon: const Icon(Icons.photo_camera_outlined),
            label: const Text('Use photos and measurements'),
          ),
          OutlinedButton(
            onPressed: enabled ? () => run(scan.refreshCapabilities) : null,
            child: const Text('Check device'),
          ),
          if (scan.canCancelCapture)
            OutlinedButton(
              onPressed: () => scan.cancelCapture(),
              child: const Text('Cancel scan'),
            ),
        ],
      ),
      if (scene != null) ...[
        Text(
          'What would you like help with?',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const Text(
          'Choose what feels difficult. Leave anything unanswered if you are not sure.',
        ),
        for (final difficulty in ScanDifficulty.values)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(difficulty.label),
            value: scan.review.difficulties.contains(difficulty),
            onChanged: enabled
                ? (value) => run(() => scan.setDifficulty(difficulty, value!))
                : null,
          ),
        Text(
          'Improvements to explore',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const Text(
          'Choose a concern that matches the room. An assessor can help decide whether grab bars, access changes or other support would help.',
        ),
        if (prompts.length >= 20)
          const Text(
            'Showing the first 20 suggestions. This is not a complete assessment; add other concerns with photos or notes.',
          ),
        if (prompts.isEmpty)
          Text(
            scan.review.difficulties.isEmpty
                ? 'Choose a difficulty above to get started. You do not need to check room dimensions.'
                : 'The scan has not identified a matching feature yet. You can label it in the optional model review below, or add this concern with a photo or note in the assessment.',
          ),
        for (final suggestion in prompts) _suggestion(context, suggestion),
        const Text(
          'No suggestions does not mean the room is safe. You can add a concern even when the scanner misses it.',
        ),
        ExpansionTile(
          key: const PageStorageKey('scan-model-details'),
          tilePadding: EdgeInsets.zero,
          title: const Text('Explore or correct the 3D model'),
          subtitle: const Text('Optional · no dimension checks required'),
          children: [
            const Text(
              'This is a rough layout, not a construction plan. Drag to turn it, pinch to zoom, or tap a feature to see its label. Use the list below if tapping is difficult.',
            ),
            const SizedBox(height: 12),
            BathroomModelView(
              key: ValueKey(scene.fingerprint),
              scene: scene,
              selectedId: selected?.id,
              selectedLabel: selected == null
                  ? null
                  : '${scene.elements.indexOf(selected) + 1}. ${(scan.review.labels[selected.id] ?? selected.kind).label}',
              onSelect: (id) => setState(() => selectedId = id),
            ),
            if (scene.warnings.isNotEmpty)
              _notice(scene.warnings.map(_warning).join('\n')),
            if (selected != null) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: ValueKey('scan-selection-${selected.id}'),
                initialValue: selected.id,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Detected feature',
                ),
                items: [
                  for (var i = 0; i < scene.elements.length; i++)
                    DropdownMenuItem(
                      value: scene.elements[i].id,
                      child: Text(
                        '${i + 1}. ${(scan.review.labels[scene.elements[i].id] ?? scene.elements[i].kind).label}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: enabled
                    ? (id) => setState(() => selectedId = id)
                    : null,
              ),
              _feature(context, selected),
            ] else
              const Text(
                'This capture contains point samples only. Add photos or notes for anything the scan missed.',
              ),
            Text(
              '${scene.sourceLabel} · ${scene.elements.length} features · ${scene.points.length} samples',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 16),
          ],
        ),
        OutlinedButton.icon(
          onPressed: enabled
              ? () => run(() async {
                  if (await confirm(
                    'Remove the device model?',
                    'The 3D model and feature reviews will be removed. Any observations already in the assessment remain there.',
                    'Remove model',
                  )) {
                    await scan.clearModel();
                    selectedId = null;
                  }
                })
              : null,
          icon: const Icon(Icons.delete_outline),
          label: const Text('Remove device model'),
        ),
      ],
      const Text('The 3D model stays encrypted on this device.'),
      const SahMoreInfo(
        label: 'Privacy and saving',
        details: [
          'The scanner does not save or upload raw video. Added observations use the assessment’s normal Save to my case step; the 3D model is not included in cloud backups, cross-device resume or draft PDFs.',
          'Use the photo and measurement tools for close-up evidence and verified dimensions.',
        ],
      ),
      OutlinedButton(
        onPressed: busy || scan.busy ? null : close,
        child: const Text('Back to assessment'),
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
        decoration: const InputDecoration(labelText: 'This feature is'),
        items: [
          for (final kind in ScanElementKind.values)
            DropdownMenuItem(value: kind, child: Text(kind.label)),
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
        'Scanner says: ${element.kind.label} (${element.classificationConfidence.name} confidence)',
      ),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('Approximate model dimensions'),
        subtitle: const Text('Optional technical detail'),
        children: [
          Text(
            'About ${dims.x.toStringAsFixed(2)} × ${dims.y.toStringAsFixed(2)} × ${dims.z.toStringAsFixed(2)} m · not a verified measurement',
          ),
          const Text(
            'These bounds draw the 3D model. You do not need to verify toilet size, wall dimensions or ceiling height to ask about support. Only take a specific measurement if it helps assess a concern.',
          ),
          const SahMoreInfo(
            details: [
              'Confidence is about the label, not measurement accuracy.',
              'Sizes are local-axis bounds, not verified height or clear opening. A zero axis means a flat surface with unknown thickness.',
            ],
          ),
        ],
      ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: reviewed,
        title: const Text('I checked this feature’s identity'),
        subtitle: const Text('Optional. This does not verify its dimensions.'),
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
      Text(suggestion.title, style: Theme.of(context).textTheme.titleMedium),
      if (added && busy)
        const Text('Saving this concern on your device…')
      else if (added)
        Text(
          active
              ? 'Previously added. Review its current status in the assessment.'
              : 'Previously added, then dismissed or removed in the assessment. It will not be added again from here; change it in the assessment if it still applies.',
        )
      else if (dismissed)
        const Text('Dismissed for this review.')
      else ...[
        Text(suggestion.nextAction),
        SahMoreInfo(
          label: 'Why this is suggested',
          details: [
            'Based on the resident’s answers and proposed scan features. Confirm that these describe the room before adding the concern.',
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Observation to add'),
          children: [Text(suggestion.detail), const SizedBox(height: 12)],
        ),
        FilledButton(
          onPressed: enabled && !scan.dirty
              ? () => run(() async {
                  if (!await confirm(
                    'Confirm this observation?',
                    '${suggestion.detail}\n\nConfirm that this describes the resident and the named feature in the room. This adds one concern; it does not verify dimensions or approve an installation.',
                    'Confirm and add',
                  )) {
                    return;
                  }
                  final confirmed = await scan.confirmImprovement(suggestion);
                  await widget.onImport(confirmed);
                  if (mounted) {
                    notice =
                        'Observation saved on this device. Return to the assessment and choose Save to my case when ready.';
                  }
                })
              : null,
          child: const Text('Review and add observation'),
        ),
        TextButton(
          onPressed: enabled
              ? () => run(() => scan.dismiss(suggestion.id))
              : null,
          child: const Text('Dismiss suggestion'),
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
      Semantics(liveRegion: true, child: _card([Text(text)]));
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
