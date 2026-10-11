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

const localProviderCatalogVersion = 'bay-area-2026-10-24-v1';
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
