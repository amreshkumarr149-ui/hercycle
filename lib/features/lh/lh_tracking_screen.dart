import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:hercycle/core/app_theme.dart';
import 'package:hercycle/core/database_repository.dart';
import 'package:hercycle/core/lh_prediction_engine.dart';
import 'package:hercycle/models/lh_test_entry.dart';
import 'package:hercycle/providers/auth_user_provider.dart';
import 'package:hercycle/providers/prediction_provider.dart';
import 'lh_entry_bottom_sheet.dart';
import 'lh_test_detail_screen.dart';

class LhTrackingScreen extends ConsumerStatefulWidget {
  final String initialDateStr;

  const LhTrackingScreen({
    super.key,
    required this.initialDateStr,
  });

  @override
  ConsumerState<LhTrackingScreen> createState() => _LhTrackingScreenState();
}

class _LhTrackingScreenState extends ConsumerState<LhTrackingScreen> {
  bool _loading = true;
  List<LhTestEntry> _tests = [];
  LhPredictionResult? _prediction;

  @override
  void initState() {
    super.initState();
    _loadTests();
  }

  Future<void> _loadTests() async {
    final userId = safeCurrentUid();
    if (userId == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    try {
      final list = await DatabaseRepository().getLhTests(userId, limit: 100);
      final sorted = List<LhTestEntry>.from(list)
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

      DateTime baselineOvulation = DateTime.now().add(const Duration(days: 14));
      try {
        final preds = ref.read(predictionProvider).valueOrNull;
        if (preds != null && preds['ovulationDate'] is DateTime) {
          baselineOvulation = preds['ovulationDate'] as DateTime;
        }
      } catch (_) {}

      final baseDate = DateTime.tryParse(widget.initialDateStr) ?? DateTime.now();
      final lastPeriod = DateTime.now().subtract(const Duration(days: 14));
      final cycleDay = baseDate.difference(lastPeriod).inDays + 1;

      final prediction = LhPredictionEngine.compute(
        sortedEntries: sorted,
        baselineOvulationDate: baselineOvulation,
        cycleDay: cycleDay.clamp(1, 40),
      );

      setState(() {
        _tests = list;
        _prediction = prediction;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _openAddModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => LhEntryBottomSheet(
        dateStr: widget.initialDateStr,
        onSaved: (entry) {
          _loadTests();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('LH test saved & ovulation prediction recalculated')),
          );
        },
      ),
    );
  }

  bool get _hasQuantitativeData =>
      _tests.any((t) => t.tcRatio != null && t.entryType == LhEntryType.aiScan);

  int get _quantitativeCount => _tests
      .where((t) => t.tcRatio != null && t.entryType == LhEntryType.aiScan)
      .length;

  /// PRD §35 — single quantitative result: velocity unavailable yet.
  Widget _buildLearningNote() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.purple.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.purple.withValues(alpha: 0.2)),
      ),
      child: Text(
        "We're learning your LH pattern. Add another LH test to see how your LH level is changing over time.",
        style: TextStyle(fontSize: 13, color: context.her.ink, height: 1.4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LH Test Tracker', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _tests.isEmpty
              ? _buildEmptyState()
              : _buildContent(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openAddModal,
        backgroundColor: const Color(0xFFC26D81),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Log LH Test'),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.science_outlined, size: 64, color: Color(0xFFC26D81)),
            const SizedBox(height: 16),
            const Text('No LH Tests Recorded Yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              'Track ovulation strip tests via AI camera scan or manual positive/negative log to dynamically shift your ovulation window.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.her.muted),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _openAddModal,
              icon: const Icon(Icons.add),
              label: const Text('Add First LH Test'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFC26D81),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildCurrentLhCard(),
        const SizedBox(height: 16),
        if (_prediction != null) _buildPredictionCard(),
        const SizedBox(height: 16),
        if (_hasQuantitativeData) _buildProgressionGraph(),
        if (_hasQuantitativeData) const SizedBox(height: 16),
        if (_prediction != null && _prediction!.explanation.isNotEmpty)
          _buildExplanationCard(),
        if (_prediction != null && _prediction!.explanation.isNotEmpty)
          const SizedBox(height: 16),
        if (_quantitativeCount == 1) _buildLearningNote(),
        if (_quantitativeCount == 1) const SizedBox(height: 16),
        Row(
          children: [
            Text('Test History', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.her.ink)),
            const Spacer(),
            Text('${_tests.length} tests', style: TextStyle(fontSize: 13, color: context.her.muted)),
          ],
        ),
        const SizedBox(height: 12),
        ...List.generate(_tests.length, (index) => _buildHistoryCard(_tests[index])),
      ],
    );
  }

  /// PRD §29 — current LH card (latest result, AI vs manual layouts).
  Widget _buildCurrentLhCard() {
    if (_tests.isEmpty) return const SizedBox.shrink();
    final latest = _tests.first;
    final isAi = latest.entryType == LhEntryType.aiScan;
    final isSurge = latest.surgeStatus == LhSurgeStatus.high ||
        latest.surgeStatus == LhSurgeStatus.peak;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.her.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isSurge
              ? const Color(0xFFC26D81).withValues(alpha: 0.5)
              : context.her.muted.withValues(alpha: 0.2),
          width: isSurge ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('CURRENT LH',
              style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.bold,
                  color: context.her.muted)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isAi
                          ? (latest.tcRatio?.toStringAsFixed(2) ?? '--')
                          : (latest.manualResult == LhManualResult.positive
                              ? 'Positive'
                              : 'Negative'),
                      style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFC26D81)),
                    ),
                    Text(
                      isAi ? 'T/C Ratio' : 'Result',
                      style: TextStyle(fontSize: 12, color: context.her.muted),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    latest.surgeStatus.name.toUpperCase(),
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: isSurge
                            ? const Color(0xFFC26D81)
                            : Colors.grey.shade600),
                  ),
                  Text(
                    isAi ? 'AI Scan' : 'Manual Entry',
                    style:
                        TextStyle(fontSize: 12, color: context.her.muted),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            DateFormat('MMM d, yyyy • h:mm a').format(latest.timestamp),
            style: TextStyle(fontSize: 12, color: context.her.muted),
          ),
        ],
      ),
    );
  }

  Widget _buildPredictionCard() {
    final pred = _prediction!;
    final shifted = pred.hasShifted;
    final shiftDays = pred.shiftDays;
    final predDate = pred.predictedOvulationDate;

    String shiftLabel;
    Color shiftColor;
    if (shifted && shiftDays < 0) {
      shiftLabel = '${shiftDays.abs()} day(s) earlier';
      shiftColor = Colors.orange;
    } else if (shifted && shiftDays > 0) {
      shiftLabel = '$shiftDays day(s) later';
      shiftColor = Colors.blue;
    } else {
      shiftLabel = 'On track';
      shiftColor = Colors.green;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFFC26D81).withValues(alpha: 0.08),
            const Color(0xFFC26D81).withValues(alpha: 0.03),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFC26D81).withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_graph, color: Color(0xFFC26D81), size: 20),
              const SizedBox(width: 8),
              const Text('Dynamic Ovulation Prediction',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Predicted Ovulation', style: TextStyle(fontSize: 12, color: context.her.muted)),
                    const SizedBox(height: 2),
                    Text(
                      DateFormat('MMM d, yyyy').format(predDate),
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFC26D81)),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: shiftColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  shiftLabel,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: shiftColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Estimated window ${DateFormat('MMM d').format(pred.windowStart)} – ${DateFormat('MMM d, yyyy').format(pred.windowEnd)}',
            style: TextStyle(fontSize: 13, color: context.her.muted),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _metricChip('Cycle Day ${pred.cycleDay}'),
              const SizedBox(width: 8),
              if (pred.currentTcRatio != null)
                _metricChip('T/C ${pred.currentTcRatio!.toStringAsFixed(2)}'),
              if (pred.currentTcRatio != null) const SizedBox(width: 8),
              if (pred.lhVelocity != null)
                _metricChip('Speed ${pred.lhVelocity!.toStringAsFixed(2)}/day'),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Confidence ${(pred.predictionConfidence * 100).round()}% — tracking aid, not a diagnosis.',
            style: TextStyle(fontSize: 11, color: context.her.muted),
          ),
        ],
      ),
    );
  }

  Widget _metricChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: context.her.ink)),
    );
  }

  Widget _buildProgressionGraph() {
    final quantitative = _tests
        .where((t) => t.tcRatio != null && t.entryType == LhEntryType.aiScan)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    if (quantitative.length < 2) return const SizedBox.shrink();

    final spots = <FlSpot>[];
    for (int i = 0; i < quantitative.length; i++) {
      spots.add(FlSpot(i.toDouble(), quantitative[i].tcRatio!));
    }

    final maxY = quantitative.map((t) => t.tcRatio!).reduce((a, b) => a > b ? a : b);
    final chartMaxY = (maxY * 1.2).clamp(0.5, 2.0);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.her.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.her.muted.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.show_chart, color: Color(0xFFC26D81), size: 20),
              const SizedBox(width: 8),
              const Text('LH Progression', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 200,
            child: LineChart(
              LineChartData(
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: chartMaxY / 4,
                  getDrawingHorizontalLine: (value) => FlLine(
                    color: Colors.grey.withValues(alpha: 0.15),
                    strokeWidth: 1,
                  ),
                ),
                titlesData: FlTitlesData(
                  show: true,
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 36,
                      interval: chartMaxY / 4,
                      getTitlesWidget: (value, meta) {
                        return Text(value.toStringAsFixed(1),
                            style: TextStyle(fontSize: 10, color: context.her.muted));
                      },
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 24,
                      getTitlesWidget: (value, meta) {
                        final idx = value.toInt();
                        if (idx < 0 || idx >= quantitative.length) return const SizedBox.shrink();
                        final d = quantitative[idx].timestamp;
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(DateFormat('M/d').format(d),
                              style: TextStyle(fontSize: 9, color: context.her.muted)),
                        );
                      },
                    ),
                  ),
                ),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    preventCurveOverShooting: true,
                    color: const Color(0xFFC26D81),
                    barWidth: 2.5,
                    isStrokeCapRound: true,
                    dotData: FlDotData(
                      show: true,
                      getDotPainter: (spot, percent, bar, index) {
                        final isSurge = quantitative[index].surgeStatus != LhSurgeStatus.low;
                        return FlDotCirclePainter(
                          radius: isSurge ? 5 : 3.5,
                          color: isSurge ? const Color(0xFFE91E63) : const Color(0xFFC26D81),
                          strokeColor: Colors.white,
                          strokeWidth: 1.5,
                        );
                      },
                    ),
                    belowBarData: BarAreaData(
                      show: true,
                      color: const Color(0xFFC26D81).withValues(alpha: 0.08),
                    ),
                  ),
                ],
                extraLinesData: ExtraLinesData(
                  horizontalLines: [
                    HorizontalLine(
                      y: LhPredictionEngine.surgeThreshold,
                      color: Colors.red.withValues(alpha: 0.4),
                      strokeWidth: 1,
                      dashArray: [6, 4],
                      label: HorizontalLineLabel(
                        show: true,
                        alignment: Alignment.topRight,
                        style: TextStyle(fontSize: 9, color: Colors.red.withValues(alpha: 0.6)),
                        labelResolver: (_) => 'Surge (0.8)',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExplanationCard() {
    final pred = _prediction!;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: Colors.blue.shade600),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              pred.explanation,
              style: TextStyle(fontSize: 13, color: context.her.ink, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryCard(LhTestEntry test) {
    final isAi = test.entryType == LhEntryType.aiScan;
    final isHigh = test.surgeStatus == LhSurgeStatus.high || test.surgeStatus == LhSurgeStatus.peak;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => LhTestDetailScreen(entry: test)),
      ),
      child: Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.her.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isHigh ? const Color(0xFFC26D81).withValues(alpha: 0.5) : context.her.muted.withValues(alpha: 0.2),
          width: isHigh ? 1.5 : 1,
        ),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 6, offset: const Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: isHigh ? const Color(0xFFC26D81).withValues(alpha: 0.15) : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              isAi ? Icons.camera_alt : Icons.edit_note,
              color: isHigh ? const Color(0xFFC26D81) : Colors.grey.shade600,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      DateFormat('MMM d, yyyy h:mm a').format(test.timestamp),
                      style: TextStyle(fontSize: 12, color: context.her.muted),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: isAi ? Colors.blue.withValues(alpha: 0.1) : Colors.purple.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        isAi ? 'AI Scan' : 'Manual',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: isAi ? Colors.blue.shade700 : Colors.purple.shade700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(
                      isAi
                          ? 'T/C: ${test.tcRatio?.toStringAsFixed(2) ?? "—"}'
                          : 'Result: ${test.manualResult == LhManualResult.positive ? "Positive" : "Negative"}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isHigh ? const Color(0xFFC26D81) : Colors.grey.shade400,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        test.surgeStatus.name.toUpperCase(),
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    ),
                    if (test.surgeVelocity != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        '${test.surgeVelocity! >= 0 ? "+" : ""}${test.surgeVelocity!.toStringAsFixed(2)}/day',
                        style: TextStyle(
                          fontSize: 11,
                          color: test.surgeVelocity! > 0 ? Colors.orange.shade700 : Colors.grey.shade600,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
                if (test.notes != null && test.notes!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(test.notes!, style: TextStyle(fontSize: 12, color: context.her.ink)),
                ],
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }
}
