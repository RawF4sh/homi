import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/presentation/sah_components.dart';

class PlanAssistantScreen extends StatelessWidget {
  const PlanAssistantScreen({super.key, required this.onSection});
  final ValueChanged<int> onSection;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.tr('Plan assistant'))),
    body: SafeArea(
      child: SahContent(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: SahStatusBadge(
                label: context.tr('AI coming later'),
                icon: Icons.chat_bubble_outline_rounded,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              context.tr('Help with your next step'),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Text(
              context.tr(
                'AI chat is not connected. These shortcuts open the app; they do not send your plan to an AI service.',
              ),
            ),
            const SizedBox(height: 24),
            SahActionTile(
              key: const ValueKey('assistant-next-step'),
              title: context.tr('What should I do next?'),
              icon: Icons.arrow_forward_rounded,
              onTap: () => onSection(0),
            ),
            SahActionTile(
              key: const ValueKey('assistant-rooms'),
              title: context.tr('Where are my scans and concerns?'),
              icon: Icons.view_in_ar,
              onTap: () => onSection(1),
            ),
            SahActionTile(
              key: const ValueKey('assistant-help'),
              title: context.tr('Where can I find assistance?'),
              icon: Icons.support_agent_outlined,
              onTap: () => onSection(2),
            ),
            const SizedBox(height: 16),
            ExpansionTile(
              title: Text(context.tr('About the future assistant')),
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    context.tr(
                      'Planned: explain confirmed findings, help with app steps, and point to reviewed program sources. It will not decide eligibility or submit applications for you.',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
