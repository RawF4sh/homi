import 'package:flutter/material.dart';

class SahBrandMark extends StatelessWidget {
  const SahBrandMark({super.key, this.size = 44});
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(size * .3),
      ),
      child: Icon(
        Icons.cottage_outlined,
        color: Theme.of(context).colorScheme.onPrimary,
        size: size * .62,
      ),
    ),
  );
}

class SahHomeIllustration extends StatelessWidget {
  const SahHomeIllustration({super.key, this.height = 148});
  final double height;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      height: height,
      width: height * 1.45,
      child: CustomPaint(
        painter: _HomeIllustrationPainter(
          dark: Theme.of(context).brightness == Brightness.dark,
        ),
      ),
    ),
  );
}

class _HomeIllustrationPainter extends CustomPainter {
  const _HomeIllustrationPainter({required this.dark});

  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 240, size.height / 166);
    final paint = Paint()..isAntiAlias = true;
    void polygon(List<Offset> points, Color color) {
      final path = Path()..addPolygon(points, true);
      canvas.drawPath(path, paint..color = color);
    }

    const cream = Color(0xFFF8F4E4);
    const forest = Color(0xFF355E4C);
    const sage = Color(0xFFB9CEAC);
    const apricot = Color(0xFFE9B892);
    canvas.drawOval(
      const Rect.fromLTWH(15, 111, 214, 49),
      paint..color = dark ? const Color(0xFF2A2F2D) : const Color(0xFFCDDDC1),
    );
    polygon(const [
      Offset(57, 77),
      Offset(135, 91),
      Offset(135, 140),
      Offset(57, 122),
    ], cream);
    polygon(const [
      Offset(135, 91),
      Offset(181, 63),
      Offset(181, 112),
      Offset(135, 140),
    ], const Color(0xFFE5E9D1));
    polygon(const [
      Offset(47, 77),
      Offset(79, 23),
      Offset(151, 38),
      Offset(139, 95),
    ], forest);
    polygon(const [Offset(139, 95), Offset(151, 38), Offset(191, 66)], sage);
    polygon(const [Offset(151, 38), Offset(181, 63), Offset(146, 84)], cream);
    polygon(const [
      Offset(91, 95),
      Offset(114, 100),
      Offset(114, 135),
      Offset(91, 130),
    ], apricot);
    polygon(const [
      Offset(66, 86),
      Offset(81, 89),
      Offset(81, 108),
      Offset(66, 105),
    ], sage);
    polygon(const [
      Offset(149, 98),
      Offset(169, 86),
      Offset(169, 106),
      Offset(149, 119),
    ], forest);
    polygon(const [
      Offset(102, 132),
      Offset(118, 135),
      Offset(100, 153),
      Offset(78, 147),
    ], const Color(0xFFEEEBD9));
    canvas.drawCircle(const Offset(108, 116), 1.5, paint..color = forest);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(207, 89, 4, 43),
        const Radius.circular(2),
      ),
      paint..color = forest,
    );
    canvas.drawOval(const Rect.fromLTWH(191, 55, 34, 52), paint..color = sage);
    canvas.drawOval(
      const Rect.fromLTWH(195, 68, 24, 34),
      paint..color = const Color(0xFF9BB991),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(32, 116, 15, 16),
        const Radius.circular(3),
      ),
      paint..color = apricot,
    );
    canvas.drawOval(
      const Rect.fromLTWH(29, 100, 20, 22),
      paint..color = forest,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HomeIllustrationPainter oldDelegate) =>
      oldDelegate.dark != dark;
}

