import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../../app/appearance.dart';
import '../../shared/presentation/sah_components.dart';

class AppearanceSection extends StatelessWidget {
  const AppearanceSection({super.key, AppAppearance? appearance})
    : _appearance = appearance;
  final AppAppearance? _appearance;

  @override
  Widget build(BuildContext context) {
    final appearance = _appearance ?? AppAppearance.instance;
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appearance,
      builder: (context, mode, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SahSectionHeading(title: context.tr('Appearance')),
          RadioGroup<ThemeMode>(
            groupValue: mode,
            onChanged: (value) {
              if (value != null) appearance.choose(value);
            },
            child: Column(
              children: [
                RadioListTile<ThemeMode>(
                  key: ValueKey('appearance-system'),
                  value: ThemeMode.system,
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.tr('Match phone setting')),
                ),
                RadioListTile<ThemeMode>(
                  key: ValueKey('appearance-light'),
                  value: ThemeMode.light,
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.tr('Light')),
                ),
                RadioListTile<ThemeMode>(
                  key: ValueKey('appearance-dark'),
                  value: ThemeMode.dark,
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.tr('Dark')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
