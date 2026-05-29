bool isSubscriptionActiveNow(
  Map<dynamic, dynamic> row, {
  DateTime? now,
}) {
  final status = (row['status']?.toString() ?? '').toLowerCase();
  if (status != 'active' && status != 'trialing') {
    return false;
  }

  final periodEnd = _parseDateTime(row['current_period_end']);
  if (periodEnd == null) {
    return false;
  }

  final nowUtc = (now ?? DateTime.now()).toUtc();
  if (!nowUtc.isBefore(periodEnd.toUtc())) {
    return false;
  }

  final periodStart = _parseDateTime(row['current_period_start']);
  if (periodStart != null && nowUtc.isBefore(periodStart.toUtc())) {
    return false;
  }

  return true;
}

Map<String, dynamic>? firstActiveSubscriptionRow(
  Iterable<Map<dynamic, dynamic>> rows, {
  DateTime? now,
}) {
  for (final row in rows) {
    if (isSubscriptionActiveNow(row, now: now)) {
      return Map<String, dynamic>.from(row);
    }
  }
  return null;
}

DateTime? _parseDateTime(Object? value) {
  final raw = value?.toString();
  if (raw == null || raw.isEmpty) {
    return null;
  }
  return DateTime.tryParse(raw);
}