class SahStatusBadge extends StatelessWidget {
  const SahStatusBadge({
    super.key,
    required this.label,
    this.icon,
    this.tone = SahNoticeTone.info,
  });
  final String label;
  final IconData? icon;
  final SahNoticeTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (tone) {
      SahNoticeTone.info => (
        scheme.surfaceContainerLow,
        scheme.onSurfaceVariant,
      ),
      SahNoticeTone.success => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      SahNoticeTone.warning => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      SahNoticeTone.error => (scheme.errorContainer, scheme.onErrorContainer),
    };
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (icon != null) ...[
              ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(icon, size: 17, color: foreground),
                ),
              ),
              const SizedBox(width: 7),
            ],
            Flexible(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SahFeaturePanel extends StatelessWidget {
  const SahFeaturePanel({
    super.key,
    this.eyebrow,
    required this.title,
    required this.description,
    this.action,
    this.illustration,
  });
  final String? eyebrow;
  final String title, description;
  final Widget? action, illustration;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enlarged = MediaQuery.textScalerOf(context).scale(14) > 20;
    final dark = theme.brightness == Brightness.dark;
    final panel = dark ? scheme.surfaceContainer : scheme.primary;
    final onPanel = dark ? scheme.onSurface : scheme.onPrimary;
    return Container(
      padding: EdgeInsets.all(enlarged ? 16 : 24),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(26),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final content = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (eyebrow != null) ...[
                Text(
                  eyebrow!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: dark ? scheme.primary : onPanel,
                    letterSpacing: 1.3,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Semantics(
                header: true,
                child: Text(
                  title,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: onPanel,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                description,
                style: theme.textTheme.bodyMedium?.copyWith(color: onPanel),
              ),
              if (action != null) ...[
                const SizedBox(height: 20),
                FilledButtonTheme(
                  data: FilledButtonThemeData(
                    style: FilledButton.styleFrom(
                      foregroundColor: dark ? scheme.onPrimary : scheme.primary,
                      backgroundColor: dark
                          ? scheme.primary
                          : scheme.primaryContainer,
                      disabledForegroundColor: dark
                          ? scheme.onSurfaceVariant
                          : scheme.onPrimary,
                      disabledBackgroundColor: dark
                          ? scheme.outlineVariant
                          : const Color(0xFF48695C),
                      minimumSize: const Size(48, 52),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                  child: action!,
                ),
              ],
            ],
          );
          if (illustration == null ||
              constraints.maxWidth < 512 ||
              MediaQuery.textScalerOf(context).scale(14) > 20) {
            return content;
          }
          return Row(
            children: [
              Expanded(child: content),
              const SizedBox(width: 20),
              SizedBox(width: 180, child: illustration!),
            ],
          );
        },
      ),
    );
  }
}

class SahMoreInfo extends StatelessWidget {
  const SahMoreInfo({
    super.key,
    required this.details,
    this.label = 'More about this',
  });
  final List<String> details;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        Icons.info_outline_rounded,
        color: theme.colorScheme.primary,
      ),
      title: Text(
        label,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      children: [
        for (final text in details)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(text, style: theme.textTheme.bodyMedium),
          ),
      ],
    );
  }
}

class SahContent extends StatelessWidget {
  const SahContent({super.key, required this.child, this.maxWidth = 760});
  final Widget child;
  final double maxWidth;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}

class SahPageHeader extends StatelessWidget {
  const SahPageHeader({
    super.key,
    required this.title,
    this.description,
    this.eyebrow,
    this.trailing,
  });
  final String title;
  final String? description, eyebrow;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (eyebrow != null) ...[
            Text(
              eyebrow!,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.3,
              ),
            ),
            const SizedBox(height: 10),
          ],
          Semantics(
            header: true,
            child: Text(title, style: theme.textTheme.headlineMedium),
          ),
          if (description != null) ...[
            const SizedBox(height: 12),
            Text(
              description!,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (trailing != null) ...[const SizedBox(height: 16), trailing!],
        ],
      ),
    );
  }
}

class SahSectionHeading extends StatelessWidget {
  const SahSectionHeading({super.key, required this.title, this.description});
  final String title;
  final String? description;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        if (description != null) ...[
          const SizedBox(height: 6),
          Text(
            description!,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    ),
  );
}

enum SahNoticeTone { info, warning, error, success }

class SahNotice extends StatelessWidget {
  const SahNotice({
    super.key,
    required this.message,
    this.title,
    this.icon,
    this.tone = SahNoticeTone.info,
    this.messageKey,
    this.action,
    this.liveRegion = true,
  });
  final String message;
  final String? title;
  final IconData? icon;
  final SahNoticeTone tone;

  final Key? messageKey;

  final Widget? action;

