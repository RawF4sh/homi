import 'package:flutter/material.dart';

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
          const SahSectionHeading(title: 'Appearance'),
          RadioGroup<ThemeMode>(
            groupValue: mode,
            onChanged: (value) {
              if (value != null) appearance.choose(value);
            },
            child: const Column(
              children: [
                RadioListTile<ThemeMode>(
                  key: ValueKey('appearance-system'),
                  value: ThemeMode.system,
                  contentPadding: EdgeInsets.zero,
                  title: Text('Match phone setting'),
                ),
                RadioListTile<ThemeMode>(
                  key: ValueKey('appearance-light'),
                  value: ThemeMode.light,
                  contentPadding: EdgeInsets.zero,
                  title: Text('Light'),
                ),
                RadioListTile<ThemeMode>(
                  key: ValueKey('appearance-dark'),
                  value: ThemeMode.dark,
                  contentPadding: EdgeInsets.zero,
                  title: Text('Dark'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
