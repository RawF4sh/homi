import 'referral_directory.dart';

List<ReferralProvider> searchLocalProviders(
  ReferralDirectory directory, {
  String query = '',
  String? county,
  ReferralService? service,
  String Function(String)? translate,
}) {
  final words = _normalize(query).split(' ').where((w) => w.isNotEmpty);
  final results = directory.providers.where((p) {
    if (!p.isLocalProvider ||
        county != null && county.trim().isNotEmpty && !p.listsCounty(county) ||
        service != null && !p.services.contains(service)) {
      return false;
    }
    final searchable = _normalize(
      [
        p.name,
        p.description,
        if (translate != null) translate(p.description),
        ...p.counties,
        ...p.cities,
        for (final s in p.services) ...[
          s.label,
          if (translate != null) translate(s.label),
        ],
      ].join(' '),
    );
    return words.every(searchable.contains);
  }).toList();
  results.sort((a, b) {
    final name = _normalize(a.name).compareTo(_normalize(b.name));
    return name == 0 ? a.id.compareTo(b.id) : name;
  });
  return List.unmodifiable(results);
}

String _normalize(String value) => value
    .toLowerCase()
    .replaceAll(RegExp('[áàâäãå]'), 'a')
    .replaceAll(RegExp('[éèêë]'), 'e')
    .replaceAll(RegExp('[íìîï]'), 'i')
    .replaceAll(RegExp('[óòôöõ]'), 'o')
    .replaceAll(RegExp('[úùûü]'), 'u')
    .replaceAll('ñ', 'n')
    .replaceAll('ç', 'c')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();