  final bool liveRegion;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground, defaultIcon) = switch (tone) {
      SahNoticeTone.warning => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
        Icons.info_outline_rounded,
      ),
      SahNoticeTone.error => (
        scheme.errorContainer,
        scheme.onErrorContainer,
        Icons.error_outline,
      ),
      SahNoticeTone.success => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        Icons.check_circle_outline_rounded,
      ),
      SahNoticeTone.info => (
        scheme.surfaceContainerLow,
        scheme.onSurface,
        Icons.info_outline_rounded,
      ),
    };
    return Semantics(
      liveRegion: liveRegion,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: Icon(icon ?? defaultIcon, color: foreground, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null) ...[
                    Text(
                      title!,
                      style: Theme.of(
                        context,
                      ).textTheme.titleMedium?.copyWith(color: foreground),
                    ),
                    const SizedBox(height: 4),
                  ],
                  Text(
                    message,
                    key: messageKey,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: foreground),
                  ),
                  if (action != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: action,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SahActionFeedback extends StatefulWidget {
  const SahActionFeedback({
    super.key,
    required this.message,
    this.title,
    this.tone = SahNoticeTone.info,
    this.onReview,
    this.revealRevision = 0,
  });
  final String message;
  final String? title;
  final SahNoticeTone tone;
  final VoidCallback? onReview;
  final int revealRevision;

  @override
  State<SahActionFeedback> createState() => _SahActionFeedbackState();
}

class _SahActionFeedbackState extends State<SahActionFeedback> {
  final _anchor = GlobalKey();
  @override
  void initState() {
    super.initState();
    _reveal();
  }

  @override
  void didUpdateWidget(SahActionFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revealRevision != widget.revealRevision) {
      _reveal();
    }
  }

  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
      final target = _anchor.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(
          target,
          alignment: 0.1,
          duration: const Duration(milliseconds: 180),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(key: _anchor, height: 1),
      SahNotice(
        title: widget.title,
        message: widget.message,
        tone: widget.tone,
      ),
      if (widget.onReview != null)
        OutlinedButton(
          onPressed: widget.onReview,
          child: const Text('Review this answer'),
        ),
    ],
  );
}

class SahActionTile extends StatelessWidget {
  const SahActionTile({
    super.key,
    required this.title,
    this.overline,
    this.subtitle,
    required this.icon,
    this.onTap,
    this.trailing,
    this.enabled = true,
    this.status,
    this.statusIcon,
  });
  final String title;
  final String? overline;
  final String? subtitle;

  final String? status;
  final IconData? statusIcon;
  final IconData icon;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool enabled;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = enabled && onTap != null;
    final showIcon = MediaQuery.textScalerOf(context).scale(14) <= 20;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Semantics(
          button: true,
          enabled: active,
          child: InkWell(
            onTap: active ? onTap : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 64),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showIcon) ...[
                      ExcludeSemantics(
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: active
                                ? theme.colorScheme.primaryContainer
                                : theme.colorScheme.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                            icon,
                            color: active
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (overline != null) ...[
                            Text(
                              overline!,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                                letterSpacing: .7,
                              ),
                            ),
                            const SizedBox(height: 5),
                          ],
                          Text(
                            title,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: active
                                  ? theme.colorScheme.onSurface
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: 5),
                            Text(
                              subtitle!,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          if (status != null) ...[
                            const SizedBox(height: 8),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (statusIcon != null) ...[
                                  ExcludeSemantics(
                                    child: Padding(
                                      padding: const EdgeInsets.only(top: 1),
                                      child: Icon(
                                        statusIcon,
                                        size: 18,
                                        color: theme.colorScheme.primary,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                Flexible(
                                  child: Text(
                                    status!,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.onSurface,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    trailing ??
                        ExcludeSemantics(
                          child: Icon(
                            active
                                ? Icons.chevron_right_rounded
                                : Icons.lock_outline_rounded,
                            color: theme.colorScheme.onSurfaceVariant,
                            size: 22,
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SahEmptyState extends StatelessWidget {
  const SahEmptyState({
    super.key,
    required this.title,
    required this.message,
    required this.icon,
    this.action,
  });
  final String title, message;
  final IconData icon;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Icon(
            icon,
            size: 36,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 16),
        Semantics(
          header: true,
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        const SizedBox(height: 8),
        Text(message, style: Theme.of(context).textTheme.bodyLarge),
        if (action != null) ...[const SizedBox(height: 16), action!],
      ],
    ),
  );
}
