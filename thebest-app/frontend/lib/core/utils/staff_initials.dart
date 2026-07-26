/// Avatar label for a staff member.
///
/// Staff are named `12 - Alex` or `(12) Alex`, so the leading
/// number is the identifier people actually recognise — use it as the avatar
/// label and drop any brackets/separator. Falls back to name initials when the
/// name carries no leading number.
String staffInitials(String name, {String fallback = '?'}) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return fallback;

  final numbered = RegExp(r'^\(?\s*(\d+)\s*\)?\s*[-–—:.]?\s+').firstMatch(trimmed);
  if (numbered != null) return numbered.group(1)!;

  final parts = trimmed
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) return fallback;
  if (parts.length == 1) return parts.first[0].toUpperCase();
  return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
}
