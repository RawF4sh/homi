/// USPS 3-digit ZIP prefix allocation (public), written for this project and
/// reviewed 2026-10-26. A ZIP only suggests the state to fill in; the person can
/// always correct it, and nothing here infers a county, city or eligibility.
///
/// Gaps are deliberate: unallocated prefixes, military APO/FPO (AA/AE/AP) and
/// 969 (shared by Guam, Northern Mariana Islands, Palau, Micronesia and the
/// Marshall Islands) return null so the person is asked for the state.
// ponytail: a few unused prefixes inside a state's run resolve to that state;
// no real ZIP uses them. Swap for a USPS-published table if one is adopted.
const _prefixRuns = <String, String>{
  'NY': '005 100-149',
  'PR': '006-007 009',
  'VI': '008',
  'MA': '010-027 055',
  'RI': '028-029',
  'NH': '030-038',
  'ME': '039-049',
  'VT': '050-054 056-059',
  'CT': '060-069',
  'NJ': '070-089',
  'PA': '150-196',
  'DE': '197-199',
  'DC': '200 202-205 569',
  'VA': '201 220-246',
  'MD': '206-212 214-219',
  'WV': '247-268',
  'NC': '270-289',
  'SC': '290-299',
  'GA': '300-319 398-399',
  'FL': '320-339 341-342 344 346-347 349',
  'AL': '350-369',
  'TN': '370-385',
  'MS': '386-397',
  'KY': '400-427',
  'OH': '430-459',
  'IN': '460-479',
  'MI': '480-499',
  'IA': '500-516 520-528',
  'WI': '530-532 534-535 537-549',
  'MN': '550-551 553-567',
  'SD': '570-577',
  'ND': '580-588',
  'MT': '590-599',
  'IL': '600-620 622-629',
  'MO': '630-631 633-641 644-658',
  'KS': '660-662 664-679',
  'NE': '680-681 683-693',
  'LA': '700-714',
  'AR': '716-729',
  'OK': '730-731 734-749',
  'TX': '733 750-770 772-799 885',
  'CO': '800-816',
  'WY': '820-831',
  'ID': '832-838',
  'UT': '840-847',
  'AZ': '850-853 855-857 859-860 863-865',
  'NM': '870-884',
  'NV': '889-891 893-895 897-898',
  'CA': '900-908 910-928 930-961',
  'HI': '967-968',
  'OR': '970-979',
  'WA': '980-986 988-994',
  'AK': '995-999',
};

/// Whole ZIPs that differ from their prefix's state.
const _zipExceptions = {'96799': 'AS'};

final _prefixState = () {
  final table = <String, String>{};
  for (final MapEntry(key: state, value: runs) in _prefixRuns.entries) {
    for (final run in runs.split(' ')) {
      final [start, end] = run.contains('-')
          ? run.split('-').map(int.parse).toList()
          : [int.parse(run), int.parse(run)];
      for (var p = start; p <= end; p++) {
        final prefix = '$p'.padLeft(3, '0');
        assert(!table.containsKey(prefix), 'Overlapping prefix $prefix');
        table[prefix] = state;
      }
    }
  }
  return table;
}();

/// The state or territory code for a 5-digit ZIP or ZIP+4, or null when the ZIP
/// is malformed or its prefix does not identify one state.
String? stateForZip(String zip) {
  final z = zip.trim();
  if (!RegExp(r'^[0-9]{5}(-[0-9]{4})?$').hasMatch(z)) return null;
  final five = z.substring(0, 5);
  return _zipExceptions[five] ?? _prefixState[five.substring(0, 3)];
}
