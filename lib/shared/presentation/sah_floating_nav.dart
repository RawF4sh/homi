import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../l10n/app_localizations.dart';
import '../navigation/homi_destination.dart';

const double sahFloatingNavHeight = 72;

double sahFloatingNavClearance(BuildContext context) =>
    MediaQuery.paddingOf(context).bottom + 24;

class SahFloatingNavBar extends StatelessWidget {
  const SahFloatingNavBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    if (media.viewInsets.bottom > 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final iOS = theme.platform == TargetPlatform.iOS;
    final opaque = media.highContrast || media.accessibleNavigation || !iOS;
    final surface = opaque
        ? scheme.surfaceContainerLow
        : scheme.surfaceContainerLow.withValues(alpha: .9);
    final largeText = media.textScaler.scale(14) > 22;
    final navigation = largeText
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  destinations[selectedIndex].label,
                  style: theme.textTheme.labelMedium,
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < destinations.length; i++)
                    Expanded(
                      child: Semantics(
                        selected: i == selectedIndex,
                        label: destinations[i].label,
                        button: true,
                        child: Tooltip(
                          message: destinations[i].label,
                          child: IconButton(
                            key: destinations[i].key,
                            constraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                            onPressed: () => onDestinationSelected(i),
                            icon: ExcludeSemantics(child: destinations[i].icon),
                            color: i == selectedIndex
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          )
        : media.size.width < 360
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < destinations.length; i++)
                Expanded(
                  child: Semantics(
                    selected: i == selectedIndex,
                    button: true,
                    child: InkWell(
                      key: destinations[i].key,
                      onTap: () => onDestinationSelected(i),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 12,
                            horizontal: 2,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ExcludeSemantics(
                                child: IconTheme(
                                  data: IconThemeData(
                                    color: i == selectedIndex
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                  ),
                                  child: destinations[i].icon,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                destinations[i].label,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.labelSmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          )
        : NavigationBar(
            height: sahFloatingNavHeight,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.transparent,
            elevation: 0,
            indicatorColor: scheme.primaryContainer,
            indicatorShape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(SahRadius.medium),
            ),
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            selectedIndex: selectedIndex,
            onDestinationSelected: onDestinationSelected,
            destinations: destinations,
          );
    final bar = DecoratedBox(
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: theme.brightness == Brightness.dark ? .4 : .08,
            ),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: MediaQuery.removePadding(
        context: context,
        removeBottom: true,
        child: navigation,
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        media.padding.bottom > 0 ? media.padding.bottom : 12,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: opaque || kIsWeb
            ? bar
            : BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: bar,
              ),
      ),
    );
  }
}

List<NavigationDestination> homiDestinations(BuildContext context) => [
  for (final destination in HomiDestination.values)
    NavigationDestination(
      key: ValueKey('plan-tab-${destination.name}'),
      icon: Icon(switch (destination) {
        HomiDestination.plan => Icons.home_outlined,
        HomiDestination.rooms => Icons.grid_view_outlined,
        HomiDestination.help => Icons.support_agent_outlined,
        HomiDestination.tasks => Icons.checklist_outlined,
        HomiDestination.settings => Icons.settings_outlined,
      }),
      label: context.tr(switch (destination) {
        HomiDestination.plan => 'Plan',
        HomiDestination.rooms => 'Rooms',
        HomiDestination.help => 'Help',
        HomiDestination.tasks => 'Tasks',
        HomiDestination.settings => 'Settings',
      }),
    ),
];
