import 'dart:async';
import 'package:flutter/material.dart';

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

  List<ScanSuggestion> get suggestions {
    final review = scan.review;
    final scene = review.scene;
    if (scene == null) return const [];
    return suggestBathroomImprovements(
      scene: scene,
      reviewedElementIds: review.reviewed,
      difficulties: review.difficulties,
      identifiedKinds: {
        for (final e in review.labels.entries)
          if (review.reviewed.contains(e.key)) e.key: e.value,
      },
    );
  }

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
        .difference({for (final s in prompts) s.id});
    final capability = scan.capabilities;
    final selected =
        scene?.elementById(selectedId ?? '') ?? scene?.elements.firstOrNull;
    final canStart =
        enabled &&
        !scan.dirty &&
        capability != null &&
        (capability.supported ||
            {
              'services_missing',
              'services_update_required',
              'permission_denied',
            }.contains(capability.reason));
    return [
      Text(
        scene == null
            ? 'Understand your bathroom.'
            : 'Review what was captured.',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      Text(
        scene == null
            ? 'Walk slowly around one bathroom to build a partial model. Review its features, tell us what is difficult, and choose which observations to add.'
            : 'This is an approximate model of visible surfaces and objects. Review the identification and position of each feature you want to use.',
      ),
      if (!scan.isCurrent())
        const Text(
          'This case or account has changed. Return to the assessment.',
        ),
      if (notice != null) _notice(notice!),
      if (scan.notice != null) _notice(scan.notice!),
      if (earlier.isNotEmpty)
        _notice(
          'Observations added from an earlier model review: ${earlier.length}. '
          'They are not among this review\'s current suggestions and stay '
          'unchanged in the assessment. Review, correct or remove them there '
          'before saving to your case.',
        ),
      if (scan.dirty)
        FilledButton(
          onPressed: enabled ? () => run(scan.retrySave) : null,
          child: const Text('Retry device save'),
        ),
      if (scan.busy || busy)
        const LinearProgressIndicator(semanticsLabel: 'Processing scan step'),
      if (scene == null)
        _card([
          Text(
            'Before you scan',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const Text(
            'Turn on the lights. Keep a clear path and move slowly. Include the entry, floor, bath, toilet and sink from several angles. Stay on dry, stable ground.',
          ),
          const Text(
            'Only one bathroom, up to 3 minutes. Mirrors, glass, small fittings and hidden areas may be missed. Stop if moving around feels unsafe; someone else can capture for you.',
          ),
          Text(
            capability?.source == 'arcore'
                ? 'Android uses ARCore surfaces and available depth samples. You identify what a surface represents; the scanner does not recognize bathroom fixtures.'
                : 'iPhone uses RoomPlan on supported LiDAR devices with iOS 16 or later. Other devices keep the photo and manual assessment flow.',
          ),
        ]),
      if (capability != null && !canStart && !scan.busy && !busy && !scan.dirty)
        Text(switch (capability.reason) {
          'simulator' =>
            'The simulator cannot capture LiDAR. Use a supported physical iPhone to scan.',
          'checking' =>
            'Device support is still being checked. Try checking again.',
          _ =>
            'Scanning is unavailable here. Photos and manual measurements are still available in the assessment.',
        }),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            key: const ValueKey('bathroom-start-scan'),
            onPressed: canStart ? capture : null,
            icon: const Icon(Icons.view_in_ar),
            label: Text(scene == null ? 'Scan bathroom' : 'Scan again'),
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
          '${scene.sourceLabel} · ${scene.elements.length} features · ${scene.points.length} samples',
          style: Theme.of(context).textTheme.labelLarge,
        ),
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
          Text(
            '1. Review features',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          DropdownButtonFormField<String>(
            key: ValueKey('scan-selection-${selected.id}'),
            initialValue: selected.id,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Detected feature'),
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
            onChanged: enabled ? (id) => setState(() => selectedId = id) : null,
          ),
          _feature(context, selected),
        ] else
          const Text(
            'This capture contains point samples only. Scan again to detect surfaces, or continue with photos and manual observations.',
          ),
        Text(
          '2. What feels difficult?',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const Text(
          'Select only difficulties the resident reports. Unselected items remain unanswered.',
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
          '3. Suggested next steps',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const Text(
          'These are prompts for review, not a safety certification or a benefits decision. No observation is added automatically.',
        ),
        const Text(
          'Up to 20 review prompts are shown. Focus on fewer features to review other parts of the model.',
        ),
        if (prompts.isEmpty)
          const Text(
            'Review a feature and select a reported difficulty to see relevant next steps. No suggestion does not mean the room is safe.',
          ),
        for (final suggestion in prompts) _suggestion(context, suggestion),
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
      _card([
        const Text(
          'Private on this device',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        const Text(
          'The app stores this model and review encrypted on this device. The scanner does not save or upload raw video. Added observations use the assessment’s normal Save to my case step; the 3D model is not included in cloud backups, cross-device resume or draft PDFs.',
        ),
        const Text(
          'Use the existing photo and measurement tools for close-up evidence and verified dimensions.',
        ),
      ]),
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
        'Scanner identification: ${element.kind.label}. Classification confidence: ${element.classificationConfidence.name}. Confidence is not measurement accuracy.',
      ),
      Text(
        'Approximate model extents: ${dims.x.toStringAsFixed(2)} × ${dims.y.toStringAsFixed(2)} × ${dims.z.toStringAsFixed(2)} m. These are local-axis bounds, not verified height or clear opening. A zero axis means a flat surface with unknown thickness.',
      ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: reviewed,
        title: const Text(
          'I reviewed this feature’s identity and position against the room',
        ),
        onChanged: enabled
            ? (value) =>
                  run(() => scan.reviewElement(element.id, confirmed: value!))
            : null,
      ),
    ]);
  }

  Widget _suggestion(BuildContext context, ScanSuggestion suggestion) {
    final added = widget.importedFinding(suggestion.id) != null;
    final active =
        widget.activeImports?.call().contains(suggestion.id) ?? added;
    final dismissed = scan.review.dismissed.contains(suggestion.id);
    return _card([
      Text(suggestion.title, style: Theme.of(context).textTheme.titleMedium),
      if (added)
        Text(
          active
              ? 'Previously added. Review its current status in the assessment.'
              : 'Previously added, then dismissed or removed in the assessment. It will not be added again from here; change it in the assessment if it still applies.',
        )
      else if (dismissed)
        const Text('Dismissed for this review.')
      else ...[
        Text(suggestion.basis),
        Text(suggestion.nextAction),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Observation to add'),
          children: [Text(suggestion.observation), const SizedBox(height: 12)],
        ),
        FilledButton(
          onPressed: enabled && !scan.dirty
              ? () => run(() async {
                  if (!await confirm(
                    'Confirm this observation?',
                    '${suggestion.observation}\n\nConfirm only if this describes the resident and room. It will be saved as a reviewed observation, with no verified measurements.',
                    'Confirm and add',
                  )) {
                    return;
                  }
                  await widget.onImport(suggestion);
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
