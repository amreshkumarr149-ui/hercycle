import 'package:flutter_test/flutter_test.dart';
import 'package:hercycle/core/clinical_report_engine.dart';
import 'package:hercycle/core/premium_service.dart';
import 'package:hercycle/models/daily_log.dart';

String d(DateTime dt) =>
    '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

void main() {
  test('quote constants price one rupee', () {
    expect(PremiumService.priceInrPaise, 100);
    expect(PremiumService.priceInr, '₹1');
  });

  test('empty data yields exactly the fallback suggestion', () {
    final report = ClinicalReportEngine.build(
        profile: {'name': 'Test'},
        allLogs: [],
        windowDays: 90,
        fromCache: false);
    final recs = PremiumService.buildRecommendations(report);
    expect(recs.length, 1);
    expect(recs.first, contains('keep logging daily'));
  });

  test('variable cycles trigger variability suggestion with label', () {
    final t = DateTime.now();
    final logs = <DailyLog>[];
    // Starts 45 and 27 days apart: intervals [45, 27], variation 18.
    final s1 = t.subtract(const Duration(days: 120));
    for (final start in [
      s1,
      s1.add(const Duration(days: 45)),
      s1.add(const Duration(days: 72))
    ]) {
      for (var i = 0; i < 4; i++) {
        logs.add(DailyLog(
            date: d(start.add(Duration(days: i))),
            period: true,
            symptoms: const [],
            mood: '',
            flowIntensity: 'Medium'));
      }
    }
    final report = ClinicalReportEngine.build(
        profile: {'name': 'T'},
        allLogs: logs,
        windowDays: null,
        fromCache: false);
    final recs = PremiumService.buildRecommendations(report);
    expect(recs.any((s) => s.contains('varies')), isTrue);
    expect(recs.every((s) => s.contains('(educational)')), isTrue);
    expect(recs.length, lessThanOrEqualTo(6));
  });
}
