import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';
import '../../app/live_app.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/models/contracts.dart';
import '../../shared/models/annotated_export.dart';
import '../../shared/models/evidence_annotations.dart';
import '../assessment/presentation/saved_photo_with_marks.dart';
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
  bool _busy = false;
  String? _error;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
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

  bool get _current =>
      widget.services.coordinator.isCurrent &&
      _catalog != null &&
      widget.services.coordinator.snapshot != null &&
      _catalog!.belongsTo(widget.services.coordinator.currentCase());
  void _invalidate() {
    if (!mounted) return;
    if (!_current ||
        (_artifact != null &&
            !_artifact!.base.isAvailableAt(DateTime.now().toUtc()))) {
      if (_pdf != null || _artifact != null) {
        setState(() {
          _pdf = null;
          _artifact = null;
          _error =
              'The draft expired or its case changed. Reload and prepare a fresh draft.';
        });
      }
    }
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _pdf = null;
      _artifact = null;
      _selected.clear();
      _catalog = null;
      _answers = null;
    });
    try {
      final c = widget.services.coordinator;
      final catalog = await widget.services.exports.listEvidence(
        c.currentCase(),
        currentCase: c.currentCase,
        currentCatalog: () => _catalog,
      );
      final answers = await widget.services.answers.readAnswers(
        c.currentCase(),
        programId: widget.program.programId,
        currentCase: c.currentCase,
        currentProgramId: () => widget.program.programId,
        currentContext: () => _answers?.context,
      );
      if (mounted) {
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

  String get _operationKey =>
      'export.${widget.services.coordinator.currentCase().caseId}.${widget.program.programId}';
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
    final prior = await widget.services.store.readJson(_operationKey);
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
    final fingerprint = _fingerprint();
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
        _error =
            'Recovered the exact reviewed selection. Prepare or recover this draft to continue.';
      });
    }
  }

  bool _reviewCurrent(AnnotationState value) =>
      value.annotation['reviewState'] == 'reviewed' &&
      value.annotation['reviewedCaseRevision'] ==
          widget.services.coordinator.currentCase().revision;

  Future<void> _review(EvidenceDescriptor evidence) async {
    if (_busy || !_current) return;
    if (_selected.containsKey(evidence.evidenceId)) {
      setState(() {
        _selected.remove(evidence.evidenceId);
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
        c.currentCase(),
        catalog: _catalog!,
        evidence: evidence,
        currentCase: c.currentCase,
        currentCatalog: () => _catalog!,
      );
      if (!_guard(fingerprint) || !mounted) return;
      final accepted = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('Review private photo')),
            body: SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: InteractiveViewer(
                      child: SavedPhotoWithMarks(
                        bytes: Uint8List.fromList(bytes),
                        width: evidence.width,
                        height: evidence.height,
                        marks: annotations.marks,
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Check the saved photo, boxes and labels. Include only information you want in this draft. Marks are observations, not a professional assessment.',
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('Include this reviewed photo'),
                    ),
                  ),
                ],
              ),
            ),
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
          reviewed = await c.serialize(
            () => widget.services.annotations.saveAnnotations(
              request,
              isCurrent: () => _guard(fingerprint),
            ),
          );
          final catalog = await widget.services.exports.listEvidence(
            c.currentCase(),
            currentCase: c.currentCase,
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
    if (_busy || !_current) return;
    setState(() {
      _busy = true;
      _error = null;
      _pdf = null;
    });
    try {
      final fingerprint = _fingerprint();
      final prior = await widget.services.store.readJson(_operationKey);
      final generation = !newAttempt && prior?['fingerprint'] == fingerprint
          ? prior!['generation'] as String
          : newUuidV4();
      final request = _request(generation);
      await widget.services.store.writeJson(_operationKey, {
        'fingerprint': fingerprint,
        'generation': generation,
        'request': request,
      });
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
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share(BuildContext buttonContext) async {
    _invalidate();
    if (_pdf == null || _artifact == null || !_current) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Share an incomplete draft?'),
        content: const Text(
          'The selected app or recipient can keep this copy. Sharing does not submit an application or confirm receipt.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open share sheet'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    _invalidate();
    if (_pdf == null || _artifact == null) return;
    final sharedArtifact = _artifact;
    final sharedPdf = _pdf;
    File? temporaryShare;
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
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/pdf')],
          title: 'Safe at Home incomplete draft',
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
      unawaited(
        Future<void>.delayed(const Duration(minutes: 2), () async {
          try {
            if (await file.exists()) await file.delete();
          } catch (_) {}
        }),
      );
    } catch (error) {
      try {
        if (temporaryShare != null && await temporaryShare.exists()) {
          await temporaryShare.delete();
        }
      } catch (_) {}
      if (mounted) await showOperationError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Private draft review')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(widget.program.programName),
          const SizedBox(height: 8),
          const Text(
            'Incomplete draft · Nothing is submitted. Review the administrative answers and each selected photo.',
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_error!),
            ),
          OutlinedButton(
            onPressed: _busy ? null : _load,
            child: const Text('Reload current evidence and answers'),
          ),
          if (_catalog != null)
            for (final evidence in _catalog!.evidence)
              ListTile(
                title: Text(
                  'Photo ${_catalog!.evidence.indexOf(evidence) + 1}',
                ),
                subtitle: Text(
                  _selected.containsKey(evidence.evidenceId)
                      ? 'Reviewed · Attachment ${_selected.keys.toList().indexOf(evidence.evidenceId) + 1}'
                      : 'Tap to view and review the sanitized photo',
                ),
                trailing: Icon(
                  _selected.containsKey(evidence.evidenceId)
                      ? Icons.check_circle
                      : Icons.photo_outlined,
                ),
                onTap: _busy ? null : () => _review(evidence),
              ),
          if (_selected.length > 1)
            const Text(
              'Photos appear in selection order. Remove and reselect a photo to change its position.',
            ),
          FilledButton(
            onPressed: _busy || !_current || _answers == null
                ? null
                : () => _prepare(),
            child: const Text('Prepare or recover this draft'),
          ),
          if (_error != null)
            TextButton(
              onPressed: _busy || !_current
                  ? null
                  : () => _prepare(newAttempt: true),
              child: const Text('Start a newly reviewed draft attempt'),
            ),
          if (_artifact != null) ...[
            Text(
              'Download expires ${DateTime.parse(_artifact!.base.expiresAt).toLocal()}',
            ),
            for (final item in _artifact!.base.missingItems)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(item.description),
              ),
            for (final warning in _artifact!.base.warnings)
              Text(switch (warning) {
                'INCOMPLETE_DRAFT' => 'This draft is incomplete.',
                'NOT_SUBMITTED' => 'No application has been submitted.',
                _ =>
                  'Program availability or requirements still need confirmation.',
              }),
          ],
          if (_pdf != null) ...[
            SizedBox(
              height: 560,
              child:
                  widget.services.pdfPreviewBuilder?.call(_pdf!) ??
                  PdfViewer.data(
                    _pdf!,
                    sourceName: 'private-draft',
                    params: PdfViewerParams(
                      linkHandlerParams: PdfLinkHandlerParams(
                        onLinkTap: (_) {},
                      ),
                      textSelectionParams: PdfTextSelectionParams(
                        enabled: false,
                      ),
                    ),
                  ),
            ),
            Builder(
              builder: (ctx) => FilledButton.icon(
                onPressed: _busy ? null : () => _share(ctx),
                icon: const Icon(Icons.ios_share),
                label: const Text('Share or save draft'),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
