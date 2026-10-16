enum ReferralAvailability { unknown, closed }

enum ReferralCoverage { locator, listedCounty, unknown }

enum ReferralService {
  homeRepair('Home repairs'),
  accessibility('Accessibility modifications'),
  coordination('Service coordination');

  const ReferralService(this.label);
  final String label;
}

class ReferralProvider {
  const ReferralProvider({
    required this.id,
    required this.name,
    required this.description,
    required this.website,
    required this.sources,
    required this.reviewedOn,
    required this.reviewAfter,
    this.phone,
    this.counties = const [],
    this.isLocator = false,
    this.availability = ReferralAvailability.unknown,
    this.services = const [],
    this.cities = const [],
    this.areaNote,
  });
  final String id, name, description, website, reviewedOn, reviewAfter;
  final List<String> sources, counties;
  final String? phone;
  final bool isLocator;
  final ReferralAvailability availability;
  final List<ReferralService> services;
  final List<String> cities;
  final String? areaNote;
  bool get isLocalProvider => !isLocator && services.isNotEmpty;

  bool needsReview(DateTime now) => !DateTime(
    now.year,
    now.month,
    now.day,
  ).isBefore(DateTime.parse(reviewAfter));
  bool listsCounty(String? county) =>
      county != null &&
      counties.any(
        (c) => normalizeReferralCounty(c) == normalizeReferralCounty(county),
      );
  ReferralCoverage coverage(String? county, DateTime now) => isLocator
      ? ReferralCoverage.locator
      : !needsReview(now) && listsCounty(county)
      ? ReferralCoverage.listedCounty
      : ReferralCoverage.unknown;
}

String normalizeReferralCounty(String county) =>
    county.trim().toLowerCase().replaceFirst(RegExp(r'\s+county$'), '');

abstract interface class ReferralDirectory {
  List<ReferralProvider> get providers;
  ReferralProvider? provider(String id);
}

class OfficialReferralDirectory implements ReferralDirectory {
  const OfficialReferralDirectory();
  @override
  List<ReferralProvider> get providers => const [
    ...officialReferrals,
    ...localProviderCatalog,
  ];
  @override
  ReferralProvider? provider(String id) =>
      providers.where((p) => p.id == id).firstOrNull;
}

const referralCounties = [
  'Marin',
  'Napa',
  'San Francisco',
  'San Mateo',
  'Santa Clara',
  'Solano',
];
const officialReferrals = [
  ReferralProvider(
    id: 'referral-211-national',
    name: '211',
    description: 'Ask about local home repair and community services.',
    website: 'https://211.org/about-us/your-local-211',
    phone: '211',
    isLocator: true,
    sources: ['https://211.org/about-us/your-local-211'],
    reviewedOn: '2026-10-24',
    reviewAfter: '2026-11-23',
  ),
  ReferralProvider(
    id: 'referral-rebuilding-together-national',
    name: 'Rebuilding Together',
    description: 'Find a Rebuilding Together affiliate',
    website: 'https://rebuildingtogether.org/find-your-local-affiliate',
    isLocator: true,
    sources: ['https://rebuildingtogether.org/find-your-local-affiliate'],
    reviewedOn: '2026-10-24',
    reviewAfter: '2026-11-23',
  ),
  ReferralProvider(
    id: 'referral-211-bay-area',
    name: '211 Bay Area',
    description: 'Ask about local home repair and community services.',
    website: 'https://211bayarea.org/contact/',
    phone: '8002736222',
    counties: referralCounties,
    sources: [
      'https://211bayarea.org/about-211-bay-area/',
      'https://211bayarea.org/contact/',
    ],
    reviewedOn: '2026-10-24',
    reviewAfter: '2026-11-23',
  ),
];

