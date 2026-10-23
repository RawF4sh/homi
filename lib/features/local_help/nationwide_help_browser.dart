import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/presentation/sah_floating_nav.dart';
import 'local_help_record.dart';
import 'provider_search_section.dart';
import 'referral_directory.dart';
import 'referral_coverage_summary.dart';

/// Public, read-only discovery. A browsing location is not a resident profile
/// update and is never included in an external link.
class NationwideHelpBrowser extends StatefulWidget {
  const NationwideHelpBrowser({
    super.key,
    this.directory = const OfficialReferralDirectory(),
    this.openExternal,
    this.now,
    this.embedded = false,
  });
  final ReferralDirectory directory;
  final Future<bool> Function(Uri)? openExternal;
  final DateTime Function()? now;
  final bool embedded;

  @override
  State<NationwideHelpBrowser> createState() => _NationwideHelpBrowserState();
}

class _NationwideHelpBrowserState extends State<NationwideHelpBrowser> {
  HelpLocation? _location;
  String? _error;
  bool _opening = false;

  Future<void> _open(ReferralProvider provider, {bool phone = false}) async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final uri = referralDestination(provider, phone: phone);
      final opened =
          await (widget.openExternal?.call(uri) ??
              launchUrl(uri, mode: LaunchMode.externalApplication));
      if (!opened) throw StateError('External application unavailable');
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not open this link or dialer. Check your connection, try the official locator, or use the phone number or website shown below.',
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _planNeeded() => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        context.tr(
          'Create or open a plan to save contacts and add follow-ups.',
        ),
      ),
    ),
  );

  Widget _card(ReferralProvider provider) => NationwideReferralCard(
    provider: provider,
    location: _location,
    now: widget.now?.call() ?? DateTime.now(),
    actions: Wrap(
      spacing: 8,
      children: [
        if (provider.phone != null)
          TextButton(
            onPressed: _opening ? null : () => _open(provider, phone: true),
            child: Text(
              context.tr(
                provider.phone == '211' ? 'Call 211' : 'Call organization',
              ),
            ),
          ),
        TextButton(
          onPressed: _opening ? null : () => _open(provider),
          child: Text(context.tr(referralWebsiteLabel(provider))),
        ),
        TextButton(
          onPressed: _planNeeded,
          child: Text(context.tr('Save contact')),
        ),
        TextButton(
          onPressed: _planNeeded,
          child: Text(context.tr('Add follow-up')),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final body = SafeArea(
      child: SahContent(
        child: ListView(
          padding: widget.embedded
              ? sahFloatingContentPadding(context)
              : const EdgeInsets.all(16),
          children: [
            Text(
              context.tr(
                'Browse official referral routes in all 50 states and DC. Local listings, program checks and draft forms have separate coverage.',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              context.tr(
                'Create or open a plan to save contacts and add follow-ups.',
              ),
            ),
            const SizedBox(height: 12),
            ReferralLocationEditor(
              onConfirm: (location) => setState(() => _location = location),
            ),
            if (_location != null)
              Text(
                context.tr('Confirmed location: {location}', {
                  'location': referralLocationLabel(_location!),
                }),
              ),
            if (_error != null)
              SahNotice(
                message: context.tr(_error!),
                tone: SahNoticeTone.warning,
              ),
            if (_opening) const LinearProgressIndicator(),
            const NationwideHelpNotice(),
            ReferralCoverageSummary(
              directory: widget.directory,
              stateCode: _location?.stateCode,
              now: widget.now?.call() ?? DateTime.now(),
            ),
            for (final kind in [
              ReferralProviderKind.nationalLocator,
              ReferralProviderKind.referralContact,
              ReferralProviderKind.programReferral,
            ]) ...[
              ReferralSectionHeading(label: referralKindHeading(kind)),
              for (final provider in widget.directory.providers.where(
                (p) =>
                    p.providerKind == kind &&
                    (p.isLocator ||
                        _location?.stateCode != null &&
                            p.stateCodes.contains(_location!.stateCode)),
              ))
                _card(provider),
            ],
            ProviderSearchSection(
              directory: widget.directory,
              confirmedStateCode: _location?.stateCode,
              confirmedCounty: _location?.county,
              confirmedCountyFips: _location?.countyFips,
              providerCard: _card,
            ),
          ],
        ),
      ),
    );
    return widget.embedded
        ? body
        : Scaffold(
            appBar: AppBar(title: Text(context.tr('Find help nationwide'))),
            body: body,
          );
  }
}

class ReferralSectionHeading extends StatelessWidget {
  const ReferralSectionHeading({super.key, required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Semantics(
      header: true,
      child: Text(
        context.tr(label),
        style: Theme.of(context).textTheme.titleLarge,
      ),
    ),
  );
}

String referralKindHeading(ReferralProviderKind kind) => switch (kind) {
  ReferralProviderKind.organization => 'Reviewed organizations',
  ReferralProviderKind.nationalLocator => 'National locators',
  ReferralProviderKind.referralContact => 'Referral contacts',
  ReferralProviderKind.programReferral => 'Program research and preparation',
};

String referralWebsiteLabel(ReferralProvider p) => switch (p.id) {
  'referral-211-national' => 'Find my local 211',
  'referral-rebuilding-together-national' =>
    'Find a Rebuilding Together affiliate',
  'referral-eldercare-national' => 'Open Eldercare Locator',
  _ => 'Open official website',
};

String referralLocationLabel(HelpLocation location) => [
  location.city,
  location.county,
  if (location.stateCode != null)
    referralState(location.stateCode)?.name ?? location.stateCode!,
  location.zip ?? '',
].where((v) => v.isNotEmpty).join(', ');

class NationwideHelpNotice extends StatelessWidget {
  const NationwideHelpNotice({super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr(
            'Listings work offline. Opening websites needs a connection. Your location and plan details are not sent in these links.',
          ),
        ),
        const SizedBox(height: 8),
        Text(
          context.tr(
            'No reviewed local listing does not mean no help exists. Ask an official locator who serves your address.',
          ),
        ),
        const SizedBox(height: 8),
        Text(
          context.tr(
            'Program research is preparation only. It does not check eligibility, generate an official form or submit an application.',
          ),
        ),
      ],
    ),
  );
}

/// No GPS request or geographic guessing. In particular, an old county name is
/// preserved without treating it as California.
class ReferralLocationEditor extends StatefulWidget {
  const ReferralLocationEditor({
    super.key,
    this.initialLocation,
    required this.onConfirm,
    this.busy = false,
  });
  final HelpLocation? initialLocation;
  final void Function(HelpLocation) onConfirm;
  final bool busy;
  @override
  State<ReferralLocationEditor> createState() => _ReferralLocationEditorState();
}

class _ReferralLocationEditorState extends State<ReferralLocationEditor>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  final _form = GlobalKey<FormState>();
  late final _city = TextEditingController(
    text: widget.initialLocation?.city ?? '',
  );
  late final _county = TextEditingController(
    text: widget.initialLocation?.county ?? '',
  );
  late final _zip = TextEditingController(
    text: widget.initialLocation?.zip ?? '',
  );
  late String? _state = widget.initialLocation?.stateCode;
  @override
  void dispose() {
    _city.dispose();
    _county.dispose();
    _zip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ReferralSectionHeading(label: 'Confirm your location'),
          DropdownButtonFormField<String>(
            key: const ValueKey('help-location-state'),
            initialValue: _state,
            isExpanded: true,
            itemHeight: null,
            decoration: InputDecoration(labelText: context.tr('State or DC')),
            items: [
              for (final state in usStates)
                DropdownMenuItem(value: state.code, child: Text(state.name)),
            ],
            onChanged: widget.busy
                ? null
                : (value) => setState(() => _state = value),
            validator: (value) => referralState(value)?.routingSupported == true
                ? null
                : context.tr('Choose your state or DC. No GPS is needed.'),
          ),
          TextFormField(
            controller: _city,
            enabled: !widget.busy,
            maxLength: 100,
            decoration: InputDecoration(
              labelText: context.tr('City (optional)'),
            ),
          ),
          TextFormField(
            controller: _county,
            enabled: !widget.busy,
            maxLength: 100,
            decoration: InputDecoration(
              labelText: context.tr('County (optional)'),
            ),
          ),
          TextFormField(
            controller: _zip,
            enabled: !widget.busy,
            maxLength: 10,
            keyboardType: TextInputType.text,
            decoration: InputDecoration(
              labelText: context.tr('ZIP code (optional)'),
            ),
            validator: (value) =>
                value!.trim().isEmpty ||
                    RegExp(r'^[0-9]{5}(-[0-9]{4})?$').hasMatch(value.trim())
                ? null
                : context.tr('Enter a 5-digit ZIP or ZIP+4.'),
          ),
          FilledButton(
            onPressed: widget.busy
                ? null
                : () {
                    if (_form.currentState!.validate()) {
                      FocusScope.of(context).unfocus();
                      widget.onConfirm(
                        HelpLocation(
                          stateCode: _state,
                          city: _city.text.trim(),
                          county: _county.text.trim(),
                          zip: _zip.text.trim().isEmpty
                              ? null
                              : _zip.text.trim(),
                        ),
                      );
                    }
                  },
            child: Text(context.tr('Confirm location')),
          ),
          const SizedBox(height: 8),
          Text(
            context.tr(
              'Unknown location? Use the national locators. Location is not sent to these websites.',
            ),
          ),
          Text(
            context.tr(
              'Territory and Tribal service routes need separate review. Use the official locators to ask about your location.',
            ),
          ),
        ],
      ),
    );
  }
}

