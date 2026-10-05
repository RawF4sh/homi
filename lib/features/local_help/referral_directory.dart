enum ReferralAvailability { unknown, closed }

enum ReferralCoverage { locator, listedCounty, unknown }

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
  });
  final String id, name, description, website, reviewedOn, reviewAfter;
  final List<String> sources, counties;
  final String? phone;
  final bool isLocator;
  final ReferralAvailability availability;

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
  List<ReferralProvider> get providers => officialReferrals;
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