const localProviderCatalogVersion = 'bay-area-2026-10-25-v2';
const localProviderCatalog = [
  ReferralProvider(
    id: 'provider-rebuilding-together-silicon-valley',
    name: 'Rebuilding Together Silicon Valley',
    description:
        'Home repairs and safety modifications in selected Santa Clara County communities.',
    website: 'https://rebuildingtogethersv.org/apply/',
    phone: '4085789519',
    counties: ['Santa Clara'],
    cities: [
      'Alviso',
      'Campbell',
      'Cupertino',
      'Gilroy',
      'Los Gatos',
      'Milpitas',
      'Morgan Hill',
      'San Jose',
      'San Martin',
      'Santa Clara',
      'Saratoga',
      'Sunnyvale',
    ],
    services: [ReferralService.homeRepair, ReferralService.accessibility],
    areaNote:
        'Only selected cities are listed. Funding and project selection are limited.',
    sources: [
      'https://rebuildingtogethersv.org/apply/',
      'https://rebuildingtogethersv.org/programs/',
    ],
    reviewedOn: '2026-10-24',
    reviewAfter: '2026-11-23',
  ),
  ReferralProvider(
    id: 'provider-rebuilding-together-san-francisco',
    name: 'Rebuilding Together San Francisco',
    description:
        'Home repair and renovation programs for San Francisco homeowners and renters.',
    website: 'https://rebuildingtogethersf.org/apply/',
    phone: '4159051611',
    counties: ['San Francisco'],
    services: [ReferralService.homeRepair],
    sources: [
      'https://rebuildingtogethersf.org/',
      'https://rebuildingtogethersf.org/apply/',
    ],
    reviewedOn: '2026-10-24',
    reviewAfter: '2026-11-23',
  ),
  ReferralProvider(
    id: 'provider-habitat-greater-san-francisco',
    name: 'Habitat for Humanity Greater San Francisco',
    description:
        'Home repairs and accessibility improvements with financing options.',
    website: 'https://habitatgsf.org/home-repair-work/',
    phone: '4156251000',
    counties: ['Marin', 'San Francisco', 'San Mateo'],
    cities: ['Menlo Park', 'Redwood City', 'Foster City'],
    services: [ReferralService.homeRepair, ReferralService.accessibility],
    areaNote:
        'Programs vary by city and property type. Marin is fully subscribed at review; ask about future opportunities. Repairs may involve a loan.',
    sources: ['https://habitatgsf.org/home-repair-work/'],
    reviewedOn: '2026-10-24',
    reviewAfter: '2026-11-23',
  ),
  ReferralProvider(
    id: 'provider-cid-san-mateo',
    name: 'Center for Independence of Individuals with Disabilities (CID)',
    description:
        'Assistive technology advice and home modification resource coordination.',
    website: 'https://www.cidsanmateo.org/services/assistive-technology.php',
    phone: '6506451780',
    counties: ['San Mateo'],
    services: [ReferralService.coordination],
    areaNote:
        'Resource coordination does not mean this organization performs repairs.',
    sources: [
      'https://www.cidsanmateo.org/services/',
      'https://www.cidsanmateo.org/services/assistive-technology.php',
      'https://www.cidsanmateo.org/about/',
    ],
    reviewedOn: '2026-10-24',
    reviewAfter: '2026-11-23',
  ),
  ReferralProvider(
    id: 'provider-habitat-east-bay-silicon-valley',
    name: 'Habitat for Humanity East Bay/Silicon Valley',
    description:
        'Home repairs and accessibility improvements in selected East Bay and Santa Clara County communities.',
    website: 'https://www.habitatebsv.org/services/home-repair',
    phone: '5108033388',
    counties: ['Alameda', 'Contra Costa', 'Santa Clara'],
    services: [ReferralService.homeRepair, ReferralService.accessibility],
    areaNote:
        'Only selected cities are served. Ask about your address, funding and any loan terms.',
    sources: [
      'https://www.habitatebsv.org/services/home-repair',
      'https://www.habitatebsv.org/blog/home-repair-program',
      'https://www.achhd.org/programs/housing-rehab/index.htm',
    ],
    reviewedOn: '2026-10-25',
    reviewAfter: '2026-11-24',
  ),
  ReferralProvider(
    id: 'provider-rebuilding-together-petaluma',
    name: 'Rebuilding Together Petaluma',
    description:
        'Home repairs and safety modifications in selected Sonoma County communities.',
    website: 'https://rtpetaluma.org/apply/',
    phone: '7077653944',
    counties: ['Sonoma'],
    cities: [
      'Petaluma',
      'Bodega Bay',
      'Boyes Hot Springs',
      'Cazadero',
      'Cloverdale',
      'El Verano',
      'Forestville',
      'Freestone',
      'Glen Ellen',
      'Guerneville',
      'Healdsburg',
      'Monte Rio',
      'Occidental',
      'Rio Nido',
      'Sebastopol',
      'Sonoma',
      'Valley Ford',
      'Windsor',
    ],
    services: [ReferralService.homeRepair, ReferralService.accessibility],
    areaNote:
        'Selected Sonoma County communities only; confirm address coverage, funding and project selection.',
    sources: [
      'https://rtpetaluma.org/apply/',
      'https://rtpetaluma.org/programs/',
    ],
    reviewedOn: '2026-10-25',
    reviewAfter: '2026-11-24',
  ),
  ReferralProvider(
    id: 'provider-rebuilding-together-solano-county',
    name: 'Rebuilding Together Solano County',
    description:
        'Home rehabilitation and safety repairs for selected Solano County homeowners.',
    website: 'https://rebuildingtogethersolanocounty.org/services/',
    phone: '7075809360',
    counties: ['Solano'],
    services: [ReferralService.homeRepair],
    areaNote:
        'The published veteran application deadline was April 30, 2026. Ask about current programs and address coverage.',
    sources: [
      'https://rebuildingtogethersolanocounty.org/services/',
      'https://rebuildingtogethersolanocounty.org/contacts/',
      'https://rebuildingtogethersolanocounty.org/faqs/',
    ],
    reviewedOn: '2026-10-25',
    reviewAfter: '2026-11-24',
  ),
  ReferralProvider(
    id: 'provider-marin-center-independent-living',
    name: 'Marin Center for Independent Living',
    description:
        'Home accessibility modifications and assistive technology support in Marin County.',
    website: 'https://www.marincil.org/services/',
    phone: '4154596245',
    counties: ['Marin'],
    services: [ReferralService.accessibility, ReferralService.coordination],
    areaNote:
        'Ask for the home modifications team to discuss ramps, grab bars and available support.',
    sources: ['https://www.marincil.org/services/'],
    reviewedOn: '2026-10-25',
    reviewAfter: '2026-11-24',
  ),
  ReferralProvider(
    id: 'provider-napa-housing-rehabilitation',
    name: 'City of Napa Housing Rehabilitation',
    description:
        'Home repair and accessibility program assistance in Napa County cities.',
    website: 'https://www.cityofnapa.org/204/Housing-Rehabilitation',
    phone: '7072579642',
    counties: ['Napa'],
    cities: [
      'Napa',
      'American Canyon',
      'Calistoga',
      'St. Helena',
      'Yountville',
    ],
    services: [
      ReferralService.homeRepair,
      ReferralService.accessibility,
      ReferralService.coordination,
    ],
    areaNote:
        'City programs differ. Ask the Housing Division about loans, grants and construction management; this is not a contractor booking.',
    sources: ['https://www.cityofnapa.org/204/Housing-Rehabilitation'],
    reviewedOn: '2026-10-25',
    reviewAfter: '2026-11-24',
  ),
  ReferralProvider(
    id: 'provider-cil-residential-access',
    name: 'Center for Independent Living — Residential Access',
    description:
        'Home accessibility modifications in Berkeley and consultations in nearby Alameda County cities.',
    website: 'https://thecil.org/residential-access/',
    phone: '5108414776',
    counties: ['Alameda'],
    cities: [
      'Berkeley',
      'Oakland',
      'Alameda',
      'Emeryville',
      'Piedmont',
      'Albany',
    ],
    services: [ReferralService.accessibility, ReferralService.coordination],
    areaNote:
        'Funded modifications are limited to Berkeley. The other listed cities receive consultations with more limited support.',
    sources: ['https://thecil.org/residential-access/'],
    reviewedOn: '2026-10-25',
    reviewAfter: '2026-11-24',
  ),
  ReferralProvider(
    id: 'provider-alameda-county-healthy-homes',
    name: 'Alameda County Healthy Homes — Minor Home Repair',
    description:
        'Minor home repairs and safety modifications in selected Alameda County communities.',
    website: 'https://www.achhd.org/programs/housing-rehab/index.htm',
    phone: '5105678280',
    counties: ['Alameda'],
    cities: [
      'Albany',
      'Dublin',
      'Emeryville',
      'Oakland',
      'Newark',
      'Union City',
      'Ashland',
      'Cherryland',
      'Castro Valley',
      'Hayward Acres',
      'Hillcrest Knolls',
      'Fairview',
      'San Lorenzo',
      'Sunol',
    ],
    services: [ReferralService.homeRepair, ReferralService.accessibility],
    areaNote:
        'Selected communities only. Oakland has a waiting list; Union City is awaiting funding. Confirm current restrictions directly.',
    sources: ['https://www.achhd.org/programs/housing-rehab/index.htm'],
    reviewedOn: '2026-10-25',
    reviewAfter: '2026-11-24',
  ),
  ReferralProvider(
    id: 'provider-habitat-sonoma-county',
    name: 'Habitat for Humanity of Sonoma County',
    description:
        'Sonoma County home repair program contact; repair requests are not being accepted at review.',
    website: 'https://habitatsoco.org/contact/',
    phone: '7075787707',
    counties: ['Sonoma'],
    services: [ReferralService.homeRepair],
    availability: ReferralAvailability.closed,
    areaNote:
        'Home repair intake is closed at review. Ask about future openings or use another listed organization.',
    sources: ['https://habitatsoco.org/contact/'],
    reviewedOn: '2026-10-25',
    reviewAfter: '2026-11-24',
  ),
];

Uri referralDestination(ReferralProvider provider, {bool phone = false}) {
  if (phone) {
    final number = provider.phone;
    if (number == null || !RegExp(r'^\+?[0-9]{3,15}$').hasMatch(number)) {
      throw const FormatException('Invalid referral phone.');
    }
    return Uri(scheme: 'tel', path: number);
  }
  final uri = Uri.parse(provider.website);
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException('Invalid referral destination.');
  }
  return uri;
}
