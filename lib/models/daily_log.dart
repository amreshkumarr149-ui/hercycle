class DailyLog {
  final String date;
  final bool period;
  final List<String> symptoms;
  final String mood;
  final String mucus;
  final String lhTest;
  final String flowIntensity;
  final int painScore;
  final bool pelvicPressure;
  final bool backBowelPain;
  /// Per-symptom intensity on a 0-10 scale, e.g. {'Cramps': 6}.
  /// Stored as a Firestore map; missing keys mean "not rated".
  final Map<String, int> symptomIntensity;
  /// Optional free-text note for the day. Omitted from Firestore when empty.
  final String notes;
  /// SOS episodes: relief name -> times tried / times it helped.
  /// Empty maps are omitted from Firestore; missing keys mean "not rated".
  final Map<String, int> reliefTried;
  final Map<String, int> reliefHelped;
  /// Trying-to-conceive logging: true when intimacy was logged this day.
  /// Omitted from Firestore when false.
  final bool intimacy;

  DailyLog({
    required this.date,
    required this.period,
    required this.symptoms,
    required this.mood,
    this.mucus = '',
    this.lhTest = '',
    this.flowIntensity = 'None',
    this.painScore = 0,
    this.pelvicPressure = false,
    this.backBowelPain = false,
    Map<String, int>? symptomIntensity,
    this.notes = '',
    Map<String, int>? reliefTried,
    Map<String, int>? reliefHelped,
    this.intimacy = false,
  })  : symptomIntensity = symptomIntensity ?? const {},
        reliefTried = reliefTried ?? const {},
        reliefHelped = reliefHelped ?? const {};

  static Map<String, int> _parseIntensity(dynamic value) {
    if (value is Map) {
      final out = <String, int>{};
      value.forEach((k, v) {
        if (v is int) {
          out[k.toString()] = v.clamp(0, 10);
        } else if (v is num) {
          out[k.toString()] = v.toInt().clamp(0, 10);
        }
      });
      return out;
    }
    return {};
  }

  /// Non-negative string->int counts; corrupt values (negatives, non-maps,
  /// non-numbers) degrade to empty rather than crashing or inflating ranks.
  static Map<String, int> _parseCounts(dynamic value) {
    if (value is Map) {
      final out = <String, int>{};
      value.forEach((k, v) {
        final n = v is int ? v : (v is num ? v.toInt() : null);
        if (n != null && n > 0) out[k.toString()] = n;
      });
      return out;
    }
    return {};
  }

  factory DailyLog.fromFirestore(Map<String, dynamic> data) {
    return DailyLog(
      date: data['date'] ?? '',
      period: data['period'] ?? false,
      symptoms: List<String>.from(data['symptoms'] ?? []),
      mood: data['mood'] ?? '',
      mucus: data['mucus'] ?? '',
      lhTest: data['lhTest'] ?? '',
      flowIntensity: data['flowIntensity'] ?? 'None',
      painScore: (data['painScore'] is num) ? (data['painScore'] as num).toInt() : 0,
      pelvicPressure: data['pelvicPressure'] ?? false,
      backBowelPain: data['backBowelPain'] ?? false,
      symptomIntensity: _parseIntensity(data['symptomIntensity']),
      notes: data['notes']?.toString() ?? '',
      reliefTried: _parseCounts(data['reliefTried']),
      reliefHelped: _parseCounts(data['reliefHelped']),
      intimacy: data['intimacy'] == true,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'date': date,
      'period': period,
      'symptoms': symptoms,
      'mood': mood,
      'mucus': mucus,
      'lhTest': lhTest,
      'flowIntensity': flowIntensity,
      'painScore': painScore,
      'pelvicPressure': pelvicPressure,
      'backBowelPain': backBowelPain,
      'symptomIntensity': symptomIntensity,
      // Notes are always written (even empty) so clearing the field under
      // merge semantics actually clears it instead of resurrecting text.
      'notes': notes.trim(),
      if (reliefTried.isNotEmpty) 'reliefTried': reliefTried,
      if (reliefHelped.isNotEmpty) 'reliefHelped': reliefHelped,
      if (intimacy) 'intimacy': true,
    };
  }
}
