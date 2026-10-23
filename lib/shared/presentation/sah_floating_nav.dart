import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// Top-level shell tabs. The assistant is a destination, not a floating
/// button, so it never covers row actions and always keeps its label.
enum HomiTab { plan, rooms, help, tasks, assistant }

/// Page padding for scrolling content inside the shell. The tab bar is laid
/// out below the body, so no extra clearance is needed.
EdgeInsets sahFloatingContentPadding(BuildContext context, {double all = 20}) =>
    EdgeInsets.all(all);

/// One shell for both the selected-plan and no-plan states.
class SahFloatingScaffold extends StatelessWidget {
  const SahFloatingScaffold({
    super.key,
    required this.body,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final Widget body;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(bottom: false, child: body),
    bottomNavigationBar: SahFloatingNavBar(
      selectedIndex: selectedIndex,
      onDestinationSelected: onDestinationSelected,
      destinations: homiDestinations(context),
    ),
  );
}

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
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Labels stay visible at every text size and never split mid-word. They
    // grow up to 1.3×, then shrink just enough for the longest translated
    // label to fit its tab; long-pressing shows the full label.
    final style =
        (theme.navigationBarTheme.labelTextStyle?.resolve({
                  WidgetState.selected,
                }) ??
                theme.textTheme.labelMedium)
            ?.copyWith(fontWeight: FontWeight.w700);
    final width = MediaQuery.sizeOf(context).width / destinations.length - 8;
    var widest = 0.0;
    for (final destination in destinations) {
      final painter = TextPainter(
        text: TextSpan(text: destination.label, style: style),
        textDirection: Directionality.of(context),
        maxLines: 1,
      )..layout();
      if (painter.width > widest) widest = painter.width;
      painter.dispose();
    }
    // The scale at which the longest label still fits on one line.
    final fits = widest <= 0 ? 1.3 : width / widest;
    final requested = MediaQuery.textScalerOf(context).scale(1);
    final scale = [requested, 1.3, fits].reduce((a, b) => a < b ? a : b);
    final label = scale < .7 ? .7 : scale;
    return MediaQuery.withClampedTextScaling(
      minScaleFactor: label,
      maxScaleFactor: label,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: NavigationBar(
          height: 72,
          backgroundColor: scheme.surfaceContainerLow,
          surfaceTintColor: Colors.transparent,
          indicatorColor: scheme.primaryContainer,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          selectedIndex: selectedIndex,
          onDestinationSelected: onDestinationSelected,
          destinations: destinations,
        ),
      ),
    );
  }
}

List<NavigationDestination> homiDestinations(BuildContext context) => [
  for (final tab in HomiTab.values)
    NavigationDestination(
      key: ValueKey('plan-tab-${tab.name}'),
      icon: Icon(switch (tab) {
        HomiTab.plan => Icons.home_outlined,
        HomiTab.rooms => Icons.grid_view_outlined,
        HomiTab.help => Icons.support_agent_outlined,
        HomiTab.tasks => Icons.checklist_outlined,
        HomiTab.assistant => Icons.chat_bubble_outline,
      }),
      selectedIcon: Icon(switch (tab) {
        HomiTab.plan => Icons.home_rounded,
        HomiTab.rooms => Icons.grid_view_rounded,
        HomiTab.help => Icons.support_agent,
        HomiTab.tasks => Icons.checklist_rounded,
        HomiTab.assistant => Icons.chat_bubble_rounded,
      }),
      label: context.tr(switch (tab) {
        HomiTab.plan => 'Plan',
        HomiTab.rooms => 'Rooms',
        HomiTab.help => 'Help',
        HomiTab.tasks => 'Tasks',
        HomiTab.assistant => 'Assistant',
      }),
    ),
];

/// Keeps a tab's pushed screens inside the tab, so the tab bar stays
/// visible and each tab remembers where the person was.
class SahTabNavigator extends StatefulWidget {
  const SahTabNavigator({
    super.key,
    required this.child,
    this.active = true,
    this.onOpenScreensChanged,
  });
  final Widget child;
  final bool active;
  final ValueChanged<bool>? onOpenScreensChanged;

  @override
  State<SahTabNavigator> createState() => SahTabNavigatorState();
}

class SahTabNavigatorState extends State<SahTabNavigator> {
  final _navigator = GlobalKey<NavigatorState>();
  late final _observer = _DepthObserver(_depthChanged);
  int _depth = 0;

  bool get hasOpenScreens => _depth > 1;

  void _depthChanged(int delta) {
    final before = hasOpenScreens;
    _depth += delta;
    if (before != hasOpenScreens) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onOpenScreensChanged?.call(hasOpenScreens);
      });
    }
  }

  /// Returns to the tab's first screen through each screen's own leave
  /// guard. Returns false when a screen keeps itself open.
  Future<bool> closeOpenScreens() async {
    while (hasOpenScreens) {
      final navigator = _navigator.currentState;
      if (navigator == null) return true;
      final before = _depth;
      await navigator.maybePop();
      await WidgetsBinding.instance.endOfFrame;
      if (_depth >= before) return false;
    }
    return true;
  }

  void closeAllNow() =>
      _navigator.currentState?.popUntil((route) => route.isFirst);

  @override
  Widget build(BuildContext context) => NavigatorPopHandler<Object?>(
    enabled: widget.active,
    onPopWithResult: (_) => _navigator.currentState?.maybePop(),
    child: Navigator(
      key: _navigator,
      observers: [_observer],
      pages: [
        MaterialPage<void>(
          key: const ValueKey('tab-root'),
          child: widget.child,
        ),
      ],
      onDidRemovePage: (_) {},
    ),
  );
}

class _DepthObserver extends NavigatorObserver {
  _DepthObserver(this.changed);
  final ValueChanged<int> changed;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      route is PageRoute ? changed(1) : null;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      route is PageRoute ? changed(-1) : null;
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      route is PageRoute ? changed(-1) : null;
}
