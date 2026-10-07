import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../../app/live_app.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/models/contracts.dart';
import '../../shared/models/annotated_export.dart';
import '../../shared/models/evidence_annotations.dart';
import '../../shared/presentation/sah_components.dart';
import 'reviewed_photo_screen.dart';
import 'private_draft_preview.dart';
import '../../shared/models/evidence.dart';
import '../../shared/models/form_answers.dart';
import '../../shared/services/matching_api_client.dart';

class PrivateExportScreen extends StatefulWidget {
  const PrivateExportScreen({
    super.key,
    required this.services,
    required this.program,
  });
  final AppServices services;
  final ProgramMatch program;
  @override
  State<PrivateExportScreen> createState() => _PrivateExportScreenState();
}

class _PrivateExportScreenState extends State<PrivateExportScreen>
    with WidgetsBindingObserver {
  EvidenceCatalog? _catalog;
  FormAnswersResponse? _answers;
  final _selected = <String, AnnotationState>{};
  AnnotatedExportArtifact? _artifact;
  Uint8List? _pdf;
  bool _busy = false, _sharing = false;
  String? _error;
  String? _notice;
  Timer? _timer;
  late final String _caseId;
  late final int _caseGeneration;
  @override
  void initState() {
    super.initState();
    final coordinator = widget.services.coordinator;
    _caseId = coordinator.currentCase().caseId;
    _caseGeneration = coordinator.generation;
    WidgetsBinding.instance.addObserver(this);
    widget.services.coordinator.addListener(_invalidate);
    _load();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _invalidate());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _invalidate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.services.coordinator.removeListener(_invalidate);
    _timer?.cancel();
    _pdf = null;
    super.dispose();
  }

  bool get _scopeCurrent {
    final c = widget.services.coordinator;
    return mounted &&
        c.isCurrent &&
        c.generation == _caseGeneration &&
        c.snapshot?.caseId == _caseId;
  }

  CaseSnapshot _currentCase() {
    if (!_scopeCurrent) {
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
    return widget.services.coordinator.currentCase();
  }

  bool get _current =>
      _scopeCurrent &&
      _catalog != null &&
      widget.services.coordinator.snapshot != null &&
      _catalog!.belongsTo(widget.services.coordinator.currentCase());
  void _invalidate() {
    if (!mounted) return;
    if (!_scopeCurrent) {
      if (_catalog != null ||
          _answers != null ||
          _artifact != null ||
          _pdf != null) {
        setState(() {
          _catalog = null;
          _answers = null;
          _selected.clear();
          _artifact = null;
          _pdf = null;
          _notice = null;
          _error =
              'This case was closed or changed. Return to the case and open draft review again.';
        });
      }
      return;
    }
    if (!_current ||
        (_artifact != null &&
            !_artifact!.base.isAvailableAt(DateTime.now().toUtc()))) {
      const staleMessage =
          'The draft expired or its case changed. Reload and prepare a fresh draft.';
      if (_pdf != null ||
          _artifact != null ||
          (_catalog != null && _error != staleMessage)) {
        setState(() {
          _pdf = null;
          _artifact = null;
          _selected.clear();
          _notice = null;
          _error = staleMessage;
        });
      }
    }
  }

  Future<void> _load() async {
    if (_busy || _sharing || !_scopeCurrent) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
      _pdf = null;
      _artifact = null;
      _selected.clear();
      _catalog = null;
      _answers = null;
    });
    try {
      final catalog = await widget.services.exports.listEvidence(
        _currentCase(),
        currentCase: _currentCase,
        currentCatalog: () => _catalog,
      );
      if (!_scopeCurrent) return;
      final answers = await widget.services.answers.readAnswers(
        _currentCase(),
        programId: widget.program.programId,
        currentCase: _currentCase,
        currentProgramId: () => widget.program.programId,
        currentContext: () => _answers?.context,
      );
      if (_scopeCurrent) {
        setState(() {
          _catalog = catalog;
          _answers = answers;
        });
        await _restoreSelection();
      }
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _operationKey => 'export.$_caseId.${widget.program.programId}';
  Map<String, Object?> _request(String generation) {
    if (!_current || _answers == null) {
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
    final snapshot = widget.services.coordinator.currentCase();
    return {
      'schemaVersion': '2',
      'caseId': snapshot.caseId,
      'expectedCaseRevision': snapshot.revision,
      'programId': widget.program.programId,
      'expectedFormContextId': _answers!.context.formContextId,
      'expectedAnswerRevision': _answers!.saved?.answerRevision ?? 0,
      'expectedEvidenceCatalogRevision': _catalog!.catalogRevision,
      'generationKey': generation,
      'selectedEvidence': [
        for (final entry in _selected.entries)
          {
            'evidenceId': entry.key,
            'expectedEvidenceRevision':
                entry.value.annotation['evidenceRevision'],
            'expectedAnnotationRevision': entry.value.annotationRevision,
            'reviewedForExport': true,
          },
      ],
    };
  }

  String _fingerprint() => sha256
      .convert(utf8.encode(jsonEncode(_request('fingerprint'))))
      .toString();
  bool _guard(String fingerprint) =>
      mounted &&
      _current &&
      _answers != null &&
      !widget.services.coordinator.hasUnsavedChanges &&
      _fingerprint() == fingerprint;
  Map<String, Object?> _annotationRequest(EvidenceDescriptor evidence) => {
    'schemaVersion': '2',
    'caseId': evidence.caseId,
    'expectedCaseRevision': widget.services.coordinator.currentCase().revision,
    'expectedCatalogRevision': _catalog!.catalogRevision,
    'evidenceId': evidence.evidenceId,
    'expectedEvidenceRevision': evidence.evidenceRevision,
  };
  Future<void> _restoreSelection() async {
    if (!_current || _answers == null) return;
    final fingerprint = _fingerprint();
    final prior = await widget.services.store.readJson(_operationKey);
    if (!_guard(fingerprint)) return;
    final request = prior?['request'];
    if (request is! Map || !_current || _answers == null) return;
    final current = _request('fingerprint');
    for (final key in [
      'caseId',
      'expectedCaseRevision',
      'programId',
      'expectedFormContextId',
      'expectedAnswerRevision',
      'expectedEvidenceCatalogRevision',
    ]) {
      if (request[key] != current[key]) return;
    }
    final selected = request['selectedEvidence'];
    if (selected is! List || selected.length > maxSelectedEvidence) return;
    final recovered = <String, AnnotationState>{};
    for (final raw in selected) {
      if (raw is! Map) return;
      final candidates = _catalog!.evidence.where(
        (item) =>
            item.evidenceId == raw['evidenceId'] &&
            item.evidenceRevision == raw['expectedEvidenceRevision'],
      );
      if (candidates.length != 1) return;
      final annotation = await widget.services.annotations.readAnnotations(
        _annotationRequest(candidates.single),
        isCurrent: () => _guard(fingerprint),
      );
      if (annotation.annotationRevision != raw['expectedAnnotationRevision'] ||
          !_reviewCurrent(annotation)) {
        return;
      }
      recovered[candidates.single.evidenceId] = annotation;
    }
    if (_guard(fingerprint)) {
      setState(() {
        _selected.addAll(recovered);
        _notice =
            'Recovered the exact reviewed selection. Prepare or recover this draft to continue.';
      });
    }
  }

  bool _reviewCurrent(AnnotationState value) =>
      value.annotation['reviewState'] == 'reviewed' &&
      value.annotation['reviewedCaseRevision'] ==
          widget.services.coordinator.currentCase().revision;

  Future<void> _review(EvidenceDescriptor evidence) async {
    if (_busy || _sharing || !_current) return;
    if (_selected.containsKey(evidence.evidenceId)) {
      setState(() {
        _selected.remove(evidence.evidenceId);
        _notice = null;
        _artifact = null;
        _pdf = null;
      });
      return;
    }
    if (_selected.length >= maxSelectedEvidence) {
      setState(() => _error = 'Choose at most six reviewed photos.');
      return;
    }
    setState(() => _busy = true);
    try {
      final c = widget.services.coordinator;
      final fingerprint = _fingerprint();
      final annotations = await widget.services.annotations.readAnnotations(
        _annotationRequest(evidence),
        isCurrent: () => _guard(fingerprint),
      );
      final bytes = await widget.services.exports.downloadEvidence(
        _currentCase(),
        catalog: _catalog!,
        evidence: evidence,
        currentCase: _currentCase,
        currentCatalog: () => _catalog!,
      );
      if (!_guard(fingerprint) || !mounted) return;
      final accepted = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => ReviewedPhotoScreen(
            bytes: Uint8List.fromList(bytes),
            width: evidence.width,
            height: evidence.height,
            marks: annotations.marks,
          ),
        ),
      );
      if (accepted == true && _guard(fingerprint)) {
        var reviewed = annotations;
        if (!_reviewCurrent(reviewed)) {
          final journal =
              'annotation-review.${evidence.caseId}.${evidence.evidenceId}';
          final request = annotations.saveRequest(
            marks: annotations.marks,
            reviewedForExport: true,
          );
          await widget.services.store.writeJson(journal, request);
          if (!_guard(fingerprint)) return;
          reviewed = await c.serialize(
            () => widget.services.annotations.saveAnnotations(
              request,
              isCurrent: () => _guard(fingerprint),
            ),
          );
          final catalog = await widget.services.exports.listEvidence(
            _currentCase(),
            currentCase: _currentCase,
            currentCatalog: () => null,
          );
          if (!_guard(fingerprint) ||
              catalog.catalogRevision != reviewed.catalogRevision) {
            throw MatchingApiException.forCode('STALE_RESPONSE');
          }
          _catalog = catalog;
          await widget.services.store.delete(journal);
        }
        if (!mounted || !_current) return;
        setState(() {
          _selected[evidence.evidenceId] = reviewed;
          _notice = null;
          _artifact = null;
          _pdf = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _prepare({bool newAttempt = false}) async {
    if (_busy || _sharing || !_current) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
      _pdf = null;
    });
    try {
      final fingerprint = _fingerprint();
      final prior = await widget.services.store.readJson(_operationKey);
      if (!_guard(fingerprint)) return;
      final generation = !newAttempt && prior?['fingerprint'] == fingerprint
          ? prior!['generation'] as String
          : newUuidV4();
      final request = _request(generation);
      await widget.services.store.writeJson(_operationKey, {
        'fingerprint': fingerprint,
        'generation': generation,
        'request': request,
      });
      if (!_guard(fingerprint)) return;
      final artifact = await widget.services.annotatedExports.createDraftExport(
        request,
        isCurrent: () => _guard(fingerprint),
      );
      if (!_guard(fingerprint)) return;
      _artifact = artifact;
      final bytes = await widget.services.annotatedExports.downloadDraftExport(
        artifact,
        isCurrent: () => _guard(fingerprint) && identical(_artifact, artifact),
      );
      if (mounted) setState(() => _pdf = Uint8List.fromList(bytes));
    } catch (error) {
      if (mounted) {
        setState(
          () => _error =
              error is MatchingApiException &&
                  error.code == 'EXPORT_REVIEW_REQUIRED'
              ? 'The draft could not be prepared accurately. Review the text, measurements and images. The current PDF does not support all characters or layouts. Your saved information is kept; preserve the original spelling.'
              : safeOperationMessage(error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share(BuildContext buttonContext) async {
    if (_busy || _sharing) return;
    setState(() => _sharing = true);
    try {
      await _sharePrepared(buttonContext);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _sharePrepared(BuildContext buttonContext) async {
    _invalidate();
    if (_pdf == null || _artifact == null || !_current) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
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
                  header: true,
                  child: Text(
                    ctx.tr('Share an incomplete draft?'),
                    style: Theme.of(ctx).textTheme.headlineSmall,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  ctx.tr(
                    'The selected app or recipient can keep this copy. Sharing does not submit an application or confirm receipt.',
                  ),
                ),
                const SizedBox(height: 24),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(ctx.tr('Cancel')),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(ctx.tr('Open share sheet')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (approved != true || !mounted) return;
    _invalidate();
    if (_pdf == null || _artifact == null) return;
    final sharedArtifact = _artifact;
    final sharedPdf = _pdf;
    File? temporaryShare;
    var shareRequested = false;
    try {
      const channel = MethodChannel('safe_at_home/private_media');
      final root = await channel.invokeMethod<String>('privateRootDirectory');
      if (root == null) throw StateError('Private storage unavailable.');
      final directory = Directory('$root/temporary-shares');
      await directory.create(recursive: true);
      await channel.invokeMethod('preparePrivateDirectory', {
        'path': directory.path,
      });
      final file = File('${directory.path}/draft-${newUuidV4()}.pdf');
      temporaryShare = file;
      if (!_current ||
          !identical(_artifact, sharedArtifact) ||
          sharedArtifact == null ||
          !sharedArtifact.base.isAvailableAt(DateTime.now().toUtc())) {
        return;
      }
      await file.writeAsBytes(sharedPdf!, flush: true);
      await channel.invokeMethod('preparePrivateDirectory', {
        'path': directory.path,
      });
      if (!mounted ||
          !buttonContext.mounted ||
          !_current ||
          !identical(_artifact, sharedArtifact) ||
          !sharedArtifact.base.isAvailableAt(DateTime.now().toUtc())) {
        await file.delete();
        return;
      }
      final box = buttonContext.findRenderObject() as RenderBox?;
      shareRequested = true;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/pdf')],
          title: context.tr('Safe at Home incomplete draft'),
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (error) {
      try {
        if (!shareRequested &&
            temporaryShare != null &&
            await temporaryShare.exists()) {
          await temporaryShare.delete();
        }
      } catch (_) {}
      if (mounted) await showOperationError(context, error);
    } finally {
      if (shareRequested && temporaryShare != null) {
        final file = temporaryShare;
        unawaited(
          Future<void>.delayed(const Duration(minutes: 2), () async {
            try {
              if (await file.exists()) await file.delete();
            } catch (_) {}
            try {
              await const MethodChannel(
                'safe_at_home/private_media',
              ).invokeMethod<void>('clearSharedDraftCopy', {
                'name': file.uri.pathSegments.last,
              });
            } catch (_) {}
          }),
        );
      }
    }
  }

  String _expiryLabel(BuildContext context) {
    final expires = DateTime.parse(_artifact!.base.expiresAt).toLocal();
    final local = MaterialLocalizations.of(context);
    return context.tr('{date} at {time}', {
      'date': local.formatMediumDate(expires),
      'time': local.formatTimeOfDay(TimeOfDay.fromDateTime(expires)),
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.tr('Private draft review'))),
    body: SafeArea(
      child: SahContent(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            SahPageHeader(
              title: context.tr('Review your draft'),
              eyebrow: widget.program.programName,
              description: context.tr(
                'Pick photos, prepare the draft, then check it.',
              ),
            ),
            if (Localizations.localeOf(context).languageCode != 'en')
              SahNotice(
                message: context.tr(
                  'Program information and official forms may remain in English. Your saved answers are not translated.',
                ),
              ),
            SahStatusBadge(
              label: context.tr('Incomplete draft · nothing is submitted'),
              icon: Icons.info_outline_rounded,
              tone: SahNoticeTone.warning,
            ),
            if (_busy)
              LinearProgressIndicator(
                semanticsLabel: context.tr('Preparing your private draft'),
              ),
            if (_error != null)
              SahNotice(
                message: context.tr(_error!),
                tone: SahNoticeTone.error,
              ),
            if (_notice != null) SahNotice(message: context.tr(_notice!)),
            SahSectionHeading(
              title: context.tr('Photo attachments'),
              description: context.tr('Only photos you select are included.'),
            ),
            if (_catalog != null && _catalog!.evidence.isEmpty)
              SahNotice(
                message: context.tr(
                  'No saved photos. You can prepare a draft without them.',
                ),
                icon: Icons.photo_outlined,
              ),
            if (_catalog != null)
              for (final evidence in _catalog!.evidence)
                SahActionTile(
                  title: context.tr('Photo {number}', {
                    'number': _catalog!.evidence.indexOf(evidence) + 1,
                  }),
                  subtitle: _selected.containsKey(evidence.evidenceId)
                      ? context.tr(
                          'Reviewed · Attachment {number}. Tap to leave it out.',
                          {
                            'number':
                                _selected.keys.toList().indexOf(
                                  evidence.evidenceId,
                                ) +
                                1,
                          },
                        )
                      : context.tr(
                          'View the saved photo and review its notes.',
                        ),
                  icon: _selected.containsKey(evidence.evidenceId)
                      ? Icons.check_circle_outline_rounded
                      : Icons.photo_outlined,
                  enabled: !_busy && !_sharing && _current,
                  onTap: () => _review(evidence),
                ),
            if (_selected.length > 1)
              Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  context.tr('Photos appear in the order you select them.'),
                ),
              ),
            OutlinedButton.icon(
              onPressed: _busy || _sharing ? null : _load,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(context.tr('Reload current evidence and answers')),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy || _sharing || !_current || _answers == null
                  ? null
                  : () => _prepare(),
              icon: const Icon(Icons.description_outlined),
              label: Text(context.tr('Prepare or recover this draft')),
            ),
            if (_error != null)
              TextButton(
                onPressed: _busy || _sharing || !_current
                    ? null
                    : () => _prepare(newAttempt: true),
                child: Text(context.tr('Start a newly reviewed draft attempt')),
              ),
            if (_artifact != null) ...[
              SahSectionHeading(title: context.tr('Draft checklist')),
              Text(
                context.tr('Download expires {expiry}.', {
                  'expiry': _expiryLabel(context),
                }),
              ),
              const SizedBox(height: 12),
              SahNotice(
                title: context.tr('Not ready to submit'),
                message: context.tr(
                  '{count} unresolved items are listed below. Review the complete checklist before sharing. Nothing has been submitted.',
                  {'count': _artifact!.base.missingItems.length},
                ),
                tone: SahNoticeTone.warning,
              ),
              for (final warning in _artifact!.base.warnings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(switch (warning) {
                    'INCOMPLETE_DRAFT' => context.tr(
                      'This draft is incomplete.',
                    ),
                    'NOT_SUBMITTED' => context.tr(
                      'No application has been submitted.',
                    ),
                    _ => context.tr(
                      'Program availability or requirements still need confirmation.',
                    ),
                  }),
                ),
            ],
            if (_pdf != null) ...[
              SahSectionHeading(
                title: context.tr('Your PDF'),
                description: context.tr(
                  'Review every page before sharing. Use the page buttons, pinch to zoom, or open the page text.',
                ),
              ),
              Builder(
                builder: (ctx) => FilledButton.icon(
                  onPressed: _busy || _sharing ? null : () => _share(ctx),
                  icon: const Icon(Icons.ios_share),
                  label: Text(
                    _sharing
                        ? context.tr('Opening sharing…')
                        : context.tr('Share or save draft'),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              widget.services.pdfPreviewBuilder?.call(_pdf!) ??
                  PrivateDraftPreview(bytes: _pdf!),
              const SizedBox(height: 24),
            ],
            if (_artifact != null)
              ExpansionTile(
                key: const ValueKey('draft-unresolved-items'),
                tilePadding: EdgeInsets.zero,
                title: Text(context.tr('Unresolved draft items')),
                subtitle: Text(
                  context.tr('{count} items to review', {
                    'count': _artifact!.base.missingItems.length,
                  }),
                ),
                children: [
                  for (final item in _artifact!.base.missingItems)
                    Padding(
                      key: ValueKey('draft-unresolved-${item.id}'),
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(item.description),
                    ),
                ],
              ),
          ],
        ),
      ),
    ),
  );
}
