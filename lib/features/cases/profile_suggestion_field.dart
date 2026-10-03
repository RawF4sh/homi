import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import 'profile_suggestions.dart';

class ProfileSuggestionField extends StatefulWidget {
  const ProfileSuggestionField({
    super.key,
    required this.field,
    required this.controller,
    required this.enabled,
    required this.onSelected,
    required this.child,
  });

  final String field;
  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<ProfileSuggestion> onSelected;
  final Widget child;

  @override
  State<ProfileSuggestionField> createState() => _ProfileSuggestionFieldState();
}

class _ProfileSuggestionFieldState extends State<ProfileSuggestionField> {
  final _groupFocus = FocusNode(canRequestFocus: false);

  @override
  void dispose() {
    _groupFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextFieldTapRegion(
    child: Focus(
      focusNode: _groupFocus,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          widget.child,
          ListenableBuilder(
            listenable: Listenable.merge([widget.controller, _groupFocus]),
            builder: (context, _) {
              final query = widget.controller.text;
              if (!widget.enabled ||
                  !_groupFocus.hasFocus ||
                  query.trim().isEmpty) {
                return const SizedBox.shrink();
              }
              final suggestions = profileSuggestions(widget.field, query);
              if (suggestions.isEmpty) return const SizedBox.shrink();
              final theme = Theme.of(context);
              return Padding(
                key: ValueKey('profile-suggestions-${widget.field}'),
                padding: const EdgeInsets.only(top: 8),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(
                          context.tr('Suggestions'),
                          style: theme.textTheme.labelLarge,
                        ),
                      ),
                      for (final suggestion in suggestions)
                        TextButton(
                          key: ValueKey(
                            'profile-suggestion-${widget.field}-${suggestion.value}',
                          ),
                          style: TextButton.styleFrom(
                            alignment: Alignment.centerLeft,
                            minimumSize: const Size(48, 56),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ),
                          onPressed: !widget.enabled
                              ? null
                              : () {
                                  widget.onSelected(suggestion);
                                  _groupFocus.unfocus();
                                },
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.field == 'county'
                                    ? context.tr(suggestion.label)
                                    : suggestion.label,
                              ),
                              if (suggestion.detail != null)
                                Text(
                                  {
                                        'San Mateo County',
                                        'Santa Clara County',
                                        'California',
                                      }.contains(suggestion.detail)
                                      ? context.tr(suggestion.detail!)
                                      : suggestion.detail!,
                                  style: theme.textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    ),
  );
}
