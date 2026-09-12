/// Ranks pain-relief options from the user's own history. Pure functions —
/// no I/O, never throw.
///
/// Data model: per relief name, how many times tried and how many times it
/// helped (both accumulated on the daily log). A relief earns a personal
/// verdict only after [minTries] attempts; before that it is listed as
/// untried so the UI can never fabricate a personal claim.
class RankedRelief {
  final String name;
  final int tried;
  final int helped;

  /// True once the user has tried this enough times for a personal verdict.
  bool get hasVerdict => tried >= 2;

  /// "Helped 3 of 4 times" or "Not tried enough yet".
  String get verdict => hasVerdict
      ? 'Helped $helped of $tried times'
      : (tried == 0 ? 'Not tried yet' : 'Tried once — rate it again');

  const RankedRelief(
      {required this.name, required this.tried, required this.helped});
}

/// Fixed safe comfort options. Plain names only — no dosages, no medical
/// advice. The "talk to a doctor" escalation lives in the SOS screen copy.
const sosReliefOptions = [
  'Heat',
  'Rest',
  'Warm tea',
  'Gentle walk',
  'Pain reliever',
  'Breathing',
];

/// Aggregates relief totals across a set of daily-log-like maps. Each map
/// may carry 'reliefTried'/'reliefHelped' string->int maps; corrupt entries
/// are ignored. Pure — shared by the SOS screen and the Relief Playbook
/// so the two can never disagree.
({Map<String, int> tried, Map<String, int> helped}) aggregateReliefs(
    Iterable<Map<String, dynamic>> logs) {
  final tried = <String, int>{};
  final helped = <String, int>{};
  void add(Map<String, int> into, dynamic source) {
    if (source is! Map) return;
    source.forEach((k, v) {
      final key = k.toString().trim();
      final n = v is int ? v : (v is num ? v.toInt() : null);
      if (key.isEmpty || n == null || n <= 0) return;
      into[key] = (into[key] ?? 0) + n;
    });
  }

  for (final log in logs) {
    add(tried, log['reliefTried']);
    add(helped, log['reliefHelped']);
  }
  return (tried: tried, helped: helped);
}

/// Merges per-day maps into totals, then ranks: verdicts first (by help
/// rate, then most tried), then untried options in their canonical order.
List<RankedRelief> rankReliefs({
  required Map<String, int> tried,
  required Map<String, int> helped,
  List<String> options = sosReliefOptions,
}) {
  int count(Map<String, int> m, String name) {
    final v = m[name.trim()];
    return v == null || v < 0 ? 0 : v;
  }

  final ranked = <RankedRelief>[];
  for (final name in options) {
    final t = count(tried, name);
    var h = count(helped, name);
    if (h > t) h = t; // Corrupt data can never claim >100%.
    ranked.add(RankedRelief(name: name, tried: t, helped: h));
  }
  ranked.sort((a, b) {
    if (a.hasVerdict != b.hasVerdict) return a.hasVerdict ? -1 : 1;
    final rateA = a.tried == 0 ? -1.0 : a.helped / a.tried;
    final rateB = b.tried == 0 ? -1.0 : b.helped / b.tried;
    final byRate = rateB.compareTo(rateA);
    if (byRate != 0) return byRate;
    final byTried = b.tried.compareTo(a.tried);
    if (byTried != 0) return byTried;
    return options.indexOf(a.name).compareTo(options.indexOf(b.name));
  });
  return ranked;
}

/// Adds one SOS episode to running totals. Returns the merged maps so
/// callers can persist them onto the daily log.
({Map<String, int> tried, Map<String, int> helped}) recordEpisode({
  required Map<String, int> tried,
  required Map<String, int> helped,
  required List<String> reliefs,
  required bool helpedIt,
}) {
  final nextTried = Map<String, int>.from(tried);
  final nextHelped = Map<String, int>.from(helped);
  for (final raw in reliefs) {
    final name = raw.trim();
    if (name.isEmpty) continue;
    nextTried[name] = (nextTried[name] ?? 0) + 1;
    if (helpedIt) nextHelped[name] = (nextHelped[name] ?? 0) + 1;
  }
  return (tried: nextTried, helped: nextHelped);
}
