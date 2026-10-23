import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'provider_search.dart';
import 'referral_directory.dart';

class ProviderSearchSection extends StatefulWidget {
  const ProviderSearchSection({
    super.key,
    required this.directory,
    required this.providerCard,
    this.confirmedCounty,
    this.confirmedStateCode,
    this.confirmedCountyFips,
    this.showHeading = true,
  });
  final ReferralDirectory directory;
  final String? confirmedCounty, confirmedStateCode, confirmedCountyFips;
  final bool showHeading;
  final Widget Function(ReferralProvider) providerCard;

  @override
  State<ProviderSearchSection> createState() => _ProviderSearchSectionState();
}

class _ProviderSearchSectionState extends State<ProviderSearchSection>
    with AutomaticKeepAliveClientMixin {
  final _query = TextEditingController();
  String? _county;
  String? _stateCode;
  ReferralService? _service;
  ReferralRole? _role;
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _stateCode = widget.confirmedStateCode;
    _county = _confirmedCounty();
  }

  String? _confirmedCounty() {
    final value = widget.confirmedCounty;
    if (value == null || value.trim().isEmpty) return null;
    return widget.directory.providers
            .expand((p) => p.counties)
            .where(
              (c) =>
                  normalizeReferralCounty(c) == normalizeReferralCounty(value),
            )
            .firstOrNull ??
        value.trim();
  }

  @override
  void didUpdateWidget(covariant ProviderSearchSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.confirmedCounty != widget.confirmedCounty ||
        oldWidget.confirmedStateCode != widget.confirmedStateCode) {
      _stateCode = widget.confirmedStateCode;
      _county = _confirmedCounty();
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final counties = <String>{
      for (final p in widget.directory.providers.where(
        (p) =>
            p.isLocalProvider &&
            (_stateCode == null || p.stateCodes.contains(_stateCode)),
      ))
        ...p.counties,
      ?_county,
    }.toList()..sort();
    final results = searchLocalProviders(
      widget.directory,
      query: _query.text,
      county: _county,
      stateCode: _stateCode,
      countyFips:
          _county == widget.confirmedCounty &&
              _stateCode == widget.confirmedStateCode
          ? widget.confirmedCountyFips
          : null,
      service: _service,
      role: _role,
      translate: (s) => context.tr(s),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 20),
        if (widget.showHeading)
          Semantics(
            header: true,
            child: Text(
              context.tr('Search local providers'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
        Text(
          context.tr(
            'Reviewed listings are available offline. Search by state, organization, city, county or service. A listing does not confirm address eligibility or current availability.',
          ),
        ),
        DropdownButtonFormField<String>(
          key: ValueKey('provider-state-${_stateCode ?? ''}'),
          initialValue: _stateCode ?? '',
          isExpanded: true,
          itemHeight: null,
          decoration: InputDecoration(labelText: context.tr('State or DC')),
          items: [
            DropdownMenuItem(
              value: '',
              child: Text(context.tr('All listed states')),
            ),
            for (final state in usStates)
              DropdownMenuItem(value: state.code, child: Text(state.name)),
          ],
          onChanged: (value) => setState(() {
            _stateCode = value == '' ? null : value;
            _county = null;
          }),
        ),
        TextField(
          key: const ValueKey('provider-search-query'),
          controller: _query,
          maxLength: 100,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            labelText: context.tr('Search providers'),
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => FocusScope.of(context).unfocus(),
        ),
        DropdownButtonFormField<String>(
          key: ValueKey('provider-county-${_county ?? ''}'),
          initialValue: _county ?? '',
          isExpanded: true,
          itemHeight: null,
          decoration: InputDecoration(labelText: context.tr('Listed county')),
          items: [
            DropdownMenuItem(
              value: '',
              child: Text(context.tr('All listed counties')),
            ),
            for (final county in counties)
              DropdownMenuItem(value: county, child: Text(county)),
          ],
          onChanged: (value) =>
              setState(() => _county = value == '' ? null : value),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey('provider-service-${_service?.name ?? ''}'),
          initialValue: _service?.name ?? '',
          isExpanded: true,
          itemHeight: null,
          decoration: InputDecoration(labelText: context.tr('Service type')),
          items: [
            DropdownMenuItem(
              value: '',
              child: Text(context.tr('All services')),
            ),
            for (final service in ReferralService.values)
              DropdownMenuItem(
                value: service.name,
                child: Text(context.tr(service.label)),
              ),
          ],
          onChanged: (value) => setState(
            () => _service = ReferralService.values
                .where((s) => s.name == value)
                .firstOrNull,
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey('provider-role-${_role?.name ?? ''}'),
          initialValue: _role?.name ?? '',
          isExpanded: true,
          itemHeight: null,
          decoration: InputDecoration(
            labelText: context.tr('Organization role'),
          ),
          items: [
            DropdownMenuItem(value: '', child: Text(context.tr('All roles'))),
            for (final role in ReferralRole.values)
              DropdownMenuItem(
                value: role.name,
                child: Text(context.tr(role.label)),
              ),
          ],
          onChanged: (value) => setState(
            () => _role = ReferralRole.values
                .where((r) => r.name == value)
                .firstOrNull,
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: () => setState(() {
              FocusScope.of(context).unfocus();
              _query.clear();
              _county = null;
              _stateCode = null;
              _service = null;
              _role = null;
            }),
            child: Text(context.tr('Clear search and filters')),
          ),
        ),
        Semantics(
          liveRegion: true,
          child: Text(
            context.tr('Providers found: {count}', {
              'count': '${results.length}',
            }),
          ),
        ),
        if (results.isEmpty)
          Text(
            context.tr(
              'No providers match these filters. Clear the filters or use the official locators below to ask who serves your address.',
            ),
          ),
        for (final p in results)
          Card(
            child: ExpansionTile(
              key: ValueKey('provider-result-${p.id}'),
              title: Text(p.name),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.services.map((s) => context.tr(s.label)).join(' · ')),
                  if (p.availability == ReferralAvailability.closed)
                    Text(context.tr('Intake closed: ask about alternatives.')),
                ],
              ),
              children: [widget.providerCard(p)],
            ),
          ),
      ],
    );
  }
}
