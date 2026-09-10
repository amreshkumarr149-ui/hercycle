import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hercycle/core/clinical_report_engine.dart';
import 'package:hercycle/features/trends/health_reports_screen.dart';
import 'package:hercycle/models/daily_log.dart';
import 'package:hercycle/providers/clinical_data_provider.dart';

/// Trends dashboard driven entirely by tracked data via
/// [ClinicalReportEngine] — no placeholder numbers. Shares
/// [clinicalDataProvider] with the Health Reports screen so both tabs always
/// agree, and a fresh log invalidates both at once.
class TrendsScreen extends ConsumerWidget {
  const TrendsScreen({super.key});

  String _metric(ClinicalReport report, String name) {
    for (final b in report.baselines) {
      if (b.name == name) return b.value;
    }
    return '—';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const primaryColor = Color(0xFFC26D81);
    const ink = Color(0xFF4A4A4A);
    final dataAsync = ref.watch(clinicalDataProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trends & Insights',
            style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: dataAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load trends: $e')),
        data: (data) {
          final logs = (data['logs'] as List<DailyLog>);
          final report = ClinicalReportEngine.build(
            profile: data['user'] as Map<String, dynamic>?,
            allLogs: logs,
            windowDays: null,
            fromCache: data['fromCache'] == true,
          );
          final ready = report.cyclesAnalyzed >= 2;
          const barColors = [
            Color(0xFFC26D81),
            Color(0xFFF9C8D2),
            Color(0xFFE29578),
            Color(0xFF83C5BE),
          ];

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // Clinical Reports Banner Card
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFF9C8D2), Color(0xFFC26D81)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.pink.withValues(alpha: 0.1),
                        blurRadius: 10,
                        offset: const Offset(0, 4))
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Clinical Pattern Screener',
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white)),
                    const SizedBox(height: 8),
                    const Text(
                        'Screen for patterns related to PCOS, Fibroids, and Endometriosis and export doctor-ready PDF reports.',
                        style: TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            height: 1.4)),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) =>
                                    const HealthReportsScreen()));
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: primaryColor,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child:
                          const Text('View Health Reports & PDF Export'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              const Text('Cycle Analytics',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: ink)),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _statCard(
                      'Avg Cycle',
                      ready
                          ? _metric(report, 'Average Cycle Length')
                          : '—',
                      ready ? _metricTag(report, 'Average Cycle Length') : null,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _statCard(
                      'Avg Period',
                      ready
                          ? _metric(report, 'Average Bleeding Duration')
                          : '—',
                      ready
                          ? _metricTag(report, 'Average Bleeding Duration')
                          : null,
                    ),
                  ),
                ],
              ),
              if (!ready) ...[
                const SizedBox(height: 12),
                Text(
                  'Log at least 2 complete cycles to unlock analytics — currently showing ${report.cyclesAnalyzed}.',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
              const SizedBox(height: 28),
              const Text('Trends',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: ink)),
              const SizedBox(height: 16),
              if (report.trends.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.pink.withValues(alpha: 0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 4))
                    ],
                  ),
                  child: const Text(
                      'Not enough complete cycles to compare trends yet.',
                      style: TextStyle(color: Colors.grey, fontSize: 13)),
                )
              else
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.pink.withValues(alpha: 0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 4))
                    ],
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < report.trends.length; i++) ...[
                        if (i > 0) const SizedBox(height: 14),
                        _trendRow(report.trends[i]),
                      ],
                    ],
                  ),
                ),
              const SizedBox(height: 28),
              const Text('Common Symptoms',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: ink)),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.pink.withValues(alpha: 0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 4))
                  ],
                ),
                child: report.symptoms.isEmpty
                    ? const Text('No symptoms logged yet.',
                        style:
                            TextStyle(color: Colors.grey, fontSize: 13))
                    : Column(
                        children: [
                          for (var i = 0;
                              i < report.symptoms.length.clamp(0, 4);
                              i++) ...[
                            if (i > 0) const SizedBox(height: 14),
                            _buildSymptomBar(
                              report.symptoms[i].name,
                              report.cyclesAnalyzed == 0
                                  ? 0
                                  : (report.symptoms[i].cyclesAffected /
                                          report.cyclesAnalyzed)
                                      .clamp(0.0, 1.0),
                              barColors[i % barColors.length],
                              '${report.symptoms[i].cyclesAffected} of ${report.cyclesAnalyzed} cycles'
                              '${report.symptoms[i].avgSeverity == '—' ? '' : ' • avg ${report.symptoms[i].avgSeverity}'}',
                            ),
                          ],
                        ],
                      ),
              ),
              const SizedBox(height: 16),
              Text('Reliability: ${report.reliability} • ${report.trackingMode}',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            ],
          );
        },
      ),
    );
  }

  String _metricTag(ClinicalReport report, String name) {
    for (final b in report.baselines) {
      if (b.name == name) return b.tag;
    }
    return '';
  }

  Widget _statCard(String label, String value, String? tag) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: Colors.pink.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 4))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.grey, fontSize: 13)),
          const SizedBox(height: 8),
          Text(value,
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFC26D81))),
          if (tag != null && tag.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(tag,
                style: TextStyle(fontSize: 11, color: Colors.grey[600])),
          ],
        ],
      ),
    );
  }

  Widget _trendRow(TrendRow t) {
    return Row(
      children: [
        SizedBox(
          width: 30,
          child: Text(t.indicator,
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold)),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.name,
                  style: const TextStyle(
                      fontWeight: FontWeight.w500, fontSize: 13)),
              Text(t.detail,
                  style:
                      TextStyle(fontSize: 12, color: Colors.grey[600])),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSymptomBar(
      String label, double progress, Color color, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: const TextStyle(fontWeight: FontWeight.w500)),
            Text(subtitle,
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: progress),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) => LinearProgressIndicator(
              value: value,
              backgroundColor: Colors.grey[100],
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 8,
            ),
          ),
        ),
      ],
    );
  }
}
