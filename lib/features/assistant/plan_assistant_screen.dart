import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_language.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/services/case_coordinator.dart';
import 'assistant_context.dart';
import 'assistant_context_v2.dart';
import '../../shared/navigation/homi_destination.dart';
import 'assistant_controller.dart';
import 'assistant_model.dart';
import 'assistant_history.dart';
import 'assistant_message_text.dart';

class PlanAssistantScreen extends StatefulWidget {
  const PlanAssistantScreen({
    super.key,
    required this.onSection,
    this.coordinator,
    this.appContextProvider,
    this.onTarget,
    this.model = const OnDeviceAssistantModel(),
  });
  final ValueChanged<int> onSection;
  final CaseCoordinator? coordinator;
  final AssistantModel model;
  final AssistantContextV2? Function()? appContextProvider;
  final ValueChanged<HomiTarget>? onTarget;

  @override
  State<PlanAssistantScreen> createState() => _PlanAssistantScreenState();
}

class _PlanAssistantScreenState extends State<PlanAssistantScreen>
    with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  AssistantController? _controller;
  int _draftEpoch = 0;
  String _conversationStamp = '';
  bool _showLatest = false;
  String? _locale;
  String? _scope;
  String? _inputConversation;
  bool _settingInput = false, _canPop = false;
  _AppHelpTopic? _guidanceTopic;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _input.addListener(_draftChanged);
    widget.coordinator?.addListener(_sourceChanged);
    widget.coordinator?.session.addListener(_sourceChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _configure();
  }

  @override
  void didUpdateWidget(PlanAssistantScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coordinator != widget.coordinator ||
        oldWidget.model != widget.model) {
      oldWidget.coordinator?.removeListener(_sourceChanged);
      oldWidget.coordinator?.session.removeListener(_sourceChanged);
      widget.coordinator?.addListener(_sourceChanged);
      widget.coordinator?.session.addListener(_sourceChanged);
      _locale = null;
      _configure();
    }
  }

  String get _scopeKey {
    final source = widget.coordinator;
    return source == null
        ? 'demo'
        : '${source.session.epoch}:${source.isCurrent}:${source.draft?.caseId ?? 'app-help'}';
  }

  void _setInput(String value) {
    _settingInput = true;
    _input.text = value;
    _settingInput = false;
  }

  void _draftChanged() {
    if (!_settingInput) _controller?.setDraft(_input.text);
  }

  void _configure() {
    final locale = AppLanguage.forLocale(
      AppLocalizations.of(context).locale,
    ).code;
    if (locale == _locale && _scope == _scopeKey) return;
    _locale = locale;
    _scope = _scopeKey;
    _controller?.removeListener(_chatChanged);
    _controller?.dispose();
    _draftEpoch++;
    _setInput('');
    _inputConversation = null;
    _guidanceTopic = null;
    final source = widget.coordinator;
    final caseId = source?.draft?.caseId;
    final accountEpoch = source?.session.epoch;
    final history = source != null && source.isCurrent
        ? AssistantHistoryStore(
            store: source.store,
            caseId: caseId,
            participantId: 'owner:${source.store.accountId}',
            isCurrent: () =>
                source.isCurrent &&
                source.session.epoch == accountEpoch &&
                source.draft?.caseId == caseId,
          )
        : null;
    _controller = AssistantController(
      historyStore: history,
      model: widget.model,
      locale: locale,
      appContextProvider: widget.appContextProvider,
      contextProvider: _legacyContext,
    );
    _controller!.addListener(_chatChanged);
    unawaited(_controller!.check());
  }

  AssistantContext? _legacyContext() {
    final base = widget.coordinator == null
        ? const AssistantContext(key: 'app-help')
        : !widget.coordinator!.isCurrent
        ? null
        : widget.coordinator!.draft == null
        ? const AssistantContext(key: 'app-help')
        : assistantContextFor(widget.coordinator!);
    final app = widget.appContextProvider?.call();
    if (base == null ||
        (widget.appContextProvider != null && app?.authorized != true)) {
      return null;
    }
    return AssistantContext(
      key: '${base.key}:${app?.key ?? ''}',
      findings: base.findings,
    );
  }

  void _sourceChanged() {
    if (_scope != _scopeKey) {
      _configure();
      return;
    }
    if (_controller?.refreshContext() == true) {
      _draftEpoch++;
      _setInput(_controller?.draft ?? '');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _sourceChanged();
      unawaited(_controller?.check());
    } else {
      _controller?.stop();
      _focus.unfocus();
      unawaited(_controller?.persist());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.coordinator?.removeListener(_sourceChanged);
    widget.coordinator?.session.removeListener(_sourceChanged);
    _controller?.removeListener(_chatChanged);
    _controller?.dispose();
    _input.removeListener(_draftChanged);
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _chatChanged() {
    final c = _controller!;
    if (_inputConversation != c.conversationId && !c.historyLoading) {
      _inputConversation = c.conversationId;
      _setInput(c.draft);
    }
    final stamp =
        '${c.conversationId}:${c.turns.length}:${c.busy}:${c.errorCode}:${c.interruptedQuestion}:${c.turns.lastOrNull?.answer}';
    if (stamp == _conversationStamp) return;
    _conversationStamp = stamp;
    // Availability/history initialization must not scroll a new chat past its
    // current-context actions and app guidance. Only conversation content has
    // a meaningful "latest message" to reveal.
    if (c.turns.isEmpty &&
        c.pendingQuestion == null &&
        c.interruptedQuestion == null &&
        c.errorCode == null) {
      if (_showLatest && mounted) setState(() => _showLatest = false);
      return;
    }
    final nearEnd = !_scroll.hasClients || _scroll.position.extentAfter < 100;
    if (nearEnd) {
      _latest();
    } else if (mounted) {
      setState(() => _showLatest = true);
    }
  }

  void _latest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (_showLatest) setState(() => _showLatest = false);
      if (MediaQuery.disableAnimationsOf(context)) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      } else {
        unawaited(
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          ),
        );
      }
    });
  }

  Future<void> _send([String? suggestion]) async {
    final c = _controller!;
    final question = suggestion ?? _input.text;
    if (!c.canSend || question.trim().isEmpty) return;
    final epoch = _draftEpoch;
    final scope = c.context?.key;
    _input.clear();
    final response = c.send(question);
    _latest();
    await response;
    if (!mounted ||
        c != _controller ||
        epoch != _draftEpoch ||
        scope != c.context?.key) {
      return;
    }
    if (c.errorCode != null && _input.text.isEmpty) _input.text = question;
  }

  void _stop() {
    final question = _controller!.pendingQuestion;
    _controller!.stop();
    if (question != null && _input.text.isEmpty) _input.text = question;
  }

  Future<bool> _saveBeforeLeaving() async {
    final c = _controller!;
    if (c.clearing || c.historyLoading || c.clearFailed) return false;
    c.stop();
    await c.persist();
    return mounted &&
        !c.saveFailed &&
        !c.historyLoadFailed &&
        !c.clearing &&
        !c.historyLoading;
  }

  Future<void> _close() async {
    if (!await _saveBeforeLeaving() || !mounted) return;
    setState(() => _canPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.maybePop(context);
  }

  Future<void> _openSection(int index) async {
    if (!await _saveBeforeLeaving() || !mounted) return;
    widget.onSection(index);
  }

  Future<void> _clearHistory() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: Text(context.tr('Clear chat history?')),
        content: Text(
          context.tr(
            'This removes all saved chats for this plan and your account on this phone. It does not change your plan.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.tr('Cancel')),
          ),
          FilledButton(
            key: const ValueKey('assistant-confirm-clear'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.tr('Clear history')),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    _draftEpoch++;
    _setInput('');
    _focus.unfocus();
    await _controller!.clearHistory();
  }

  Future<void> _history() async {
    final c = _controller!;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * .85,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              context.tr('Previous conversations'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            for (final conversation in c.conversations.reversed)
              ListTile(
                key: ValueKey('assistant-history-${conversation.id}'),
                title: Text(
                  assistantExcerpt(
                    conversation.turns.firstOrNull?.question ??
                        conversation.interruptedQuestion ??
                        conversation.draft,
                    70,
                  ),
                ),
                subtitle: Text(
                  MaterialLocalizations.of(context).formatMediumDate(
                    DateTime.parse(conversation.updatedAt).toLocal(),
                  ),
                ),
                selected: conversation.id == c.conversationId,
                onTap: () async {
                  Navigator.pop(sheetContext);
                  _draftEpoch++;
                  await c.openConversation(conversation.id);
                  if (mounted) _setInput(c.draft);
                },
              ),
            if (c.conversations.isEmpty)
              Text(context.tr('No saved chats yet.')),
            TextButton(
              onPressed: () => Navigator.pop(sheetContext),
              child: Text(context.tr('Close')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _options() async {
    _focus.unfocus();
    final c = _controller!;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => ListenableBuilder(
        listenable: c,
        builder: (_, _) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * .85,
          ),
          child: ListView(
            key: const ValueKey('assistant-options-list'),
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr('Chat options'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: context.tr('Close'),
                    onPressed: () => Navigator.pop(sheetContext),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              ListTile(
                leading: const Icon(Icons.edit_square),
                title: Text(context.tr('New chat')),
                onTap:
                    c.historyLoading ||
                        c.historyLoadFailed ||
                        c.clearing ||
                        c.saveFailed
                    ? null
                    : () async {
                        Navigator.pop(sheetContext);
                        _draftEpoch++;
                        await c.newChat();
                        if (mounted) _setInput(c.draft);
                      },
              ),
              ListTile(
                leading: const Icon(Icons.history),
                title: Text(context.tr('Previous conversations')),
                onTap: c.historyLoading
                    ? null
                    : () {
                        Navigator.pop(sheetContext);
                        _history();
                      },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(context.tr('Clear history')),
                onTap: c.historyLoading || c.clearing
                    ? null
                    : () {
                        Navigator.pop(sheetContext);
                        _clearHistory();
                      },
              ),
              if (c.context?.findings.isNotEmpty == true) ...[
                SwitchListTile.adaptive(
                  title: Text(context.tr('Use confirmed findings (up to 4)')),
                  subtitle: Text(
                    context.tr('Changing this starts a new chat.'),
                  ),
                  value: c.includeFindings,
                  onChanged:
                      c.busy ||
                          c.historyLoading ||
                          c.historyLoadFailed ||
                          c.clearing ||
                          c.saveFailed
                      ? null
                      : c.useFindings,
                ),
                if (c.includeFindings)
                  ExpansionTile(
                    title: Text(context.tr('Included findings')),
                    children: [
                      for (final finding in c.context!.findings)
                        ListTile(title: Text(finding)),
                    ],
                  ),
              ],
              ExpansionTile(
                title: Text(context.tr('Privacy and limits')),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      context.tr(
                        'Generated replies can be wrong. Confirm details in your plan.',
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      context.tr(
                        'Replies use this phone’s on-device model. Saved chats are encrypted on this phone for your account and plan. They are not shared or included in exports. Only two recent exchanges from unchanged plan context are used for follow-up questions. The assistant cannot change your plan, decide eligibility, or submit an application.',
                      ),
                    ),
                  ),
                  if (defaultTargetPlatform == TargetPlatform.android)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        context.tr(
                          'Google ML Kit handles Android model updates and sends device, app, diagnostic and usage metrics to Google. Chat text and replies stay on this phone.',
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      context.tr(
                        'App steps are included automatically. Confirmed finding excerpts are optional and may contain notes you entered. Photos, scans, measurements, resident details, and documents are not included.',
                      ),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  context.tr(
                    'This phone can save 10 chats with 12 replies each. Saved chats stay available until you clear history.',
                  ),
                ),
              ),
              ExpansionTile(
                title: Text(context.tr('Open app sections')),
                children: [
                  _shortcuts(beforeNavigate: () => Navigator.pop(sheetContext)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _shortcuts({VoidCallback? beforeNavigate}) => Column(
    children: [
      SahActionTile(
        key: const ValueKey('assistant-next-step'),
        title: context.tr('What should I do next?'),
        icon: Icons.arrow_forward_rounded,
        onTap: () {
          beforeNavigate?.call();
          _openSection(0);
        },
      ),
      SahActionTile(
        key: const ValueKey('assistant-rooms'),
        title: context.tr('Where are my scans and concerns?'),
        icon: Icons.view_in_ar,
        onTap: () {
          beforeNavigate?.call();
          _openSection(1);
        },
      ),
      SahActionTile(
        key: const ValueKey('assistant-help'),
        title: context.tr('Where can I find assistance?'),
        icon: Icons.support_agent_outlined,
        onTap: () {
          beforeNavigate?.call();
          _openSection(2);
        },
      ),
    ],
  );

  String _availabilityText(AssistantAvailability value) => switch (value) {
    AssistantAvailability.ready => 'On-device chat',
    AssistantAvailability.requiresIos26 => 'Plan chat needs iOS 26 or later.',
    AssistantAvailability.requiresAndroid26 =>
      'Plan chat needs Android 8 or later. The other app tools still work.',
    AssistantAvailability.modelDownloadable =>
      'Download the on-device model to use chat. Wi-Fi is recommended. No chat text is included in the download.',
    AssistantAvailability.modelDownloading =>
      'The on-device model is downloading. Check again when it finishes.',
    AssistantAvailability.unsupportedDevice =>
      defaultTargetPlatform == TargetPlatform.android
          ? 'On-device chat is not supported on this Android phone.'
          : 'This iPhone does not support Apple Intelligence.',
    AssistantAvailability.disabled =>
      'Turn on Apple Intelligence in iPhone Settings, then check again.',
    AssistantAvailability.modelNotReady =>
      defaultTargetPlatform == TargetPlatform.android
          ? 'The on-device model is not ready. Update Android AICore, then check again.'
          : 'Apple’s on-device model is not ready. Check Apple Intelligence in Settings, then try again.',
    AssistantAvailability.unsupportedLanguage =>
      'The on-device model does not support the selected app language. You can keep using the help tools below.',
    AssistantAvailability.unsupportedPlatform =>
      'Plan chat needs a compatible iPhone or Android phone. You can keep using the help tools below.',
    AssistantAvailability.unavailable =>
      'Plan chat is unavailable right now. You can still use the help tools below.',
  };

  String _errorText(String code) => switch (code) {
    'CONVERSATION_LIMIT' =>
      'This chat is full. Start a new chat or clear history to send more questions.',
    'HISTORY_LIMIT' =>
      'Saved chat storage is full. Clear history to start another chat.',
    'REFUSED' =>
      'The model could not answer that request. Try asking about an app step or a confirmed finding.',
    'QUESTION_LIMIT' =>
      'Try a shorter question, or clear the conversation and ask again.',
    'CONTEXT_LIMIT' =>
      'This phone’s model cannot fit the current app context. Start a new chat without included findings, or use App guidance.',
    'INVALID_RESPONSE' =>
      'The model returned a reply the app could not verify. Try again or use App guidance.',
    'INVALID_INPUT' =>
      'The app could not prepare this request. Use App guidance or reopen the assistant.',
    'UNAVAILABLE' =>
      'The on-device model is unavailable. Check availability, or use App guidance.',
    'LANGUAGE' => 'The model cannot answer in that language on this phone.',
    'TIMEOUT' =>
      'The response took too long. Your question is still here to retry.',
    'BUSY' => 'The model is busy. Wait a moment, then try again.',
    'CANCELLED' => 'Response stopped.',
    'CONTEXT_CHANGED' => 'Context changed. Ask again for current information.',
    _ =>
      'The response could not be completed. Check availability and try again.',
  };

  Widget _appGuidance(AssistantController c) {
    final current = widget.appContextProvider?.call();
    final topic = _guidanceTopic;
    final reply = current == null || topic == null
        ? null
        : topic == _AppHelpTopic.prepareDraft
        ? current.draftPreparationReply()
        : current.deterministicReply();
    final enabled = !c.busy && c.context != null;
    return Column(
      key: const ValueKey('assistant-app-guidance'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr('App guidance'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Text(context.tr('These app steps do not use a language model.')),
        const SizedBox(height: 8),
        for (final (item, label) in [
          (_AppHelpTopic.nextStep, 'What should I do next?'),
          (_AppHelpTopic.prepareDraft, 'How do I prepare a draft?'),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OutlinedButton(
              key: ValueKey('assistant-app-help-${item.name}'),
              onPressed: !enabled
                  ? null
                  : () {
                      _focus.unfocus();
                      setState(() => _guidanceTopic = item);
                    },
              child: Text(context.tr(label)),
            ),
          ),
        if (reply != null && current!.authorized)
          _sourceActions(current, reply, guidance: true)
        else if (topic != null && c.context != null && current == null) ...[
          Text(
            context.tr(
              topic == _AppHelpTopic.prepareDraft
                  ? 'Open Help, choose a program, then open Prepare forms. Review the required answers and documents. Saving or sharing a draft does not submit an application.'
                  : 'Open Plan to create or select a plan.',
            ),
          ),
          OutlinedButton.icon(
            onPressed: () =>
                _openSection(topic == _AppHelpTopic.prepareDraft ? 2 : 0),
            icon: const Icon(Icons.open_in_new),
            label: Text(
              context.tr('Open {section}', {
                'section': context.tr(
                  topic == _AppHelpTopic.prepareDraft ? 'Help' : 'Plan',
                ),
              }),
            ),
          ),
        ],
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _responseRecovery(AssistantController c) => Wrap(
    spacing: 8,
    children: [
      TextButton.icon(
        key: const ValueKey('assistant-check-availability'),
        onPressed: c.busy || c.checking ? null : c.check,
        icon: const Icon(Icons.refresh),
        label: Text(context.tr('Check availability')),
      ),
      if (c.interruptedQuestion != null)
        OutlinedButton(
          key: const ValueKey('assistant-retry-question'),
          onPressed: c.canSend ? () => _send(c.interruptedQuestion!) : null,
          child: Text(context.tr('Retry question')),
        ),
    ],
  );

  Widget _savedSources(AssistantTurn turn) {
    final app = widget.appContextProvider?.call();
    if (app == null || app.key != turn.appContextKey) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Text(
          context.tr(
            'This reply uses an earlier app state. Ask again for current sources.',
          ),
        ),
      );
    }
    try {
      final reply = app.decodeReply(turn.appReplyJson!);
      if (reply.text != turn.answer) return const SizedBox.shrink();
      return _sourceActions(app, reply);
    } on FormatException {
      return const SizedBox.shrink();
    }
  }

  Widget _sourceActions(
    AssistantContextV2 app,
    AssistantReply reply, {
    bool guidance = false,
  }) {
    final target = app.resolveOpen(reply);
    String label(HomiDestination d) => switch (d) {
      HomiDestination.plan => 'Plan',
      HomiDestination.rooms => 'Rooms',
      HomiDestination.help => 'Help',
      HomiDestination.tasks => 'Tasks',
      HomiDestination.settings => 'Settings',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (guidance) Text(context.tr(reply.text)),
          if (!guidance && reply.sourceIds.isNotEmpty)
            Text(
              '${context.tr('Sources')}: ${reply.sourceIds.map((id) => app.sources.firstWhere((s) => s.id == id)).map((s) => context.tr(label(s.target.destination))).toSet().join(', ')}',
            ),
          if (target != null && widget.onTarget != null)
            OutlinedButton.icon(
              icon: const Icon(Icons.open_in_new),
              label: Text(
                context.tr('Open {section}', {
                  'section': context.tr(label(target.destination)),
                }),
              ),
              onPressed: () async {
                if (!await _saveBeforeLeaving() || !mounted) return;
                final current = widget.appContextProvider?.call();
                final validated = current?.resolveOpen(reply);
                if (validated != null) widget.onTarget?.call(validated);
              },
            ),
        ],
      ),
    );
  }

  Widget _conversation(AssistantController c) {
    final available = c.availability == AssistantAvailability.ready;
    return ListView(
      key: const ValueKey('assistant-messages'),
      controller: _scroll,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      children: [
        if (c.historyLoading || c.clearing) const LinearProgressIndicator(),
        if (c.conversationFull)
          SahNotice(
            message: context.tr(
              'This chat is full. Start a new chat or clear history to send more questions.',
            ),
          ),
        if (c.historyLoadFailed || c.saveFailed) ...[
          SahNotice(
            tone: SahNoticeTone.error,
            message: context.tr(
              c.historyLoadFailed
                  ? 'Saved chats could not be opened. Retry before starting another chat.'
                  : c.clearFailed
                  ? 'Chat history could not be cleared. Retry to finish removing it from this phone.'
                  : 'Chat could not be saved on this phone. Keep it open and retry.',
            ),
          ),
          TextButton(
            onPressed: c.clearing ? null : c.retryHistory,
            child: Text(context.tr('Retry')),
          ),
        ],
        if (widget.appContextProvider?.call() case final app?) ...[
          Text(
            context.tr('Current app context'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Text(
            context.tr(
              'Uses recorded statuses and available sections on this phone. Notes, photos and documents are excluded.',
            ),
          ),
          const SizedBox(height: 8),
          _sourceActions(app, app.deterministicReply(), guidance: true),
          const SizedBox(height: 16),
        ],
        _appGuidance(c),
        for (var i = 0; i < c.turns.length; i++) ...[
          _ChatMessage(text: c.turns[i].question, reply: false),
          if (c.turns[i].answer.isEmpty)
            Text(
              context.tr(
                'This response was not completed. Send the question again when you are ready.',
              ),
            )
          else
            _ChatMessage(
              text: c.turns[i].answer,
              reply: true,
              announce: i == c.turns.length - 1,
            ),
          if (c.turns[i].appReplyJson != null) _savedSources(c.turns[i]),
        ],

        if (c.interruptedQuestion != null && !c.busy) ...[
          _ChatMessage(text: c.interruptedQuestion!, reply: false),
          Text(
            context.tr(
              'This response was not completed. Send the question again when you are ready.',
            ),
          ),
        ],
        if (c.checking) ...[
          const LinearProgressIndicator(),
          const SizedBox(height: 12),
          Text(context.tr('Checking on-device chat…')),
        ] else if (!available) ...[
          SahNotice(message: context.tr(_availabilityText(c.availability))),
          const SizedBox(height: 12),
          if (c.availability == AssistantAvailability.modelDownloadable)
            FilledButton(
              key: const ValueKey('assistant-download-model'),
              onPressed: c.busy ? null : c.downloadModel,
              child: Text(context.tr('Download on-device model')),
            ),
          if (c.busy) ...[
            const LinearProgressIndicator(),
            TextButton(onPressed: c.stop, child: Text(context.tr('Cancel'))),
          ],
          if (c.errorCode != null)
            SahNotice(message: context.tr(_errorText(c.errorCode!))),
          OutlinedButton(
            key: const ValueKey('assistant-check-availability'),
            onPressed: c.busy ? null : () => c.check(),
            child: Text(context.tr('Check availability')),
          ),
          const SizedBox(height: 20),
          _shortcuts(),
        ] else if (c.context == null)
          SahNotice(
            message: context.tr(
              'Reopen your plan to start a new conversation.',
            ),
          )
        else ...[
          if (c.turns.isEmpty && !c.busy && c.errorCode == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      Icons.chat_bubble_outline_rounded,
                      size: 32,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    context.tr('How can I help?'),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.tr(
                      c.historyStore == null
                          ? 'Chat stays on this phone and isn’t saved.'
                          : 'Chats save privately on this phone. You can reopen or clear them in Chat options.',
                    ),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          if (c.busy) ...[
            _ChatMessage(text: c.pendingQuestion!, reply: false),
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  context.tr('Thinking on your phone…'),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          ],
          if (c.errorCode != null)
            Semantics(
              liveRegion: true,
              child: SahNotice(message: context.tr(_errorText(c.errorCode!))),
            ),
          if (c.errorCode != null) _responseRecovery(c),
        ],
      ],
    );
  }

  Widget _composer(AssistantController c, {required bool compact}) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: Padding(
      padding: EdgeInsets.fromLTRB(12, compact ? 4 : 12, 12, compact ? 4 : 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (c.includeFindings && !compact)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: _options,
                icon: const Icon(Icons.fact_check_outlined, size: 18),
                label: Text(context.tr('Included findings')),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('assistant-input'),
                  controller: _input,
                  focusNode: _focus,
                  readOnly:
                      c.busy ||
                      c.historyLoading ||
                      c.historyLoadFailed ||
                      c.clearing ||
                      c.clearFailed,
                  minLines: 1,
                  maxLines: compact ? 1 : 4,
                  maxLength: 600,
                  textInputAction: TextInputAction.send,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    hintText: context.tr('Message the assistant…'),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide(
                        color: Theme.of(context).colorScheme.primary,
                        width: 1.5,
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                  ),
                  buildCounter:
                      (
                        _, {
                        required currentLength,
                        required isFocused,
                        maxLength,
                      }) => !compact && isFocused && currentLength >= 500
                      ? Text('$currentLength / $maxLength')
                      : null,
                  onEditingComplete: () {},
                  onSubmitted: (_) => _send(),
                  onTapOutside: (_) => _focus.unfocus(),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _input,
                  builder: (_, value, _) => IconButton.filled(
                    key: ValueKey(c.busy ? 'assistant-stop' : 'assistant-send'),
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    tooltip: context.tr(
                      c.busy ? 'Stop response' : 'Send question',
                    ),
                    onPressed: c.busy
                        ? _stop
                        : c.canSend && value.text.trim().isNotEmpty
                        ? () => _send()
                        : null,
                    icon: Icon(
                      c.busy ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = _controller!;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => PopScope(
        canPop: _canPop,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _close();
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(context.tr('Plan assistant')),
            leading: IconButton(
              tooltip: context.tr('Close'),
              onPressed: c.clearing || c.historyLoading ? null : _close,
              icon: const Icon(Icons.close),
            ),
            actions: [
              if (MediaQuery.viewInsetsOf(context).bottom > 0)
                IconButton(
                  key: const ValueKey('assistant-hide-keyboard'),
                  tooltip: context.tr('Hide keyboard'),
                  onPressed: _focus.unfocus,
                  icon: const Icon(Icons.keyboard_hide_outlined),
                ),
              IconButton(
                key: const ValueKey('assistant-options'),
                tooltip: context.tr('Chat options'),
                onPressed: _options,
                icon: const Icon(Icons.more_horiz),
              ),
            ],
          ),
          body: SafeArea(
            child: SahContent(
              maxWidth: 760,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact =
                      constraints.maxHeight < 360 ||
                      MediaQuery.textScalerOf(context).scale(17) > 30;
                  return Column(
                    children: [
                      Expanded(child: _conversation(c)),
                      if (_showLatest && !compact)
                        TextButton.icon(
                          onPressed: _latest,
                          icon: const Icon(Icons.arrow_downward, size: 18),
                          label: Text(context.tr('Latest message')),
                        ),
                      if (!c.checking &&
                          c.availability == AssistantAvailability.ready &&
                          c.context != null)
                        _composer(c, compact: compact),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _AppHelpTopic { nextStep, prepareDraft }

class _ChatMessage extends StatelessWidget {
  const _ChatMessage({
    required this.text,
    required this.reply,
    this.announce = false,
  });
  final String text;
  final bool reply, announce;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Align(
        alignment: reply
            ? AlignmentDirectional.centerStart
            : AlignmentDirectional.centerEnd,
        child: FractionallySizedBox(
          widthFactor: reply ? 1 : .88,
          child: Semantics(
            container: true,
            liveRegion: announce,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr(reply ? 'Plan assistant' : 'You'),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: reply ? 0 : 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: reply ? null : theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: SelectableText.rich(
                    reply ? assistantMessageText(text) : TextSpan(text: text),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: reply
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
