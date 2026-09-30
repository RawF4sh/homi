import 'package:flutter/material.dart';

import '../application/bathroom_scan_availability.dart';

class AssessmentScanEntry extends StatelessWidget {
  const AssessmentScanEntry({
    super.key,
    required this.availability,
    required this.onOpen,
    required this.onCheck,
  });

  final BathroomScanAvailability availability;
  final VoidCallback? onOpen, onCheck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final capability = availability.capabilities;
    final primary = availability.prefersScan;
    final title = primary
        ? 'Scan your bathroom in 3D'
        : availability.checking
        ? 'Checking 3D scan support'
        : 'Photos and measurements work here';
    final description = availability.checking
        ? 'You can start with photos or measurements while we check this phone.'
        : availability.failed
        ? 'The scanner check could not finish. Try again, or use photos and measurements.'
        : switch (capability?.reason) {
            'services_missing' =>
              'This Android phone supports ARCore. Set up Google Play Services for AR to scan.',
            'services_update_required' =>
              'Update Google Play Services for AR when you start scanning.',
            'permission_denied' =>
              capability?.source == 'roomplan'
                  ? 'Allow camera access for Safe at Home in Settings, then return to scan.'
                  : 'Allow camera access when prompted, or in Settings if permission was previously blocked.',
            'available' when primary =>
              capability?.source == 'arcore'
                  ? 'Scan with ARCore, label the surfaces, then confirm what to add.'
                  : 'Scan with LiDAR, then confirm what to add.',
            'checking' =>
              'Device support is not confirmed yet. Check again, or use photos and measurements.',
            'unsupported_os' =>
              '3D scanning needs a newer operating system. Photos and manual measurements are ready now.',
            'simulator' =>
              '3D capture needs a supported physical phone. You can still review a saved model.',
            _ =>
              '3D capture is unavailable on this phone. You can still review a saved model.',
          };
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: primary
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(title, style: theme.textTheme.titleLarge),
          ),
          const SizedBox(height: 8),
          Text(description),
          const SizedBox(height: 16),
          if (primary)
            FilledButton.icon(
              key: const ValueKey('open-bathroom-scan'),
              onPressed: onOpen,
              icon: const Icon(Icons.view_in_ar),
              label: const Text(
                'Scan bathroom in 3D',
                textAlign: TextAlign.center,
              ),
            )
          else
            OutlinedButton.icon(
              key: const ValueKey('open-bathroom-scan'),
              onPressed: onOpen,
              icon: const Icon(Icons.view_in_ar),
              label: const Text(
                'Saved 3D model & scan options',
                textAlign: TextAlign.center,
              ),
            ),
          if (!primary && !availability.checking)
            TextButton(
              key: const ValueKey('recheck-bathroom-scan'),
              onPressed: onCheck,
              child: const Text('Check scanning support again'),
            ),
        ],
      ),
    );
  }
}
