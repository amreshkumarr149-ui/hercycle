import 'package:flutter/material.dart';
import 'package:hercycle/core/app_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hercycle/core/clinical_pdf_builder.dart';
import 'package:hercycle/core/clinical_report_engine.dart';
import 'package:hercycle/core/disease_risk_screener.dart';
import 'package:hercycle/core/premium_service.dart';
import 'package:hercycle/core/telemetry_service.dart';
import 'package:hercycle/models/daily_log.dart';
import 'package:hercycle/providers/clinical_data_provider.dart';
import 'package:printing/printing.dart';

/// Premium "HERcycle Deep Insight": a fixed 6-month deep analysis pass with
/// wellness recommendations and doctor-ready export.
///
/// Entry is gated by the caller (free-first-then-paid). When [freeEntry] is
/// true the free chance is consumed only after this screen renders a real
/// report successfully — a failed render never burns the freebie.
class DeepInsightScreen extends ConsumerStatefulWidget {
  final String uid;
  final bool freeEntry;
  const DeepInsightScreen(
      {super.key, required this.uid, required this.freeEntry});

  @override
  ConsumerState<DeepInsightScreen> createState() => _DeepInsightScreenState();
}

class _DeepInsightScreenState extends ConsumerState<DeepInsightScreen> {
  bool _consumeAttempted = false;

  void _maybeConsumeFree() {
    if (!widget.freeEntry || _consumeAttempted) return;
    _consumeAttempted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ok = await PremiumService.consumeFreeReport(widget.uid);
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Free report opened, but activation could not be confirmed (offline?). You will not lose your free chance.')),
        );
      }
    });
  }

  Future<void> _exportPremium(
      BuildContext context,
      ClinicalReport report,
      List<RiskAssessmentResult> risks,
      List<DailyLog> history) async {
    try {
      // Paid entries burn one unused receipt per export (one report per
      // pay). Without one, send the user back to the paywall instead of
      // silently re-prompting after download.
      if (!widget.freeEntry) {
        final consumed =
            await PremiumService.consumePaidReceipt(widget.uid);
        if (!context.mounted) return;
        if (!consumed) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'This payment was already used for a report. Please pay again for a fresh one.')),
          );
          Navigator.pop(context);
          return;
        }
      }
      final bytes = await buildClinicalPdf(
          report: report, screener: risks, history: history);
      await Printing.layoutPdf(
        onLayout: (format) async => bytes,
        name: 'HerCycle_Deep_Insight.pdf',
      );
      await TelemetryService.logEvent('pdf_exported_premium');
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not generate PDF: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    const primaryColor = Color(0xFFC26D81);
    final her = context.her;
    final dataAsync = ref.watch(clinicalDataProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Deep Insight ★ Premium',
            style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: dataAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load data: $e')),
        data: (data) {
          final logs = (data['logs'] as List<DailyLog>);
          final risks = data['risks'] as List<RiskAssessmentResult>;
          final report = ClinicalReportEngine.build(
            profile: data['user'] as Map<String, dynamic>?,
            allLogs: logs,
            windowDays: 180,
            fromCache: data['fromCache'] == true,
          );
          final recommendations =
              PremiumService.buildRecommendations(report);
          final cutoff = DateTime.now().subtract(const Duration(days: 180));
          final history180 = logs.where((l) {
            final d = DateTime.tryParse(l.date);
            return d != null && !d.isBefore(cutoff);
          }).toList();

          // Report rendered fine: safe to consume the free chance (once).
          _maybeConsumeFree();

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _premiumHeader(report, widget.freeEntry),
              _card(
                icon: Icons.table_chart_outlined,
                title: '6-Month Baselines',
                child: Column(
                  children: report.baselines
                      .map((b) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(b.name,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 13)),
                                      Text(b.value,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 15,
                                              color: primaryColor)),
                                    ],
                                  ),
                                ),
                                Text(b.tag,
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: her.muted)),
                              ],
                            ),
                          ))
                      .toList(),
                ),
              ),
              _card(
                icon: Icons.radar,
                title: 'Pattern Screening (6 months)',
                child: report.patterns.isEmpty
                    ? Text(
                        'No tracked patterns crossed screening thresholds.',
                        style: TextStyle(color: her.muted, fontSize: 13))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: report.patterns
                            .map((p) => Padding(
                                  padding:
                                      const EdgeInsets.only(bottom: 10),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                          'PATTERN IDENTIFIED: ${p.name}',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 13,
                                              color: primaryColor)),
                                      Text(
                                          '${p.observations} (${p.cycleCount} cycles)',
                                          style: const TextStyle(
                                              fontSize: 12, height: 1.4)),
                                    ],
                                  ),
                                ))
                            .toList(),
                      ),
              ),
              _card(
                icon: Icons.trending_up,
                title: 'Irregularity Trends',
                child: report.trends.isEmpty
                    ? Text(
                        'Not enough complete cycles to compare trends.',
                        style: TextStyle(color: her.muted, fontSize: 13))
                    : Column(
                        children: report.trends
                            .map((t) => Padding(
                                  padding:
                                      const EdgeInsets.only(bottom: 8),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 30,
                                        child: Text(t.indicator,
                                            style: const TextStyle(
                                                fontSize: 18,
                                                fontWeight:
                                                    FontWeight.bold)),
                                      ),
                                      Expanded(
                                        child: Text(
                                            '${t.name} — ${t.detail}',
                                            style: const TextStyle(
                                                fontSize: 13)),
                                      ),
                                    ],
                                  ),
                                ))
                            .toList(),
                      ),
              ),
              _card(
                icon: Icons.spa_outlined,
                title: 'Personalized Wellness Recommendations',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: recommendations
                      .map((r) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text('• $r',
                                style: const TextStyle(
                                    fontSize: 13, height: 1.5)),
                          ))
                      .toList(),
                ),
              ),
              _card(
                icon: Icons.assignment_outlined,
                title: 'Doctor-Ready Summary',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ...report.summaryBullets.map((s) => Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text('✓ $s',
                              style: const TextStyle(
                                  fontSize: 13, height: 1.5)),
                        )),
                    const SizedBox(height: 6),
                    Text(
                        'Reliability: ${report.reliability} • ${report.windowLabel}',
                        style: TextStyle(
                            fontSize: 12, color: her.muted)),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () =>
                      _exportPremium(context, report, risks, history180),
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Text('Export Deep Insight PDF'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text('Confidential Medical Record Summary',
                    style: TextStyle(
                        fontSize: 11,
                        color: her.muted,
                        fontStyle: FontStyle.italic)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _premiumHeader(ClinicalReport report, bool freeEntry) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF8E3A5B), Color(0xFFC26D81)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: Colors.pink.withValues(alpha: 0.15),
              blurRadius: 12,
              offset: const Offset(0, 4))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.workspace_premium_outlined,
                  color: Colors.amber),
              const SizedBox(width: 8),
              Text(freeEntry ? 'FREE Deep Insight 🎉' : 'Deep Insight ★',
                  style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${report.userName} • 6-month analysis • ${report.cyclesAnalyzed} complete cycles • generated ${report.generatedDate}',
            style:
                const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _card(
      {required IconData icon,
      required String title,
      required Widget child}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: context.her.card,
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
              Icon(icon, color: const Color(0xFFC26D81), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: context.her.ink)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}
