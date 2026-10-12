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
