import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hercycle/core/app_theme.dart';
import 'package:hercycle/core/clinical_report_engine.dart';
import 'package:hercycle/core/relief_ranking.dart';
import 'package:hercycle/core/widgets/animations.dart';
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
    final her = context.her;
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

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(clinicalDataProvider);
            },
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // Clinical Reports Banner Card
                ScaleFadeIn(
                  child: Container(
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
              ),
              const SizedBox(height: 28),
              _sectionHeader(
                her,
                icon: Icons.analytics_outlined,
                title: 'Cycle Analytics',
                delay: 120,
              ),
              const SizedBox(height: 16),
              FadeSlideIn(
                delay: const Duration(milliseconds: 150),
                child: Row(
                  children: [
                    Expanded(
                      child: _statCard(
                        her,
                        Icons.refresh_outlined,
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
                      her,
                      Icons.water_drop_outlined,
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
              ),
              if (!ready) ...[
                const SizedBox(height: 12),
                Text(
                  'Log at least 2 complete cycles to unlock analytics — currently showing ${report.cyclesAnalyzed}.',
                  style: TextStyle(fontSize: 12, color: her.muted),
                ),
              ],
              const SizedBox(height: 28),
              _sectionHeader(
                her,
                icon: Icons.show_chart,
                title: 'Cycle Length History',
                delay: 200,
              ),
              const SizedBox(height: 16),
              FadeSlideIn(
                delay: const Duration(milliseconds: 250),
                child: _cycleLengthCard(her, report),
              ),
              const SizedBox(height: 28),
              _sectionHeader(
                her,
                icon: Icons.trending_up,
                title: 'Trends',
                delay: 300,
              ),
              const SizedBox(height: 16),
              if (report.trends.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: her.card,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.pink.withValues(alpha: 0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 4))
                    ],
                  ),
                  child: Text(
                      'Not enough complete cycles to compare trends yet.',
                      style: TextStyle(color: her.muted, fontSize: 13)),
                )
              else
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: her.card,
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
                        FadeSlideIn(
                          delay: Duration(milliseconds: 320 + i * 80),
                          child: _trendRow(her, report.trends[i]),
                        ),
                      ],
                    ],
                  ),
                ),
              const SizedBox(height: 28),
              _sectionHeader(
                her,
                icon: Icons.spa_outlined,
                title: 'Common Symptoms',
                delay: 360,
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: her.card,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.pink.withValues(alpha: 0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 4))
                  ],
                ),
                child: report.symptoms.isEmpty
                    ? Text('No symptoms logged yet.',
                        style:
                            TextStyle(color: her.muted, fontSize: 13))
                    : Column(
                        children: [
                          for (var i = 0;
                              i < report.symptoms.length.clamp(0, 4);
                              i++) ...[
                            if (i > 0) const SizedBox(height: 14),
                            FadeSlideIn(
                              delay:
                                  Duration(milliseconds: 380 + i * 80),
                              child: _buildSymptomBar(
                                her,
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
                            ),
                          ],
                        ],
                      ),
              ),
              const SizedBox(height: 28),
              _sectionHeader(
                her,
                icon: Icons.bar_chart_outlined,
                title: 'Symptom Frequency',
                delay: 420,
              ),
              const SizedBox(height: 16),
              FadeSlideIn(
                delay: const Duration(milliseconds: 440),
                child: _symptomFrequencyCard(her, report),
              ),
              const SizedBox(height: 28),
              _sectionHeader(
                her,
                icon: Icons.favorite_outline,
                title: 'Relief Playbook',
                delay: 460,
              ),
              const SizedBox(height: 16),
              FadeSlideIn(
                delay: const Duration(milliseconds: 480),
                child: _reliefPlaybookCard(her, logs),
              ),
              const SizedBox(height: 16),
              Text('Reliability: ${report.reliability} • ${report.trackingMode}',
                  style: TextStyle(fontSize: 12, color: her.muted)),
            ],
            ),
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

  /// Section header with a gradient icon medallion, staggered in.
  Widget _sectionHeader(HerCycleColors her,
      {required IconData icon,
      required String title,
      required int delay}) {
    return FadeSlideIn(
      delay: Duration(milliseconds: delay),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFC26D81), Color(0xFFE29578)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          Text(title,
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: her.ink)),
        ],
      ),
    );
  }

  /// Animated count-up for values like "28.5 days". Non-numeric values
  /// (e.g. "—") render statically.
  Widget _animatedValue(String value) {
    const style = TextStyle(
        fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFFC26D81));
    final m = RegExp(r'^([\d.]+)(.*)$').firstMatch(value);
    final target = m == null ? null : double.tryParse(m.group(1)!);
    if (target == null) return Text(value, style: style);
    final suffix = m!.group(2)!;
    final decimals = m.group(1)!.contains('.') ? 1 : 0;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: target),
      duration: const Duration(milliseconds: 1000),
      curve: Curves.easeOutCubic,
      builder: (context, v, child) =>
          Text('${v.toStringAsFixed(decimals)}$suffix', style: style),
    );
  }

  Widget _statCard(HerCycleColors her, IconData icon, String label,
      String value, String? tag) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: her.card,
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
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: const Color(0xFFC26D81).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon,
                    color: const Color(0xFFC26D81), size: 16),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(label,
                    style: TextStyle(color: her.muted, fontSize: 13)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _animatedValue(value),
          if (tag != null && tag.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFC26D81).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(tag,
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFFC26D81))),
            ),
          ],
        ],
      ),
    );
  }

  Widget _trendRow(HerCycleColors her, TrendRow t) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFC26D81), Color(0xFFE29578)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Center(
            child: Text(t.indicator,
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.name,
                  style: const TextStyle(
                      fontWeight: FontWeight.w500, fontSize: 13)),
              Text(t.detail,
                  style:
                      TextStyle(fontSize: 12, color: her.muted)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _chartCard(HerCycleColors her, {required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: her.card,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: Colors.pink.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 4))
        ],
      ),
      child: child,
    );
  }

  Widget _cycleLengthCard(HerCycleColors her, ClinicalReport report) {
    final lengths = report.cycles
        .where((c) => c.length != null)
        .map((c) => c.length!)
        .toList();
    if (lengths.length < 2) {
      return _chartCard(
        her,
        child: Text(
            'Log at least 2 complete cycles to see your length history.',
            style: TextStyle(color: her.muted, fontSize: 13)),
      );
    }
    final spots = [
      for (var i = 0; i < lengths.length; i++)
        FlSpot((i + 1).toDouble(), lengths[i].toDouble())
    ];
    final avg =
        lengths.reduce((a, b) => a + b) / lengths.length;
    final minY = (lengths.reduce((a, b) => a < b ? a : b) - 2.0)
        .clamp(0.0, double.infinity);
    final maxY =
        lengths.reduce((a, b) => a > b ? a : b).toDouble() + 2.0;
    return _chartCard(
      her,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                    'Days per cycle (avg ${avg.toStringAsFixed(1)})',
                    style:
                        TextStyle(fontSize: 12, color: her.muted)),
              ),
              Container(
                width: 18,
                height: 0,
                decoration: const BoxDecoration(
                  border: Border(
                    top: BorderSide(
                        color: Color(0xFFE29578),
                        width: 1.5,
                        style: BorderStyle.solid),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text('your average',
                  style: TextStyle(fontSize: 11, color: her.muted)),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 210,
            child: LineChart(
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              LineChartData(
                minX: 1,
                maxX: lengths.length.toDouble(),
                minY: minY,
                maxY: maxY,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (value) => FlLine(
                    color: her.muted.withValues(alpha: 0.25),
                    strokeWidth: 1,
                  ),
                ),
                borderData: FlBorderData(
                  show: true,
                  border: Border.all(
                      color: her.muted.withValues(alpha: 0.4)),
                ),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 34,
                      getTitlesWidget: (value, meta) => Text(
                        value.toInt().toString(),
                        style: TextStyle(fontSize: 10, color: her.muted),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: 1,
                      getTitlesWidget: (value, meta) {
                        final i = value.toInt();
                        if (i < 1 || i > lengths.length) {
                          return const SizedBox.shrink();
                        }
                        return Text('C$i',
                            style: TextStyle(
                                fontSize: 10, color: her.muted));
                      },
                    ),
                  ),
                ),
                lineTouchData: LineTouchData(
                  enabled: true,
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) => her.card,
                    getTooltipItems: (spots) => spots
                        .map((s) => LineTooltipItem(
                              'Cycle ${s.x.toInt()}\n',
                              TextStyle(
                                  color: her.muted, fontSize: 11),
                              children: [
                                TextSpan(
                                  text:
                                      '${s.y.toStringAsFixed(0)} days',
                                  style: TextStyle(
                                      color: her.ink,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13),
                                ),
                              ],
                            ))
                        .toList(),
                  ),
                ),
                extraLinesData: ExtraLinesData(
                  horizontalLines: [
                    HorizontalLine(
                      y: avg,
                      color: const Color(0xFFE29578),
                      strokeWidth: 1.5,
                      dashArray: [6, 4],
                    ),
                  ],
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    color: const Color(0xFFC26D81),
                    barWidth: 3.5,
                    dotData: FlDotData(
                      show: true,
                      getDotPainter: (spot, percent, bar, index) =>
                          FlDotCirclePainter(
                        radius: 4,
                        color: her.card,
                        strokeWidth: 2.5,
                        strokeColor: const Color(0xFFC26D81),
                      ),
                    ),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFFC26D81)
                              .withValues(alpha: 0.35),
                          const Color(0xFFF9C8D2)
                              .withValues(alpha: 0.05),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _symptomFrequencyCard(HerCycleColors her, ClinicalReport report) {
    final top = report.symptoms.take(5).toList();
    if (top.isEmpty) {
      return _chartCard(
        her,
        child: Text('No symptoms logged yet — bars appear here.',
            style: TextStyle(color: her.muted, fontSize: 13)),
      );
    }
    final maxCount =
        top.map((s) => s.occurrences).reduce((a, b) => a > b ? a : b);
    const barColors = [
      Color(0xFFC26D81),
      Color(0xFFE29578),
      Color(0xFF83C5BE),
      Color(0xFFCE93D8),
      Color(0xFFF9C8D2),
    ];
    return _chartCard(
      her,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Logged days per symptom (top ${top.length})',
              style: TextStyle(fontSize: 12, color: her.muted)),
          const SizedBox(height: 12),
          SizedBox(
            height: 210,
            child: BarChart(
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              BarChartData(
                maxY: (maxCount + 1).toDouble(),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (value) => FlLine(
                    color: her.muted.withValues(alpha: 0.25),
                    strokeWidth: 1,
                  ),
                ),
                borderData: FlBorderData(
                  show: true,
                  border: Border.all(
                      color: her.muted.withValues(alpha: 0.4)),
                ),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 30,
                      getTitlesWidget: (value, meta) => Text(
                        value.toInt().toString(),
                        style: TextStyle(fontSize: 10, color: her.muted),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: 1,
                      getTitlesWidget: (value, meta) {
                        final i = value.toInt();
                        if (i < 0 || i >= top.length) {
                          return const SizedBox.shrink();
                        }
                        final name = top[i].name;
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            name.length > 7
                                ? '${name.substring(0, 7)}…'
                                : name,
                            style: TextStyle(
                                fontSize: 10, color: her.muted),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                barTouchData: BarTouchData(
                  enabled: true,
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipColor: (_) => her.card,
                    getTooltipItem: (group, groupIndex, rod, rodIndex) {
                      final s = top[group.x.toInt()];
                      return BarTooltipItem(
                        '${s.name}\n',
                        TextStyle(color: her.muted, fontSize: 11),
                        children: [
                          TextSpan(
                            text:
                                '${s.occurrences} day${s.occurrences == 1 ? '' : 's'}',
                            style: TextStyle(
                                color: her.ink,
                                fontWeight: FontWeight.bold,
                                fontSize: 13),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                barGroups: [
                  for (var i = 0; i < top.length; i++)
                    BarChartGroupData(
                      x: i,
                      barRods: [
                        BarChartRodData(
                          toY: top[i].occurrences.toDouble(),
                          width: 26,
                          borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(8)),
                          gradient: LinearGradient(
                            colors: [
                              barColors[i % barColors.length],
                              barColors[i % barColors.length]
                                  .withValues(alpha: 0.55),
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Relief Playbook: the user's own remedies ranked by their SOS history.
  /// Cold start shows guidance; verdicts appear after repeat episodes.
  Widget _reliefPlaybookCard(HerCycleColors her, List<DailyLog> logs) {
    const palette = [
      Color(0xFFC26D81),
      Color(0xFFE29578),
      Color(0xFF83C5BE),
      Color(0xFFCE93D8),
    ];
    final totals = aggregateReliefs(logs.map((l) => {
          'reliefTried': l.reliefTried,
          'reliefHelped': l.reliefHelped,
        }));
    final episodes = totals.tried.values.fold(0, (a, b) => a + b);
    if (episodes == 0) {
      return _chartCard(
        her,
        child: Text(
            'No SOS episodes logged yet — next time pain hits, use Cramp SOS and rate what you try. Your playbook builds itself.',
            style: TextStyle(
                color: her.muted, fontSize: 13, height: 1.5)),
      );
    }
    final ranked = rankReliefs(tried: totals.tried, helped: totals.helped);
    final best = ranked.firstWhere(
      (r) => r.hasVerdict,
      orElse: () => ranked.first,
    );
    return _chartCard(
      her,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFC26D81), Color(0xFFE29578)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Your best relief so far',
                    style: TextStyle(color: Colors.white70, fontSize: 12)),
                const SizedBox(height: 2),
                Text('${best.name} • ${best.verdict}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
                Text('$episodes SOS ${episodes == 1 ? 'episode' : 'episodes'} logged',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(height: 14),
          for (var i = 0; i < ranked.length.clamp(0, 4); i++) ...[
            if (i > 0) const SizedBox(height: 14),
            _buildSymptomBar(
              her,
              ranked[i].name,
              ranked[i].tried == 0
                  ? 0
                  : (ranked[i].helped / ranked[i].tried)
                      .clamp(0.0, 1.0),
              palette[i % palette.length],
              ranked[i].verdict,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSymptomBar(HerCycleColors her, String label, double progress,
      Color color, String subtitle) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: progress.clamp(0.0, 1.0)),
      duration: const Duration(milliseconds: 1000),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(label,
                    style: const TextStyle(fontWeight: FontWeight.w500)),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('${(value * 100).round()}%',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: color)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(subtitle,
              style: TextStyle(color: her.muted, fontSize: 12)),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              height: 10,
              child: Stack(
                children: [
                  Container(
                      color: her.muted.withValues(alpha: 0.2)),
                  FractionallySizedBox(
                    widthFactor: value,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            color,
                            color.withValues(alpha: 0.6)
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
