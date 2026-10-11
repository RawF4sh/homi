import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/local_help/provider_search.dart';
import 'package:safe_at_home/features/local_help/referral_directory.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';

void main() {
  const directory = OfficialReferralDirectory();
  const silicon = 'provider-rebuilding-together-silicon-valley';
  test(
    'catalog has stable unique identities, sources and bounded review dates',
    () {
      expect(
        directory.providers.map((p) => p.id).toSet().length,
        directory.providers.length,
      );
      expect(localProviderCatalogVersion, 'bay-area-2026-10-24-v1');
      for (final p in localProviderCatalog) {
        expect(directory.provider(p.id), same(p));
        expect(p.isLocalProvider, isTrue);
        expect(p.counties, isNotEmpty);
        expect(p.sources, contains(p.website));
        for (final source in p.sources) {
          expect(Uri.parse(source).scheme, 'https');
        }
        expect(referralDestination(p).hasQuery, isFalse);
        expect(referralDestination(p, phone: true).scheme, 'tel');
        expect(
          DateTime.parse(
            p.reviewAfter,
          ).difference(DateTime.parse(p.reviewedOn)).inDays,
          30,
        );
        expect(p.availability, ReferralAvailability.unknown);
        expect(p.needsReview(DateTime(2026, 11, 23)), isTrue);
        expect(
          p.coverage(p.counties.first, DateTime(2026, 11, 23)),
          ReferralCoverage.unknown,
        );
      }
    },
  );

  test(
    'search finds individual organizations rather than national locators',
    () {
      final all = searchLocalProviders(directory);
      expect(all, hasLength(4));
      expect(
        all.any((p) => p.isLocator || officialReferrals.contains(p)),
        isFalse,
      );
      expect(
        searchLocalProviders(directory, query: '  SAN JOSÉ!  ').single.id,
        silicon,
      );
      expect(
        searchLocalProviders(directory, query: 'rebuilding silicon').single.id,
        silicon,
      );
      expect(
        searchLocalProviders(
          directory,
          query: 'Cupertino',
          county: 'Santa Clara County',
        ).single.id,
        silicon,
      );
      expect(
        searchLocalProviders(
          directory,
          query: 'Cupertino',
          county: 'San Mateo',
        ),
        isEmpty,
      );
      expect(searchLocalProviders(directory, query: '94105'), isEmpty);
      expect(
        searchLocalProviders(directory, query: 'Fictional unavailable repair'),
        isEmpty,
      );
      expect(searchLocalProviders(directory, county: 'not listed'), isEmpty);
      expect(searchLocalProviders(directory, query: '   '), all);
      expect(() => all.clear(), throwsUnsupportedError);
    },
  );

  test(
    'service filters distinguish coordination and direct repair discovery',
    () {
      expect(
        searchLocalProviders(directory, service: ReferralService.homeRepair),
        hasLength(3),
      );
      expect(
        searchLocalProviders(
          directory,
          county: 'SAN MATEO county',
          service: ReferralService.coordination,
        ).single.id,
        'provider-cid-san-mateo',
      );
      expect(
        searchLocalProviders(
          directory,
          county: 'San Mateo',
          service: ReferralService.accessibility,
        ).single.id,
        'provider-habitat-greater-san-francisco',
      );
      expect(
        searchLocalProviders(
          directory,
          county: 'Santa Clara',
          service: ReferralService.coordination,
        ),
        isEmpty,
      );
    },
  );

  test(
    'translated service and description text is searchable without renaming organizations',
    () {
      for (final locale in AppLocalizations.supportedLocales) {
        final tr = AppLocalizations(locale);
        final results = searchLocalProviders(
          directory,
          query: tr.text('Service coordination'),
          translate: tr.text,
        );
        expect(results.single.id, 'provider-cid-san-mateo');
        expect(results.single.name, contains('(CID)'));
      }
      final tr = AppLocalizations(const Locale('es'));
      expect(
        searchLocalProviders(
          directory,
          query: 'tecnologia',
          translate: tr.text,
        ).single.id,
        'provider-cid-san-mateo',
      );
    },
  );
}
