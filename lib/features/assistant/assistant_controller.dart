import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../shared/models/case_draft.dart';
import 'assistant_context.dart';
import 'assistant_model.dart';

class AssistantTurn {
  const AssistantTurn(this.question, this.answer);
  final String question, answer;
}

class AssistantController extends ChangeNotifier {
  AssistantController({
    required this.model,
    required this.contextProvider,
    required this.locale,
  }) : context = contextProvider();

  final AssistantModel model;
  final AssistantContext? Function() contextProvider;
  final String locale;
  AssistantContext? context;
  AssistantAvailability availability = AssistantAvailability.unavailable;
  final List<AssistantTurn> _turns = [];
  List<AssistantTurn> get turns => List.unmodifiable(_turns);
  bool checking = true, busy = false, includeFindings = false;
  String? errorCode, pendingQuestion;
  String? _requestId;
  int _epoch = 0, _checkEpoch = 0;
  bool _disposed = false;
  bool get canSend =>
      !_disposed &&
      !checking &&
      !busy &&
      context != null &&
      availability == AssistantAvailability.ready;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> check() async {
    final epoch = ++_checkEpoch;
    checking = true;
    _changed();
    AssistantAvailability result;
    try {
      result = await model.availability(locale);
    } catch (_) {
      result = AssistantAvailability.unavailable;
    }
    if (_disposed || epoch != _checkEpoch) return;
    availability = result;
    checking = false;
    _changed();
  }

  Future<void> downloadModel() async {
    final source = model;
    if (_disposed ||
        busy ||
        checking ||
        availability != AssistantAvailability.modelDownloadable ||
        source is! DownloadableAssistantModel) {
      return;
    }
    final epoch = ++_epoch;
    final id = newUuidV4();
    _requestId = id;
    busy = true;
    errorCode = null;
    _changed();
    try {
      await (source as DownloadableAssistantModel).download(id);
    } catch (error) {
      if (!_disposed && epoch == _epoch) {
        errorCode = error is AssistantFailure ? error.code : 'FAILED';
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        _requestId = null;
        busy = false;
        await check();
      }
    }
  }

  bool refreshContext() {
    final next = contextProvider();
    if (next?.key == context?.key) return false;
    context = next;
    clear();
    return true;
  }

  void useFindings(bool value) {
    if (busy || value == includeFindings) return;
    clear();
    includeFindings = value && context?.findings.isNotEmpty == true;
    _changed();
  }

  void stop() {
    _epoch++;
    final id = _requestId;
    _requestId = null;
    busy = false;
    pendingQuestion = null;
    if (id != null) unawaited(model.cancel(id));
    _changed();
  }

  void clear() {
    stop();
    _turns.clear();
    errorCode = null;
    includeFindings = false;
    _changed();
  }

  Future<void> send(String input) async {
    refreshContext();
    if (!canSend) return;
    final question = input.trim();
    if (question.isEmpty || question.runes.length > 600) {
      errorCode = 'QUESTION_LIMIT';
      _changed();
      return;
    }
    final id = newUuidV4();
    final epoch = ++_epoch;
    final scope = context!.key;
    _requestId = id;
    busy = true;
    errorCode = null;
    pendingQuestion = question;
    final recent = _turns.skip(_turns.length > 2 ? _turns.length - 2 : 0);
    final history = jsonEncode([
      for (final turn in recent)
        {
          'question': assistantExcerpt(turn.question, 160),
          'answer': assistantExcerpt(turn.answer, 320),
        },
    ]);
    final findings = includeFindings ? context!.modelFindings : '[]';
    _changed();
    try {
      final answer = await model.respond(
        requestId: id,
        locale: locale,
        question: question,
        history: history,
        findings: findings,
      );
      if (_disposed || epoch != _epoch) return;
      if (contextProvider()?.key != scope) {
        refreshContext();
        return;
      }
      if (answer.trim().isEmpty || answer.runes.length > 2400) {
        throw const AssistantFailure('INVALID_RESPONSE');
      }
      _turns.add(AssistantTurn(question, answer.trim()));
      if (_turns.length > 12) _turns.removeAt(0);
    } catch (error) {
      if (_disposed || epoch != _epoch) return;
      if (contextProvider()?.key != scope) {
        refreshContext();
        return;
      }
      errorCode = error is AssistantFailure ? error.code : 'FAILED';
    } finally {
      if (!_disposed && epoch == _epoch) {
        _requestId = null;
        busy = false;
        pendingQuestion = null;
        _changed();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_checkEpoch;
    stop();
    _turns.clear();
    context = null;
    super.dispose();
  }
}
