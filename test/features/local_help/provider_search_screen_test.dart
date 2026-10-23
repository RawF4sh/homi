import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/local_help/local_help_record.dart';
import 'package:safe_at_home/features/local_help/local_help_repository.dart';
import 'package:safe_at_home/features/local_help/local_help_screen.dart';
import 'package:safe_at_home/features/local_help/provider_search_section.dart';
import 'package:safe_at_home/features/local_help/referral_directory.dart';
import 'package:safe_at_home/features/tracking/program_progress_screen.dart';
import 'package:safe_at_home/features/tracking/task_editor_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../../app/app_design_test.dart' show narrowLargeText;
import '../../app/core_localization_test.dart' show localized;
import 'local_help_screen_test.dart' show make, tap, reveal;
import 'referral_test_support.dart';

const providerId = 'provider-cid-san-mateo';
Finder providerAction(String label, {String id = providerId}) =>
    find.descendant(of: find.byKey(ValueKey(id)), matching: find.text(label));

void main() {
  testWidgets(
    'new county listings do not show the old unsupported-location message',
    (tester) async {
      final app = await make();
      await LocalHelpRepository(app.coordinator).confirmLocation(
        HelpLocation(stateCode: 'CA', city: '', county: 'Alameda', zip: null),
      );
      await tester.pumpWidget(
        localized(const Locale('en'), LocalHelpScreen(services: app)),
      );
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const ValueKey('local-provider-search')));
      await reveal(tester, find.text('Providers found: 3'));
      await reveal(tester, find.text('Official referrals'));
      expect(
        find.text(
          'No reviewed local listing for this location. Use the national locators to ask who serves your address.',
        ),
        findsNothing,
      );
      await reveal(tester, find.byKey(const ValueKey('referral-211-national')));
      await reveal(tester, find.byKey(const ValueKey('referral-211-bay-area')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'closed Sonoma intake is visible before opening details and keeps contact actions',
    (tester) async {
      final app = await make();
      await LocalHelpRepository(app.coordinator).confirmLocation(
        HelpLocation(stateCode: 'CA', city: '', county: 'Sonoma', zip: null),
      );
      final opened = <Uri>[];
      await tester.pumpWidget(
        localized(
          const Locale('en'),
          LocalHelpScreen(
            services: app,
            openExternal: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const ValueKey('local-provider-search')));
      const closedId = 'provider-habitat-sonoma-county';
      final row = find.byKey(const ValueKey('provider-result-$closedId'));
      await reveal(tester, row);
      expect(
        find.descendant(
          of: row,
          matching: find.text('Intake closed: ask about alternatives.'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey(closedId)), findsNothing);
      expect(opened, isEmpty);
      await tap(tester, row);
      await tap(tester, providerAction('Call organization', id: closedId));
      expect(opened.single.toString(), 'tel:7075787707');
      await tap(tester, providerAction('Save contact', id: closedId));
      await tester.tap(find.text('Save on this device'));
      await tester.pumpAndSettle();
      expect(
        (await LocalHelpRepository(
          app.coordinator,
        ).load()).contacts.single.providerId,
        closedId,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'only confirmed county changes the filter; stale coverage stays unknown',
    (tester) async {
      final app = await make();
      final repo = LocalHelpRepository(app.coordinator);
      await repo.confirmLocation(
        HelpLocation(stateCode: 'CA', city: '', county: 'San Mateo', zip: null),
      );
      await tester.pumpWidget(
        localized(
          const Locale('en'),
          LocalHelpScreen(services: app, now: () => DateTime(2027)),
        ),
      );
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const ValueKey('local-provider-search')));
      await reveal(tester, find.text('Providers found: 2'));
      final county = find.widgetWithText(TextFormField, 'County (optional)');
      await reveal(tester, county);
      await tester.enterText(county, 'Santa Clara County');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Providers found: 2'));
      await tap(tester, find.text('Confirm location'));
      await reveal(tester, find.text('Providers found: 2'));
      await tap(
        tester,
        find.byKey(
          const ValueKey(
            'provider-result-provider-rebuilding-together-silicon-valley',
          ),
        ),
      );
      final card = find.byKey(
        const ValueKey('provider-rebuilding-together-silicon-valley'),
      );
      await reveal(
        tester,
        find.descendant(
          of: card,
          matching: find.text('Coverage unknown: contact to confirm.'),
        ),
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text('Listing needs review. Contact to confirm.'),
        ),
        findsOneWidget,
      );
      await tap(tester, find.text('Clear search and filters'));
      await reveal(tester, find.text('Providers found: 17'));
      expect((await repo.load()).location!.county, 'Santa Clara County');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offline query and filters recover to all results; locators remain available',
    (tester) async {
      final app = await make();
      await LocalHelpRepository(app.coordinator).confirmLocation(
        HelpLocation(
          stateCode: 'CA',
          city: '',
          county: 'Unlisted county',
          zip: null,
        ),
      );
      await tester.pumpWidget(
        localized(const Locale('en'), LocalHelpScreen(services: app)),
      );
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const ValueKey('local-provider-search')));
      await reveal(tester, find.text('Providers found: 0'));
      await tap(tester, find.text('Clear search and filters'));
      await reveal(tester, find.text('Providers found: 17'));
      final query = find.byKey(const ValueKey('provider-search-query'));
      await reveal(tester, query);
      await tester.enterText(query, 'San José');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Providers found: 1'));
      await reveal(
        tester,
        find.byKey(
          const ValueKey(
            'provider-result-provider-rebuilding-together-silicon-valley',
          ),
        ),
      );
      await reveal(tester, query);
      await tester.enterText(query, 'fictional no result');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      await reveal(
        tester,
        find.textContaining('No providers match these filters.'),
      );
      await reveal(tester, find.byKey(const ValueKey('referral-211-national')));
      await reveal(
        tester,
        find.byKey(const ValueKey('referral-rebuilding-together-national')),
      );
      await tap(tester, find.text('Clear search and filters'));
      await reveal(tester, find.text('Providers found: 17'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new provider contact survives reopen and filtering; links carry no search or note',
    (tester) async {
      final app = await make();
      final repo = LocalHelpRepository(app.coordinator);
      await repo.confirmLocation(
        HelpLocation(stateCode: 'CA', city: '', county: 'San Mateo', zip: null),
      );
      final opened = <Uri>[];
      Widget screen() => localized(
        const Locale('en'),
        LocalHelpScreen(
          key: UniqueKey(),
          services: app,
          openExternal: (uri) async {
            opened.add(uri);
            return true;
          },
        ),
      );
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const ValueKey('local-provider-search')));
      await tap(
        tester,
        find.byKey(const ValueKey('provider-result-$providerId')),
      );
      await tap(tester, providerAction('Save contact'));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Contact note (optional)'),
        'Fictional private note',
      );
      await tester.tap(find.text('Save on this device'));
      await tester.pumpAndSettle();
      expect((await repo.load()).contacts.single.providerId, providerId);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const ValueKey('local-provider-search')));
      await tap(
        tester,
        find.byKey(const ValueKey('provider-result-$providerId')),
      );
      await tap(tester, providerAction('Open official website'));
      expect(
        opened.single.toString(),
        const OfficialReferralDirectory().provider(providerId)!.website,
      );
      final query = find.byKey(const ValueKey('provider-search-query'));
      await reveal(tester, query);
      await tester.enterText(query, 'no result');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Fictional private note'));
      expect(
        (await repo.load()).contacts.single.note,
        'Fictional private note',
      );
      await reveal(tester, query);
      expect(tester.widget<TextField>(query).controller!.text, 'no result');
      expect(tester.takeException(), isNull);
    },
  );

  for (final id in [providerId, 'provider-habitat-east-bay-silicon-valley']) {
    testWidgets(
      'provider $id creates and reopens its shared follow-up identity',
      (tester) async {
        final h = await ReferralHarness.create();
        addTearDown(h.dispose);
        await tester.pumpWidget(
          localized(const Locale('en'), LocalHelpScreen(services: h.app)),
        );
        await tester.pumpAndSettle();
        await tap(tester, find.byKey(const ValueKey('local-provider-search')));
        await tap(tester, find.byKey(ValueKey('provider-result-$id')));
        await tap(tester, providerAction('Add follow-up', id: id));
        expect(find.byType(ProgramProgressScreen), findsOneWidget);
        expect(h.server.tasks, isEmpty);
        await tap(tester, find.text('Add next step'));
        expect(find.byType(TaskEditorScreen), findsOneWidget);
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Next step'),
          'Fictional ask about modifications',
        );
        await tap(tester, find.text('Save task'));
        expect(
          (h.server.tasks.values.single['referral'] as Map)['providerId'],
          id,
        );
        expect(h.server.tasks.values.single['programId'], isNull);
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tap(tester, providerAction('Add follow-up', id: id));
        await reveal(tester, find.text('Fictional ask about modifications'));
        expect(h.server.tasks, hasLength(1));
        expect(h.device.requests, 0);
      },
    );
  }

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets(
      'search controls and filters wrap at large text in ${locale.toLanguageTag()}',
      (tester) async {
        narrowLargeText(tester, scale: 3.2);
        final tr = AppLocalizations(locale);
        await tester.pumpWidget(
          localized(
            locale,
            Scaffold(
              body: SingleChildScrollView(
                child: ProviderSearchSection(
                  directory: const OfficialReferralDirectory(),
                  providerCard: (p) => Text(p.name),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final query = find.byKey(const ValueKey('provider-search-query'));
        await tester.enterText(query, tr.text('Service coordination'));
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        await reveal(
          tester,
          find.text(tr.text('Providers found: {count}', {'count': '6'})),
        );
        await tap(tester, find.text(tr.text('Clear search and filters')));
        await tap(tester, find.text(tr.text('All services')));
        final option = find.widgetWithText(
          DropdownMenuItem<String>,
          tr.text('Service coordination'),
        );
        await tester.scrollUntilVisible(
          option,
          100,
          scrollable: find.byType(Scrollable).last,
          maxScrolls: 20,
        );
        await tester.pumpAndSettle();
        await tester.tap(option);
        await tester.pumpAndSettle();
        await reveal(
          tester,
          find.text(tr.text('Providers found: {count}', {'count': '6'})),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
