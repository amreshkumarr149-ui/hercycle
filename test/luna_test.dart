import 'package:flutter_test/flutter_test.dart';
import 'package:hercycle/core/luna_service.dart';
import 'package:hercycle/models/daily_log.dart';

String d(DateTime dt) =>
    '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

DailyLog log(String date,
    {bool period = false,
    List<String> symptoms = const [],
    String mood = '',
    String mucus = '',
    String lh = '',
    int pain = 0,
    String notes = ''}) {
  return DailyLog(
      date: date,
      period: period,
      symptoms: symptoms,
      mood: mood,
      mucus: mucus,
      lhTest: lh,
      painScore: pain,
      notes: notes);
}

void main() {
  test('empty history yields null markers, never invented values', () {
    final s = LunaService.buildSummary(
        profile: {'name': 'T'}, logs: [], prediction: {});
    expect(s['periodStarts'], isNull);
    expect(s['symptoms'], isEmpty);
    expect(s['daysLogged'], 0);
    expect((s['anchors'] as Map)['userName'], isNull);
  });

  test('rolls up 90-day logs and drops stale, future and malformed', () {
    final t = DateTime.now();
    final recent = t.subtract(const Duration(days: 5));
    final logs = [
      log(d(recent), period: true, symptoms: ['Cramps'], mood: 'Calm',
          mucus: 'Eggwhite', lh: 'Positive', pain: 8, notes: 'rough day'),
      log(d(recent.add(const Duration(days: 1))), mood: 'Happy'),
      log(d(t.subtract(const Duration(days: 200))), period: true), // stale
      log(d(t.add(const Duration(days: 3))), period: true), // future
      log('not-a-date', period: true), // malformed
    ];
    final s = LunaService.buildSummary(
      profile: {'name': 'Sara', 'hadSexRecently': 'No'},
      logs: logs,
      prediction: {
        'currentDay': 6,
        'phaseName': 'Follicular Phase',
        'nextPeriod': d(t.add(const Duration(days: 22))),
        'daysUntilNextPeriod': 22,
      },
    );
    expect((s['periodStarts'] as List).length, 1);
    expect(s['daysLogged'], 2);
    final syms = s['symptoms'] as List;
    expect(syms.length, 1);
    expect(syms.first['name'], 'Cramps');
    expect((s['moods'] as Map)['Calm'], 1);
    expect((s['lhPositives'] as List).length, 1);
    expect((s['painDays'] as List).length, 1);
    expect((s['notes'] as List).length, 1);
    expect(s['hadSexRecently'], 'No');
    expect((s['anchors'] as Map)['phaseName'], 'Follicular Phase');
  });

  test('ask returns null when the server is unreachable', () async {
    final reply = await LunaService.ask(
      serverUrl: 'http://127.0.0.1:9',
      message: 'hello?',
      summary: const {},
    );
    expect(reply, isNull);
  });
}
