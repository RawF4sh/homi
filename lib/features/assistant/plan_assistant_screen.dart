import 'dart:async';
import 'package:flutter/material.dart';
import '../../l10n/app_language.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/services/case_coordinator.dart';
import 'assistant_context.dart';
import 'assistant_controller.dart';
import 'assistant_model.dart';

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
  AssistantController? _controller;
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
    _controller?.dispose();
    _input.clear();
    _controller = AssistantController(
      model: widget.model,
      locale: locale,
      contextProvider: () => widget.coordinator == null
          ? const AssistantContext(key: 'app-help')
          : assistantContextFor(widget.coordinator!),
    );
    unawaited(_controller!.check());
  }

  void _sourceChanged() {
    if (_controller?.refreshContext() == true) _input.clear();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _sourceChanged();
      unawaited(_controller?.check());
    } else {
      _controller?.clear();
      _input.clear();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.coordinator?.removeListener(_sourceChanged);
    widget.coordinator?.session.removeListener(_sourceChanged);
    _controller?.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final controller = _controller!;
    final question = _input.text;
    if (!controller.canSend || question.trim().isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    await controller.send(question);
    if (!mounted || controller != _controller) return;
    if (controller.errorCode == null &&
        controller.turns.isNotEmpty &&
        controller.turns.last.question == question.trim()) {
      _input.clear();
    }
  }

  void _clear() {
    _controller!.clear();
    _input.clear();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  Widget _shortcuts() => Column(
    children: [
      SahActionTile(
        key: const ValueKey('assistant-next-step'),
        title: context.tr('What should I do next?'),
        icon: Icons.arrow_forward_rounded,
        onTap: () => widget.onSection(0),
      ),
      SahActionTile(
        key: const ValueKey('assistant-rooms'),
        title: context.tr('Where are my scans and concerns?'),
        icon: Icons.view_in_ar,
        onTap: () => widget.onSection(1),
      ),
      SahActionTile(
        key: const ValueKey('assistant-help'),
        title: context.tr('Where can I find assistance?'),
        icon: Icons.support_agent_outlined,
        onTap: () => widget.onSection(2),
      ),
    ],
  );

  String _availabilityText(AssistantAvailability value) => switch (value) {
    AssistantAvailability.ready => 'On-device AI',
    AssistantAvailability.requiresIos26 => 'AI chat needs iOS 26 or later.',
    AssistantAvailability.unsupportedDevice =>
      'This iPhone does not support Apple Intelligence.',
    AssistantAvailability.disabled =>
      'Turn on Apple Intelligence in iPhone Settings, then check again.',
    AssistantAvailability.modelNotReady =>
      'Apple’s on-device model is not ready. Check Apple Intelligence in Settings, then try again.',
    AssistantAvailability.unsupportedLanguage =>
      'Apple’s model does not support the selected app language on this phone. You can keep using the help tools below.',
    AssistantAvailability.unsupportedPlatform =>
      'AI chat is available on compatible iPhones. Android AI is coming later.',
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

  Widget _message(String label, String text, {required bool reply}) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.tr(label),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: reply
                  ? Theme.of(context).colorScheme.surfaceContainerLow
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(text),
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
      builder: (context, _) {
        final available = c.availability == AssistantAvailability.ready;
        return Scaffold(
          appBar: AppBar(
            title: Text(context.tr('Plan assistant')),
            actions: [
              if (MediaQuery.viewInsetsOf(context).bottom > 0)
                IconButton(
                  key: const ValueKey('assistant-hide-keyboard'),
                  tooltip: context.tr('Hide keyboard'),
                  onPressed: () =>
                      FocusManager.instance.primaryFocus?.unfocus(),
                  icon: const Icon(Icons.keyboard_hide_outlined),
                ),
              IconButton(
                tooltip: context.tr('Clear conversation'),
                onPressed: _clear,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          body: SafeArea(
            child: SahContent(
              child: ListView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.all(20),
                children: [
                  if (c.checking) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(context.tr('Checking on-device AI…')),
                  ] else if (!available) ...[
                    SahNotice(
                      message: context.tr(_availabilityText(c.availability)),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: () => c.check(),
                      child: Text(context.tr('Check again')),
                    ),
                    const SizedBox(height: 20),
                    _shortcuts(),
                  ] else if (c.context == null) ...[
                    SahNotice(
                      message: context.tr(
                        'Reopen your plan to start a new conversation.',
                      ),
                    ),
                  ] else ...[
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: SahStatusBadge(
                        label: context.tr('On-device AI'),
                        icon: Icons.auto_awesome_outlined,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      context.tr(
                        'AI can make mistakes. Confirm details in your plan.',
                      ),
                    ),
                    const SizedBox(height: 20),
                    for (final turn in c.turns) ...[
                      _message('You', turn.question, reply: false),
                      _message('AI assistant', turn.answer, reply: true),
                    ],
                    if (c.busy) ...[
                      _message('You', c.pendingQuestion!, reply: false),
                      const LinearProgressIndicator(),
                      const SizedBox(height: 12),
                      Text(context.tr('Thinking on your iPhone…')),
                      TextButton(
                        onPressed: c.stop,
                        child: Text(context.tr('Stop response')),
                      ),
                    ],
                    if (c.errorCode != null) ...[
                      Semantics(
                        liveRegion: true,
                        child: SahNotice(
                          message: context.tr(_errorText(c.errorCode!)),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: c.busy ? null : () => c.check(),
                        child: Text(context.tr('Check again')),
                      ),
                    ],
                    TextField(
                      key: const ValueKey('assistant-input'),
                      controller: _input,
                      enabled: !c.busy,
                      minLines: 2,
                      maxLines: 5,
                      maxLength: 600,
                      textInputAction: TextInputAction.send,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: context.tr('Ask about your next step'),
                        alignLabelWithHint: true,
                      ),
                      onSubmitted: (_) => _send(),
                      onTapOutside: (_) =>
                          FocusManager.instance.primaryFocus?.unfocus(),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      key: const ValueKey('assistant-send'),
                      onPressed: c.canSend ? _send : null,
                      icon: const Icon(Icons.arrow_upward),
                      label: Text(context.tr('Send question')),
                    ),
                    if (c.context!.findings.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          context.tr('Use confirmed findings (up to 4)'),
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
                              'Replies use Apple’s on-device model. Nothing is sent to an AI server. Chat clears when you leave this screen, switch plans, or leave the app. Only the last two exchanges are used for follow-up questions. The assistant cannot change your plan, decide eligibility, or submit an application.',
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
                      children: [_shortcuts()],
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
