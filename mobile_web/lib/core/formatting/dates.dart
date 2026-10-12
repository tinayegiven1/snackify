const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "2026-10-12" (the API's date format) -> "12 Oct 2026".
String formatApiDate(String apiDate) {
  final date = DateTime.parse(apiDate);
  return '${date.day} ${_months[date.month - 1]} ${date.year}';
}

/// A calendar date -> "2026-10-12" for the API.
String toApiDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// Today's date on this device, without a time. The server checks dates against the
/// business's own time zone as well.
DateTime today() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

/// A period with both dates included -> "5 Oct – 11 Oct 2026" (the year once when both
/// dates share it), or "12 Oct 2026" for a single day.
String formatApiPeriod(String from, String to) {
  if (from == to) return formatApiDate(from);
  final start = DateTime.parse(from);
  final end = formatApiDate(to);
  if (start.year != DateTime.parse(to).year) return '${formatApiDate(from)} – $end';
  return '${start.day} ${_months[start.month - 1]} – $end';
}
