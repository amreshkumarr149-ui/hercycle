import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hercycle/core/clinical_report_engine.dart';
import 'package:hercycle/core/clinical_pdf_builder.dart';
import 'package:hercycle/core/premium_service.dart';
import 'package:hercycle/core/telemetry_service.dart';
import 'package:hercycle/core/x402_service.dart';
import 'package:hercycle/features/trends/deep_insight_screen.dart';
import 'package:hercycle/core/disease_risk_screener.dart';
import 'package:hercycle/models/daily_log.dart';
import 'package:hercycle/providers/clinical_data_provider.dart';
import 'package:printing/printing.dart';

class HealthReportsScreen extends ConsumerStatefulWidget {
  const HealthReportsScreen({super.key});

  @override
  ConsumerState<HealthReportsScreen> createState() => _HealthReportsScreenState();
}

class _HealthReportsScreenState extends ConsumerState<HealthReportsScreen> {
  final _searchController = TextEditingController();
  String _query = '';
  String? _month; // 'yyyy-MM'; null = all months
  int? _window = 90; // 30 / 90 / 180 / null = all history
  Future<PremiumAccess>? _accessFuture;

  @override
  void initState() {
    super.initState();
    _refreshAccess();
  }

  void _refreshAccess() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    _accessFuture = uid == null
        ? Future.value(PremiumAccess.locked)
        : PremiumService.getAccess(uid);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _openDeepInsight(bool freeEntry) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please log in first.')));
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => DeepInsightScreen(uid: uid, freeEntry: freeEntry)),
    );
    if (!mounted) return;
    setState(_refreshAccess);
  }

  /// Pay dialog wired to the LIVE x402 terms: it POSTs an unpaid probe to
  /// the premium server and renders the exact 402 payment requirements
  /// (price / asset / network / payTo). Falls back to the known server
  /// defaults when the server is unreachable.
  void _showPayDialog() {
    final userData =
        (ref.read(clinicalDataProvider).value?['user'] as Map<String, dynamic>?);
    final serverController = TextEditingController(
        text: userData?['x402ServerUrl']?.toString() ??
            X402Service.defaultServerUrl);
    X402Terms? terms;
    bool checking = true;
    bool live = false;
    final txController = TextEditingController();
    String? verifyMsg;
    bool verifying = false;

    /// Paid externally (any wallet / demo client)? Verify the tx id
    /// on-chain, record the receipt, and open the report directly —
    /// pay → verify → PDF, with no re-prompt in between.
    Future<void> verifyAndOpen(StateSetter setDialog) async {
      final txId = txController.text.trim();
      if (txId.isEmpty) {
        setDialog(() =>
            verifyMsg = 'Paste the TestNet transaction id first.');
        return;
      }
      setDialog(() {
        verifying = true;
        verifyMsg = null;
      });
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        setDialog(() {
          verifying = false;
          verifyMsg = 'Please log in first.';
        });
        return;
      }
      if (await PremiumService.txAlreadyUsed(uid, txId)) {
        setDialog(() {
          verifying = false;
          verifyMsg = 'This transaction was already redeemed for a report.';
        });
        return;
      }
      final result = await X402Service.verifyReceipt(
          serverUrl: serverController.text.trim(), txId: txId);
      if (!mounted) return;
      if (!result.verified) {
        setDialog(() {
          verifying = false;
          verifyMsg = result.reason ?? 'Payment not verified.';
        });
        return;
      }
      try {
        await PremiumService.addReceipt(
          uid,
          txId: result.txId ?? txId,
          inrPaise: PremiumService.priceInrPaise,
          usdcMicro: (result.amountMicro ?? 10000).toString(),
          fxRate: 'quoted-at-pay-time',
        );
        await TelemetryService.logEvent('premium_unlocked');
      } catch (e) {
        setDialog(() {
          verifying = false;
          verifyMsg =
              'Payment is valid on-chain, but saving the receipt failed: $e — retry.';
        });
        return;
      }
      if (!mounted) return;
      // ignore: use_build_context_synchronously
      Navigator.of(context).pop();
      _openDeepInsight(false);
    }

    Future<void> loadTerms(StateSetter setDialog) async {
      setDialog(() => checking = true);
      final t = await X402Service.fetchTerms(
          serverUrl: serverController.text.trim());
      if (!mounted) return;
      // Persist the working server URL for next time.
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        try {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(uid)
              .set({'x402ServerUrl': serverController.text.trim()},
                  SetOptions(merge: true));
        } catch (_) {}
      }
      if (!mounted) return;
      setDialog(() {
        terms = t ?? X402Terms.fallback;
        live = t != null;
        checking = false;
      });
    }

    showDialog(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (dialogContext, setDialog) {
          if (checking && terms == null) {
            // Kick off the first live fetch when the dialog opens.
            loadTerms(setDialog);
          }
          final shown = terms ?? X402Terms.fallback;
          return AlertDialog(
            title: const Text('Unlock Deep Insight ★'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Price',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      Text(PremiumService.priceInr,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 20,
                              color: Color(0xFFC26D81))),
                    ],
                  ),
                  Text(
                      '≈ ${PremiumService.priceUsdc} on Algorand TestNet${live ? ' — live from server' : ''}',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey[600])),
                  const SizedBox(height: 12),
                  TextField(
                    controller: serverController,
                    decoration: InputDecoration(
                      labelText: 'Premium server URL',
                      suffixIcon: IconButton(
                        icon: checking
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2))
                            : const Icon(Icons.refresh),
                        onPressed:
                            checking ? null : () => loadTerms(setDialog),
                      ),
                    ),
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF9F9F9),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: checking
                        ? const Text('Reading live 402 terms…',
                            style: TextStyle(fontSize: 12))
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Charge: ${shown.price}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13)),
                              Text('Asset: ${shown.asset}',
                                  style: const TextStyle(fontSize: 12)),
                              Text('Network: ${shown.network}',
                                  style: const TextStyle(fontSize: 11)),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                        'Pay to: ${shown.payTo}',
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontSize: 11,
                                            fontFamily: 'monospace')),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.copy, size: 16),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    onPressed: () {
                                      Clipboard.setData(ClipboardData(
                                          text: shown.payTo));
                                      ScaffoldMessenger.of(
                                              dialogContext)
                                          .showSnackBar(const SnackBar(
                                              content: Text(
                                                  'Merchant address copied')));
                                    },
                                  ),
                                ],
                              ),
                              if (!live)
                                const Text(
                                  'Server unreachable — showing last-known terms. Start it with server/README.',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontStyle: FontStyle.italic,
                                      color: Colors.grey),
                                ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'One payment unlocks one fresh 6-month Deep Insight report. Fund the payer wallet with TestNet USDC, run the demo client (server/README), and the facilitator settles it — receipt appears on the TestNet explorer.',
                    style: TextStyle(fontSize: 12, height: 1.5),
                  ),
                  const SizedBox(height: 12),
                  const Divider(),
                  const SizedBox(height: 4),
                  const Text('Already paid from any wallet?',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: txController,
                    decoration: const InputDecoration(
                      labelText: 'TestNet transaction id',
                      prefixIcon: Icon(Icons.receipt_long),
                    ),
                  ),
                  if (verifyMsg != null) ...[
                    const SizedBox(height: 6),
                    Text(verifyMsg!,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFFC62828))),
                  ],
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: verifying
                          ? null
                          : () => verifyAndOpen(setDialog),
                      icon: verifying
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.verified_outlined),
                      label: Text(verifying
                          ? 'Verifying on-chain…'
                          : 'Verify payment & open report'),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(d),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    ).then((_) {
      serverController.dispose();
      txController.dispose();
    });
  }

  /// Month keys for the filter chips: current + previous 5 months.
  List<DateTime> _recentMonths() {
    final now = DateTime.now();
    return List.generate(6, (i) => DateTime(now.year, now.month - i, 1));
  }

  List<DailyLog> _filtered(List<DailyLog> logs) {
    final q = _query.trim().toLowerCase();
    return logs.where((log) {
      if (_month != null && !log.date.startsWith(_month!)) return false;
      if (q.isEmpty) return true;
      final hay =
          '${log.date} ${log.mood} ${log.mucus} ${log.lhTest} ${log.flowIntensity} ${log.symptoms.join(' ')} ${log.notes}'
              .toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  Future<void> _exportPdf(
    BuildContext context,
    ClinicalReport report,
    List<RiskAssessmentResult> risks,
    List<DailyLog> history,
  ) async {
    try {
      final bytes = await buildClinicalPdf(
          report: report, screener: risks, history: history);
      await Printing.layoutPdf(
        onLayout: (format) async => bytes,
        name: 'HerCycle_Health_Report.pdf',
      );
      await TelemetryService.logEvent('pdf_exported');
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
    const ink = Color(0xFF4A4A4A);
    final reportAsync = ref.watch(clinicalDataProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Health Reports & Insights',
            style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: reportAsync.when(
        data: (data) {
          final risks = data['risks'] as List<RiskAssessmentResult>;
          final allLogs = (data['logs'] as List<DailyLog>);
          final report = ClinicalReportEngine.build(
            profile: data['user'] as Map<String, dynamic>?,
            allLogs: allLogs,
            windowDays: _window,
            fromCache: data['fromCache'] == true,
          );
          final filtered = _filtered(allLogs);

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // Premium Deep Insight paywall card.
              // free -> generate immediately; paid -> open directly, no
              // re-prompt; locked -> pay dialog with on-chain verification.
              FutureBuilder<PremiumAccess>(
                future: _accessFuture,
                builder: (context, snap) {
                  final checking = snap.connectionState ==
                      ConnectionState.waiting;
                  final access = snap.data ?? PremiumAccess.locked;
                  final free = access == PremiumAccess.free;
                  final paid = access == PremiumAccess.paid;
                  return Container(
                    width: double.infinity,
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
                            const Icon(
                                Icons.workspace_premium_outlined,
                                color: Colors.amber),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                  'HERcycle Deep Insight ★ Premium',
                                  style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white)),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                  checking
                                      ? '…'
                                      : free
                                          ? 'FIRST FREE 🎉'
                                          : paid
                                              ? 'PAID ✓'
                                              : PremiumService.priceInr,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '6-month cycle analysis • symptom patterns • irregularity trends • wellness recommendations • doctor-ready summary',
                          style: TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              height: 1.5),
                        ),
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                            child: ElevatedButton(
                            onPressed: checking
                                ? null
                                : () => free
                                    ? _openDeepInsight(true)
                                    : paid
                                        ? _openDeepInsight(false)
                                        : _showPayDialog(),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor:
                                  const Color(0xFF8E3A5B),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                            ),
                            child: Text(checking
                                ? 'Checking…'
                                : free
                                    ? 'Generate FREE Deep Insight 🎉'
                                    : paid
                                        ? 'Open Paid Report ✓'
                                        : 'Unlock — ${PremiumService.priceInr}'),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 20),
              // Window selector
              Wrap(
                spacing: 8,
                children: [
                  for (final opt in const [30, 90, 180])
                    ChoiceChip(
                      label: Text('$opt days'),
                      selected: _window == opt,
                      onSelected: (_) => setState(() => _window = opt),
                    ),
                  ChoiceChip(
                    label: const Text('All history'),
                    selected: _window == null,
                    onSelected: (_) => setState(() => _window = null),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ---- REPORT HEADER ----
              SectionCard(
                icon: Icons.medical_information_outlined,
                title: 'HerCycle Clinical Health Report',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv('Name', report.userName),
                    _kv('Age', report.age),
                    _kv('Report date', report.generatedDate),
                    _kv('Reporting period', report.windowLabel),
                    _kv('Tracking history', report.trackingDuration),
                    _kv('Tracking mode', report.trackingMode),
                    _kv('Confidential Medical Record Summary',
                        'Private to the user'),
                  ],
                ),
              ),

              // ---- DISCLAIMER ----
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: const Text(
                  'MEDICAL DISCLAIMER — This report is generated automatically from user-entered symptoms, cycle history, and physiological tracking data. HerCycle is an educational and health-tracking tool and is not a substitute for professional medical diagnosis, treatment, or medical advice.',
                  style: TextStyle(fontSize: 12, height: 1.5, color: ink),
                ),
              ),
              const SizedBox(height: 20),

              // ---- 1. BASELINES ----
              SectionCard(
                icon: Icons.table_chart_outlined,
                title: '1. Baseline Cycle Averages',
                child: Column(
                  children: report.baselines
                      .map((b) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      child: Text(b.name,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 13)),
                                    ),
                                    _tagChip(b.tag),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(b.value,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                        color: primaryColor)),
                                Text(b.reference,
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey[600])),
                              ],
                            ),
                          ))
                      .toList(),
                ),
              ),

              // ---- 2. PATTERN SCREENING ----
              SectionCard(
                icon: Icons.radar,
                title: '2. Automated Pattern Screening',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (report.patterns.isEmpty)
                      const Text(
                          'No tracked patterns crossed screening thresholds in this period.',
                          style:
                              TextStyle(color: Colors.grey, fontSize: 13)),
                    ...report.patterns.map((p) => Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF9F9),
                            borderRadius: BorderRadius.circular(14),
                            border:
                                Border.all(color: Colors.orange.shade200),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('PATTERN IDENTIFIED: ${p.name}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: primaryColor)),
                              const SizedBox(height: 6),
                              _patternLine('Algorithm trigger', p.trigger),
                              _patternLine(
                                  'Observations', p.observations),
                              _patternLine('Cycles affected',
                                  '${p.cycleCount} • ${p.dates.take(4).join(', ')}'),
                              _patternLine(
                                  'Clinical context', p.context),
                              _patternLine(
                                  'Recommended next step', p.nextStep),
                            ],
                          ),
                        )),
                    const SizedBox(height: 8),
                    const Text('Condition-pattern screening',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14)),
                    const SizedBox(height: 8),
                    ...risks.map((risk) => Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                                color: risk.isFlagged
                                    ? Colors.red.shade300
                                    : Colors.grey.shade200),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                risk.isFlagged
                                    ? Icons.warning_amber_rounded
                                    : Icons.check_circle_outline,
                                color: risk.isFlagged
                                    ? Colors.red
                                    : Colors.green,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(risk.title,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 14)),
                                    const SizedBox(height: 4),
                                    Text(risk.description,
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey[700],
                                            height: 1.4)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        )),
                  ],
                ),
              ),

              // ---- 3. CYCLE PHASE LOGS ----
              SectionCard(
                icon: Icons.view_timeline_outlined,
                title: '3. Detailed Cycle Phase Logs',
                child: report.cycles.isEmpty
                    ? const Text('No tracked cycles in this period.',
                        style: TextStyle(color: Colors.grey, fontSize: 13))
                    : Column(
                        children: report.cycles.reversed.map((c) {
                          final ovuLabel = c.ovulationConfirmed
                              ? 'confirmed ${_d(c.confirmedOvulation!)}'
                              : (c.estimatedOvulation != null
                                  ? 'estimated ${_d(c.estimatedOvulation!)}'
                                  : 'not enough data');
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              border:
                                  Border.all(color: Colors.grey.shade200),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: ExpansionTile(
                              title: Text(
                                'Cycle #${c.number} • ${_d(c.start)} → ${c.end != null ? _d(c.end!) : 'ongoing'}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13),
                              ),
                              subtitle: Text(
                                '${c.length != null ? '${c.length} days' : 'length TBD'} • bleeding ${c.bleedingDays}d • ovulation $ovuLabel',
                                style: const TextStyle(fontSize: 12),
                              ),
                              children: [
                                if (c.days.isEmpty)
                                  const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: Text(
                                        'No day-level logs in this cycle.',
                                        style: TextStyle(
                                            color: Colors.grey,
                                            fontSize: 12)),
                                  )
                                else
                                  ..._phaseGroups(c).entries.map((entry) =>
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12, vertical: 4),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(entry.key,
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.bold,
                                                    fontSize: 12,
                                                    color: primaryColor)),
                                            ...entry.value.map((l) =>
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                          left: 8,
                                                          top: 2,
                                                          bottom: 2),
                                                  child: Text(
                                                    _dayLine(l),
                                                    style: const TextStyle(
                                                        fontSize: 12,
                                                        height: 1.5),
                                                  ),
                                                )),
                                          ],
                                        ),
                                      )),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
              ),

              // ---- 4. TRENDS ----
              SectionCard(
                icon: Icons.trending_up,
                title: '4. Trend Analysis',
                child: report.trends.isEmpty
                    ? const Text(
                        'Not enough complete cycles to compare trends.',
                        style: TextStyle(color: Colors.grey, fontSize: 13))
                    : Column(
                        children: report.trends
                            .map((t) => Padding(
                                  padding:
                                      const EdgeInsets.only(bottom: 10),
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
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(t.name,
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.w600,
                                                    fontSize: 13)),
                                            Text(t.detail,
                                                style: TextStyle(
                                                    fontSize: 12,
                                                    color:
                                                        Colors.grey[600])),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ))
                            .toList(),
                      ),
              ),

              // ---- 5. SYMPTOM SUMMARY ----
              SectionCard(
                icon: Icons.summarize_outlined,
                title: '5. Symptom Summary',
                child: report.symptoms.isEmpty
                    ? const Text('No symptoms logged in this period.',
                        style: TextStyle(color: Colors.grey, fontSize: 13))
                    : Column(
                        children: report.symptoms
                            .map((s) => Padding(
                                  padding:
                                      const EdgeInsets.only(bottom: 10),
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(s.name,
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.w600,
                                                    fontSize: 13)),
                                            Text(
                                                '${s.occurrences} days • ${s.cyclesAffected} cycles • usually ${s.typicalPhase} • recent ${s.recent}',
                                                style: TextStyle(
                                                    fontSize: 12,
                                                    color:
                                                        Colors.grey[600])),
                                          ],
                                        ),
                                      ),
                                      Text(s.avgSeverity,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              color: primaryColor)),
                                    ],
                                  ),
                                ))
                            .toList(),
                      ),
              ),

              // ---- 6. INSIGHTS ----
              SectionCard(
                icon: Icons.lightbulb_outline,
                title: '6. Personalized Insights',
                child: report.insights.isEmpty
                    ? const Text(
                        'Not enough tracked data for personalized insights yet — keep logging daily.',
                        style: TextStyle(color: Colors.grey, fontSize: 13))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: report.insights
                            .map((i) => Padding(
                                  padding:
                                      const EdgeInsets.only(bottom: 8),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text('💡 ',
                                          style: TextStyle(fontSize: 13)),
                                      Expanded(
                                          child: Text(i,
                                              style: const TextStyle(
                                                  fontSize: 13,
                                                  height: 1.5))),
                                    ],
                                  ),
                                ))
                            .toList(),
                      ),
              ),

              // ---- 7. FLAGS ----
              if (report.urgentMessage != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFEBEE),
                    borderRadius: BorderRadius.circular(16),
                    border:
                        Border.all(color: Colors.red, width: 1.5),
                  ),
                  child: Text(report.urgentMessage!,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFC62828),
                          fontSize: 13,
                          height: 1.5)),
                ),
              if (report.urgentMessage != null)
                const SizedBox(height: 12),
              SectionCard(
                icon: Icons.flag_outlined,
                title: '7. Health Attention Flags',
                child: report.attentionFlags.isEmpty
                    ? const Text('No attention flags in this period.',
                        style: TextStyle(color: Colors.grey, fontSize: 13))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: report.attentionFlags
                            .map((f) => Padding(
                                  padding:
                                      const EdgeInsets.only(bottom: 8),
                                  child: Text('• $f',
                                      style: const TextStyle(
                                          fontSize: 13, height: 1.5)),
                                ))
                            .toList(),
                      ),
              ),

              // ---- 8. DATA QUALITY ----
              SectionCard(
                icon: Icons.verified_outlined,
                title: '8. Data Quality',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv('Cycles analysed', '${report.cyclesAnalyzed}'),
                    _kv('Days logged',
                        '${report.daysLogged} of ~${report.spanDays} days'),
                    _kv('Reliability', report.reliability),
                    const SizedBox(height: 6),
                    Text(report.dataQualityNote,
                        style: const TextStyle(fontSize: 13, height: 1.5)),
                  ],
                ),
              ),

              // ---- 9. SUMMARY ----
              SectionCard(
                icon: Icons.assignment_outlined,
                title: '9. Report Summary',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: report.summaryBullets
                      .map((s) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('✓ ',
                                    style: TextStyle(
                                        color: Colors.green,
                                        fontWeight: FontWeight.bold)),
                                Expanded(
                                    child: Text(s,
                                        style: const TextStyle(
                                            fontSize: 13, height: 1.5))),
                              ],
                            ),
                          ))
                      .toList(),
                ),
              ),

              // ---- 10. HISTORY + EXPORT ----
              SectionCard(
                icon: Icons.history,
                title: '10. Log History (date-wise)',
                child: Column(
                  children: [
                    TextField(
                      controller: _searchController,
                      decoration: const InputDecoration(
                        labelText: 'Search by date, mood, symptom…',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (v) => setState(() => _query = v),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 40,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: const Text('All'),
                              selected: _month == null,
                              onSelected: (_) =>
                                  setState(() => _month = null),
                            ),
                          ),
                          ..._recentMonths().map((m) {
                            final key =
                                '${m.year.toString().padLeft(4, '0')}-${m.month.toString().padLeft(2, '0')}';
                            const names = [
                              'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                              'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
                            ];
                            return Padding(
                              padding:
                                  const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text('${names[m.month - 1]} ${m.year}'),
                                selected: _month == key,
                                onSelected: (_) =>
                                    setState(() => _month = key),
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (filtered.isEmpty)
                      const Text('No logs match this search.',
                          style:
                              TextStyle(color: Colors.grey, fontSize: 13))
                    else
                      ...filtered.take(60).map((log) {
                        final syms = log.symptoms.map((s) {
                          final sc = log.symptomIntensity[s];
                          return sc != null ? '$s $sc/10' : s;
                        }).join(', ');
                        final details = [
                          if (log.period)
                            '🩸 Period (flow: ${log.flowIntensity})',
                          if (log.mood.isNotEmpty) '😊 ${log.mood}',
                          if (syms.isNotEmpty) '💧 $syms',
                          if (log.mucus.isNotEmpty)
                            '💧 Mucus: ${log.mucus.replaceAll('\n', ' ')}',
                          if (log.lhTest.isNotEmpty)
                            '⚲ LH: ${log.lhTest}',
                          if (log.painScore > 0)
                            '🤕 Pain ${log.painScore}/10',
                          if (log.pelvicPressure) '◉ Pelvic pressure',
                          if (log.backBowelPain) '◉ Back/bowel pain',
                          if (log.notes.trim().isNotEmpty)
                            '📝 ${log.notes.trim()}',
                        ].join('\n');
                        return Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF9F9),
                            borderRadius: BorderRadius.circular(14),
                            border:
                                Border.all(color: Colors.grey.shade200),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(log.date,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF4A4A4A),
                                      fontSize: 13)),
                              const SizedBox(height: 4),
                              Text(
                                  details.isEmpty ? 'Empty log.' : details,
                                  style: const TextStyle(
                                      fontSize: 12,
                                      height: 1.6,
                                      color: Color(0xFF4A4A4A))),
                            ],
                          ),
                        );
                      }),
                    if (filtered.length > 60)
                      Text(
                          'Showing latest 60 of ${filtered.length} — the PDF includes all.',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey[600])),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () =>
                      _exportPdf(context, report, risks, filtered),
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Text('Export Doctor\'s PDF Report'),
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
              const Center(
                child: Text('Confidential Medical Record Summary',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey,
                        fontStyle: FontStyle.italic)),
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            Center(child: Text('Error loading clinical reports: $e')),
      ),
    );
  }

  Map<String, List<DailyLog>> _phaseGroups(CycleRecord c) {
    final groups = <String, List<DailyLog>>{};
    for (final l in c.days) {
      final d = DateTime.tryParse(l.date);
      final ph = d == null
          ? 'Logged days'
          : ClinicalReportEngine.phaseLabel(
              ClinicalReportEngine.phaseOf(
                  c, DateTime(d.year, d.month, d.day)));
      final label = ph == '—' ? 'Logged days' : '$ph Phase';
      groups.putIfAbsent(label, () => []).add(l);
    }
    // Stable phase order.
    const order = [
      'Menstrual Phase',
      'Follicular Phase',
      'Ovulation Phase',
      'Luteal Phase',
      'Logged days'
    ];
    final sorted = <String, List<DailyLog>>{};
    for (final k in order) {
      if (groups.containsKey(k)) sorted[k] = groups[k]!;
    }
    return sorted;
  }

  String _dayLine(DailyLog l) {
    final bits = <String>[];
    if (l.period) bits.add('🩸 period (${l.flowIntensity})');
    if (l.mood.isNotEmpty) bits.add(l.mood);
    if (l.symptoms.isNotEmpty) {
      bits.add(l.symptoms.map((s) {
        final sc = l.symptomIntensity[s];
        return sc != null ? '$s $sc/10' : s;
      }).join(', '));
    }
    if (l.mucus.isNotEmpty) bits.add('mucus ${l.mucus.replaceAll('\n', ' ')}');
    if (l.lhTest.isNotEmpty) bits.add('LH ${l.lhTest}');
    if (l.painScore > 0) bits.add('pain ${l.painScore}/10');
    if (l.pelvicPressure) bits.add('pelvic pressure');
    if (l.backBowelPain) bits.add('back/bowel pain');
    if (l.notes.trim().isNotEmpty) bits.add('📝 ${l.notes.trim()}');
    return '${l.date} — ${bits.isEmpty ? 'no details' : bits.join(' • ')}';
  }
}

class SectionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;
  const SectionCard(
      {super.key,
      required this.icon,
      required this.title,
      required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
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
      child: Material(
        // Ink canvas for tiles (e.g. ExpansionTile headers) inside the card:
        // without it the framework throws "ink splashes may be invisible".
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: const Color(0xFFC26D81), size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF4A4A4A))),
                ),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

Widget _kv(String label, String value) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: Text(label,
              style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        ),
        Expanded(
          child: Text(value,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF4A4A4A))),
        ),
      ],
    ),
  );
}

Widget _tagChip(String tag) {
  final Color color;
  switch (tag) {
    case 'Normal':
    case 'Mild':
      color = Colors.green;
      break;
    case 'Elevated':
      color = Colors.red;
      break;
    case 'Moderate':
    case 'Variable':
    case 'Somewhat variable':
      color = Colors.orange;
      break;
    case 'Lower than typical':
      color = Colors.blue;
      break;
    default:
      color = Colors.grey;
  }
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(tag,
        style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.bold, color: color)),
  );
}

Widget _patternLine(String label, String value) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: RichText(
      text: TextSpan(
        style: const TextStyle(fontSize: 12, height: 1.4, color: Color(0xFF4A4A4A)),
        children: [
          TextSpan(
              text: '$label: ',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          TextSpan(text: value),
        ],
      ),
    ),
  );
}

String _d(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
