import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:hercycle/models/daily_log.dart';

/// Client side of log-grounded Luna.
///
/// [buildSummary] condenses the last 90 days of tracked logs plus live
/// engine anchors into a small JSON payload. Only aggregates and the most
/// relevant entries travel — never the whole raw history, never credentials.
/// [ask] POSTs it with the user's message; any failure lets the caller fall
/// back to the on-device rule engine so Luna never goes dead.
class LunaService {
  LunaService._();

  static String _d(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Builds the 90-day grounded summary. All inputs optional — missing data
  /// yields explicit "not logged" markers instead of invented values.
  static Map<String, dynamic> buildSummary({
    required Map<String, dynamic>? profile,
    required List<DailyLog> logs,
    required Map<String, dynamic> prediction,
    DateTime? now,
  }) {
    final today = now ?? DateTime.now();
    final todayDay = DateTime(today.year, today.month, today.day);
    final cutoff = todayDay.subtract(const Duration(days: 89));

    final entries = <({DateTime date, DailyLog log})>[];
    for (final log in logs) {
      final d = DateTime.tryParse(log.date);
      if (d == null) continue;
      final day = DateTime(d.year, d.month, d.day);
      if (day.isAfter(todayDay) || day.isBefore(cutoff)) continue;
      entries.add((date: day, log: log));
    }
    entries.sort((a, b) => a.date.compareTo(b.date));

    bool bleeding(DailyLog l) =>
        l.period || l.flowIntensity != 'None';

    // Period starts (bleeding day whose previous day wasn't bleeding).
    final bleedDays =
        entries.where((e) => bleeding(e.log)).map((e) => e.date).toSet();
    final starts = bleedDays
        .where((d) =>
            !bleedDays.contains(d.subtract(const Duration(days: 1))))
        .map(_d)
        .toList()
      ..sort();

    // Symptom roll-up with dates + scores.
    final symDays = <String, List<String>>{};
    final symScores = <String, List<int>>{};
    for (final e in entries) {
      for (final s in e.log.symptoms) {
        (symDays[s] ??= []).add(_d(e.date));
        final score = e.log.symptomIntensity[s] ?? e.log.painScore;
        if (score > 0) (symScores[s] ??= []).add(score);
      }
    }
    final symptoms = symDays.keys.map((s) {
      final scores = symScores[s] ?? [];
      return {
        'name': s,
        'days': symDays[s]!.length > 8
            ? [...symDays[s]!.take(8), '…']
            : symDays[s],
        'avgScore': scores.isEmpty
            ? null
            : double.parse(
                (scores.reduce((a, b) => a + b) / scores.length)
                    .toStringAsFixed(1)),
      };
    }).toList();

    // Mood distribution.
    final moods = <String, int>{};
    for (final e in entries) {
      if (e.log.mood.isNotEmpty) {
        moods[e.log.mood] = (moods[e.log.mood] ?? 0) + 1;
      }
    }

    // Fertile-pattern mucus + LH peaks with dates.
    final mucusTrail = entries
        .where((e) => e.log.mucus.isNotEmpty)
        .map((e) => '${_d(e.date)}:${e.log.mucus.replaceAll('\n', ' ')}')
        .toList();
    final lhPositives = entries
        .where((e) => e.log.lhTest.toLowerCase() == 'positive')
        .map((e) => _d(e.date))
        .toList();

    // High pain days.
    final painDays = entries
        .where((e) => e.log.painScore >= 7)
        .map((e) => '${_d(e.date)}:${e.log.painScore}/10')
        .toList();

    // Recent non-empty notes (trimmed).
    final notes = entries
        .where((e) => e.log.notes.trim().isNotEmpty)
        .map((e) =>
            '${_d(e.date)}:${e.log.notes.trim().replaceAll('\n', ' ').length > 120 ? '${e.log.notes.trim().replaceAll('\n', ' ').substring(0, 120)}…' : e.log.notes.trim().replaceAll('\n', ' ')}')
        .toList();
    final recentNotes =
        notes.length > 10 ? notes.sublist(notes.length - 10) : notes;

    DateTime? nextPeriod;
    final rawNext = prediction['nextPeriod'];
    if (rawNext is DateTime) {
      nextPeriod = rawNext;
    } else if (rawNext is String) {
      nextPeriod = DateTime.tryParse(rawNext);
    }

    return {
      'windowDays': 90,
      'userName': profile?['name']?.toString() ?? '',
      'anchors': {
        'today': _d(todayDay),
        'currentDay': prediction['currentDay'],
        'phaseName': prediction['phaseName'],
        'nextPeriod': nextPeriod == null ? null : _d(nextPeriod),
        'daysUntilNextPeriod': prediction['daysUntilNextPeriod'],
        'averageCycleLength': profile?['typicalCycleLength'],
        'ovulationLocked': prediction['isOvulationLocked'] == true,
        'activeAlert': prediction['alertMessage'],
      },
      'periodStarts': starts.isEmpty ? null : starts,
      'symptoms': symptoms,
      'moods': moods.isEmpty ? null : moods,
      'mucusTrail': mucusTrail.isEmpty ? null : mucusTrail,
      'lhPositives': lhPositives.isEmpty ? null : lhPositives,
      'painDays': painDays.isEmpty ? null : painDays,
      'notes': recentNotes.isEmpty ? null : recentNotes,
      // Sourced from the user profile (not daily logs) — included only
      // because the user explicitly allowed sensitive fields.
      'hadSexRecently': profile?['hadSexRecently']?.toString(),
      'daysLogged': entries.length,
    };
  }

  /// Sends one chat turn. Returns the server reply, or null when anything
  /// goes wrong (caller falls back to the rule engine). A 429 carries a
  /// usable "breather" reply, so it is honored rather than discarded.
  static Future<String?> ask({
    required String serverUrl,
    required String message,
    required Map<String, dynamic> summary,
  }) async {
    if (message.trim().isEmpty) return null;
    try {
      final res = await http
          .post(
            Uri.parse('$serverUrl/api/luna/chat'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'message': message.trim(), 'summary': summary}),
          )
          .timeout(const Duration(seconds: 25));
      if (res.statusCode != 200 && res.statusCode != 429) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final reply = body['reply']?.toString().trim() ?? '';
      return reply.isEmpty ? null : reply;
    } catch (_) {
      return null;
    }
  }
}