class NationwideReferralCard extends StatelessWidget {
  const NationwideReferralCard({
    super.key,
    required this.provider,
    required this.now,
    required this.actions,
    this.location,
  });
  final ReferralProvider provider;
  final DateTime now;
  final HelpLocation? location;
  final Widget actions;
  @override
  Widget build(BuildContext context) {
    final p = provider;
    final coverage = p.coverage(
      location?.county,
      now,
      stateCode: location?.stateCode,
      countyFips: location?.countyFips,
      city: location?.city,
      zip: location?.zip,
    );
    final date = MaterialLocalizations.of(
      context,
    ).formatMediumDate(DateTime.parse(p.reviewedOn));
    final details = <Widget>[
      Text(
        context.tr(
          coverage == ReferralCoverage.locator
              ? 'National locator: ask who serves your address.'
              : coverage == ReferralCoverage.listedCounty
              ? 'Listed for this county; confirm address coverage.'
              : 'Coverage unknown: contact to confirm.',
        ),
      ),
      if (p.stateCodes.isNotEmpty && !p.isLocator)
        Text(
          p.stateCodes.length == usStates.length &&
                  usStates.every((state) => p.stateCodes.contains(state.code))
              ? context.tr('National program route; requirements vary.')
              : p.stateCodes
                    .map((code) => referralState(code)?.name ?? code)
                    .join(', '),
        ),
      if (p.counties.isNotEmpty) Text(p.counties.join(', ')),
      if (p.cities.isNotEmpty) Text(p.cities.join(', ')),
      if (p.areaNote != null) Text(context.tr(p.areaNote!)),
      if (p.availability != ReferralAvailability.closed)
        Text(context.tr('Intake and repair availability unknown.')),

      Text(
        context.tr('Review due {date}', {
          'date': MaterialLocalizations.of(
            context,
          ).formatMediumDate(DateTime.parse(p.reviewAfter)),
        }),
      ),
      if (p.phone != null)
        SelectableText(p.phone!, key: PageStorageKey('referral-phone-${p.id}')),
      SelectableText(
        p.website,
        key: PageStorageKey('referral-website-${p.id}'),
      ),
      ExpansionTile(
        key: PageStorageKey('referral-sources-${p.id}'),
        title: Text(context.tr('Official sources')),
        children: [
          for (final source in p.sources)
            Padding(
              padding: const EdgeInsets.all(8),
              child: SelectableText(
                source,
                key: PageStorageKey('referral-source-${p.id}-$source'),
              ),
            ),
        ],
      ),
    ];
    return Card(
      key: ValueKey(p.id),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(p.name, style: Theme.of(context).textTheme.titleMedium),
            Text(context.tr(referralKindHeading(p.providerKind))),
            Text(context.tr(p.description)),
            Text(context.tr('Reviewed {date}', {'date': date})),
            Text(p.roles.map((role) => context.tr(role.label)).join(' · ')),
            if (p.services.isNotEmpty)
              Text(p.services.map((s) => context.tr(s.label)).join(' · ')),
            if (p.availability == ReferralAvailability.closed)
              Text(context.tr('Intake closed: ask about alternatives.')),
            if (p.needsReview(now))
              Text(context.tr('Listing needs review. Contact to confirm.')),
            if (p.isLocator ||
                p.providerKind == ReferralProviderKind.programReferral)
              ExpansionTile(
                key: PageStorageKey('referral-details-${p.id}'),
                title: Text(context.tr('Coverage and source details')),
                children: details,
              )
            else
              ...details,
            actions,
          ],
        ),
      ),
    );
  }
}
