import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_language.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/services/case_coordinator.dart';
import 'assistant_context.dart';
import 'assistant_controller.dart';
import 'assistant_model.dart';
import 'assistant_message_text.dart';

class PlanAssistantScreen extends StatefulWidget {
  const PlanAssistantScreen({
    super.key,
    required this.onSection,
    this.coordinator,
    this.model = const OnDeviceAssistantModel(),
  });
  final ValueChanged<int> onSection;
  final CaseCoordinator? coordinator;
  final AssistantModel model;

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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

  void _configure() {
    final locale = AppLanguage.forLocale(
      AppLocalizations.of(context).locale,
    ).code;
    if (locale == _locale) return;
    _locale = locale;
    _controller?.removeListener(_chatChanged);
    _controller?.dispose();
    _draftEpoch++;
    _input.clear();
    _controller = AssistantController(
      model: widget.model,
      locale: locale,
      contextProvider: () => widget.coordinator == null
          ? const AssistantContext(key: 'app-help')
          : assistantContextFor(widget.coordinator!),
    );
    _controller!.addListener(_chatChanged);
    unawaited(_controller!.check());
  }

  void _sourceChanged() {
    if (_controller?.refreshContext() == true) {
      _draftEpoch++;
      _input.clear();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _sourceChanged();
      unawaited(_controller?.check());
    } else {
      _clear();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.coordinator?.removeListener(_sourceChanged);
    widget.coordinator?.session.removeListener(_sourceChanged);
    _controller?.removeListener(_chatChanged);
    _controller?.dispose();
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _chatChanged() {
    final c = _controller!;
    final stamp =
        '${c.turns.length}:${c.busy}:${c.errorCode}:${c.turns.lastOrNull?.answer}';
    if (stamp == _conversationStamp) return;
    _conversationStamp = stamp;
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

  void _clear() {
    _draftEpoch++;
    _controller!.clear();
    _input.clear();
    _focus.unfocus();
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
                title: Text(context.tr('Clear conversation')),
                onTap: () {
                  _clear();
                  Navigator.pop(sheetContext);
                },
              ),
              if (c.context?.findings.isNotEmpty == true) ...[
                SwitchListTile.adaptive(
                  title: Text(context.tr('Use confirmed findings (up to 4)')),
                  subtitle: Text(
                    context.tr('Changing this starts a new chat.'),
                  ),
                  value: c.includeFindings,
                  onChanged: c.busy ? null : c.useFindings,
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
                        'AI can make mistakes. Confirm details in your plan.',
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      context.tr(
                        'Replies use this phone’s on-device model. Chat text and replies are not sent to an AI server. Chat clears when you leave this screen, switch plans, or leave the app. Only the last two exchanges are used for follow-up questions. The assistant cannot change your plan, decide eligibility, or submit an application.',
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
          widget.onSection(0);
        },
      ),
      SahActionTile(
        key: const ValueKey('assistant-rooms'),
        title: context.tr('Where are my scans and concerns?'),
        icon: Icons.view_in_ar,
        onTap: () {
          beforeNavigate?.call();
          widget.onSection(1);
        },
      ),
      SahActionTile(
        key: const ValueKey('assistant-help'),
        title: context.tr('Where can I find assistance?'),
        icon: Icons.support_agent_outlined,
        onTap: () {
          beforeNavigate?.call();
          widget.onSection(2);
        },
      ),
    ],
  );

  String _availabilityText(AssistantAvailability value) => switch (value) {
    AssistantAvailability.ready => 'On-device AI',
    AssistantAvailability.requiresIos26 => 'AI chat needs iOS 26 or later.',
    AssistantAvailability.requiresAndroid26 =>
      'AI chat needs Android 8 or later. The other app tools still work.',
    AssistantAvailability.modelDownloadable =>
      'Download the on-device AI model to use chat. Wi-Fi is recommended. No chat text is included in the download.',
    AssistantAvailability.modelDownloading =>
      'The on-device AI model is downloading. Check again when it finishes.',
    AssistantAvailability.unsupportedDevice =>
      defaultTargetPlatform == TargetPlatform.android
          ? 'On-device AI is not supported on this Android phone.'
          : 'This iPhone does not support Apple Intelligence.',
    AssistantAvailability.disabled =>
      'Turn on Apple Intelligence in iPhone Settings, then check again.',
    AssistantAvailability.modelNotReady =>
      defaultTargetPlatform == TargetPlatform.android
          ? 'The on-device AI model is not ready. Update Android AICore, then check again.'
          : 'Apple’s on-device model is not ready. Check Apple Intelligence in Settings, then try again.',
    AssistantAvailability.unsupportedLanguage =>
      'The on-device model does not support the selected app language. You can keep using the help tools below.',
    AssistantAvailability.unsupportedPlatform =>
      'AI chat needs a compatible iPhone or Android phone. You can keep using the help tools below.',
    AssistantAvailability.unavailable =>
      'On-device AI is unavailable right now. You can still use the help tools below.',
  };

  String _errorText(String code) => switch (code) {
    'REFUSED' =>
      'The model could not answer that request. Try asking about an app step or a confirmed finding.',
    'CONTEXT_LIMIT' || 'QUESTION_LIMIT' =>
      'Try a shorter question, or clear the conversation and ask again.',
    'LANGUAGE' => 'The model cannot answer in that language on this phone.',
    'TIMEOUT' =>
      'The response took too long. Your question is still here to retry.',
    'BUSY' => 'The model is busy. Wait a moment, then try again.',
    'CANCELLED' => 'Response stopped.',
    _ =>
      'The response could not be completed. Check availability and try again.',
  };

  Widget _conversation(AssistantController c) {
    final available = c.availability == AssistantAvailability.ready;
    return ListView(
      key: const ValueKey('assistant-messages'),
      controller: _scroll,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      children: [
        if (c.checking) ...[
          const LinearProgressIndicator(),
          const SizedBox(height: 12),
          Text(context.tr('Checking on-device AI…')),
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
            onPressed: c.busy ? null : () => c.check(),
            child: Text(context.tr('Check again')),
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
                    context.tr('Chat stays on this phone and isn’t saved.'),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 24),
                  for (final prompt in [
                    'What should I do next?',
                    'How do I prepare a draft?',
                  ])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: OutlinedButton(
                        onPressed: c.canSend
                            ? () => _send(context.tr(prompt))
                            : null,
                        child: Text(context.tr(prompt)),
                      ),
                    ),
                ],
              ),
            ),
          for (var i = 0; i < c.turns.length; i++) ...[
            _ChatMessage(text: c.turns[i].question, reply: false),
            _ChatMessage(
              text: c.turns[i].answer,
              reply: true,
              announce: i == c.turns.length - 1,
            ),
          ],
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
                  readOnly: c.busy,
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
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(context.tr('AI assistant')),
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
    );
  }
}

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
                  context.tr(reply ? 'AI assistant' : 'You'),
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
