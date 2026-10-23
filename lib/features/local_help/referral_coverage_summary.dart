import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import 'referral_directory.dart';

/// Counts Homi's actual reviewed records, independent of external network reach.
class ReferralCoverageSummary extends StatelessWidget {
  const ReferralCoverageSummary({
    super.key,
    required this.directory,
    this.stateCode,
    required this.now,
  });
  final ReferralDirectory directory;
  final String? stateCode;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final organizations = directory.providers.where((p) => p.isLocalProvider);
    final ids = organizations.map((p) => p.canonicalOrganizationId).toSet();
    final states = organizations.expand((p) => p.stateCodes).toSet();
    final local = organizations.where((p) => p.stateCodes.contains(stateCode));
    final fresh = local.where((p) => !p.needsReview(now));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.tr('Homi coverage'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(context.tr('Official referral routes: all 50 states and DC.')),
            Text(
              context.tr(
                'Homi catalog: {count} organizations in {states} states.',
                {'count': '${ids.length}', 'states': '${states.length}'},
              ),
            ),
            if (stateCode != null)
              Text(
                context.tr(
                  'Reviewed organizations in this state: {count}; current records: {fresh}.',
                  {
                    'count':
                        '${local.map((p) => p.canonicalOrganizationId).toSet().length}',
                    'fresh':
                        '${fresh.map((p) => p.canonicalOrganizationId).toSet().length}',
                  },
                ),
              ),
            Text(
              context.tr(
                'Eligibility checks: no nationwide eligibility decision.',
              ),
            ),
            Text(
              context.tr(
                'Official PDFs: existing California routes only, subject to program review. Federal routes provide preparation information.',
              ),
            ),
            Text(
              context.tr(
                'Listings do not establish address coverage, available funding or a partnership.',
              ),
            ),
            Text(
              context.tr('Catalog version: {version}', {
                'version': localProviderCatalogVersion,
              }),
            ),
          ],
        ),
      ),
    );
  }
}
