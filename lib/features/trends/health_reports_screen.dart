import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:hercycle/core/app_theme.dart';
import 'package:hercycle/core/widgets/animations.dart';
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
import 'package:hercycle/providers/auth_user_provider.dart';
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
    final uid = safeCurrentUid();
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
    final uid = safeCurrentUid();
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
    // valueOrNull: the provider may still be loading (or failed offline)
    // when the dialog opens — .value would throw and crash the tap.
    final userData = (ref.read(clinicalDataProvider).valueOrNull?['user']
        as Map<String, dynamic>?);
    final serverController = TextEditingController(
        text: userData?['x402ServerUrl']?.toString() ??
            X402Service.defaultServerUrl);
    X402Terms? terms;
    bool checking = true;
    bool live = false;
    final txController = TextEditingController();
    String? verifyMsg;
    bool verifying = false;
    final dialogUid = safeCurrentUid();
    final Future<List<PremiumReceipt>>? receiptsFuture =
        dialogUid == null ? null : PremiumService.listReceipts(dialogUid);

    /// 3-step progress header: Terms → Pay → Verify.
    Widget paySteps(int active) {
      const labels = ['Terms', 'Pay', 'Verify'];
      return Row(
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            if (i > 0)
              Expanded(
                child: Container(
                  height: 2,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  color: i <= active
                      ? const Color(0xFFC26D81)
                      : Colors.grey.shade300,
                ),
              ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < active
                        ? Colors.green
                        : i == active
                            ? const Color(0xFFC26D81)
                            : Colors.grey.shade300,
                  ),
                  child: Center(
                    child: i < active
                        ? const Icon(Icons.check,
                            size: 14, color: Colors.white)
                        : Text('${i + 1}',
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.white)),
                  ),
                ),
                const SizedBox(height: 2),
                Text(labels[i], style: const TextStyle(fontSize: 10)),
              ],
            ),
          ],
        ],
      );
    }

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
      final uid = safeCurrentUid();
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

    // Rebuild guard: the builder kicks off loadTerms while checking, and
    // every setDialog rebuilds — without this flag each rebuild would fire
    // another concurrent 402 POST storm until the first one lands.
    bool loadingTerms = false;

    Future<void> loadTerms(StateSetter setDialog) async {
      if (loadingTerms) return;
      loadingTerms = true;
      try {
        setDialog(() => checking = true);
        final t = await X402Service.fetchTerms(
            serverUrl: serverController.text.trim());
        if (!mounted) return;
        // Persist the working server URL for next time.
        final uid = safeCurrentUid();
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
      } finally {
        loadingTerms = false;
      }
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
          final step = checking ? 0 : (verifying ? 2 : 1);
          return AlertDialog(
            title: Row(
              children: [
                const Expanded(
                    child: Text('Unlock Deep Insight ★')),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: (live ? Colors.green : Colors.orange)
                        .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    checking ? '…' : (live ? 'LIVE' : 'OFFLINE'),
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: live
                            ? Colors.green.shade700
                            : Colors.orange.shade800),
                  ),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  paySteps(step),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [
                          Color(0xFF8E3A5B),
                          Color(0xFFC26D81)
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(shown.price,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 22,
                                    color: Colors.white)),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.white
                                    .withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(shown.networkLabel,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                            '≈ ${PremiumService.priceInr} • ${shown.asset}${live ? ' • live from server' : ''}',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12)),
                        if (shown.facilitator.isNotEmpty)
                          Text('Settled via ${shown.facilitator}',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 11)),
                        if (shown.isMainnet)
                          const Row(
                            children: [
                              Icon(Icons.warning_amber_rounded,
                                  size: 14, color: Colors.amber),
                              SizedBox(width: 4),
                              Text('Real MainNet funds — double-check!',
                                  style: TextStyle(
                                      color: Colors.amber,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                      ],
                    ),
                  ),
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
                      color: dialogContext.her.card,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: dialogContext.her.muted.withValues(alpha: 0.3)),
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
                                    tooltip: 'Copy merchant address',
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
                                  IconButton(
                                    icon: const Icon(
                                        Icons.open_in_new, size: 16),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    tooltip:
                                        'Copy block-explorer link',
                                    onPressed: () {
                                      final url =
                                          X402Service.explorerAccountUrl(
                                              shown.network,
                                              shown.payTo);
                                      if (url == null) return;
                                      Clipboard.setData(
                                          ClipboardData(text: url));
                                      ScaffoldMessenger.of(
                                              dialogContext)
                                          .showSnackBar(const SnackBar(
                                              content: Text(
                                                  'Explorer link copied')));
                                    },
                                  ),
                                ],
                              ),
                              if (!live)
                                Text(
                                  'Server unreachable — showing last-known terms. Start it with server/README.',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontStyle: FontStyle.italic,
                                      color: dialogContext.her.muted),
                                ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'One payment unlocks one fresh 6-month Deep Insight report. Fund the payer wallet with ${shown.networkLabel} USDC, run the demo client (server/README), and the facilitator settles it — the receipt is verifiable on the block explorer.',
                    style: const TextStyle(fontSize: 12, height: 1.5),
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
                  if (receiptsFuture != null) ...[
                    const SizedBox(height: 8),
                    FutureBuilder<List<PremiumReceipt>>(
                      future: receiptsFuture,
                      builder: (c, snap) {
                        final items = snap.data ?? const <PremiumReceipt>[];
                        if (!snap.hasData || items.isEmpty) {
                          return const SizedBox.shrink();
                        }
                        return ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: Text('My payments (${items.length})',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13)),
                          children: [
                            for (final r in items)
                              Padding(
                                padding:
                                    const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: (r.used
                                                ? Colors.grey
                                                : Colors.green)
                                            .withValues(alpha: 0.15),
                                        borderRadius:
                                            BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                          r.used ? 'USED' : 'READY',
                                          style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: r.used
                                                  ? Colors.grey.shade700
                                                  : Colors.green
                                                      .shade700)),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(r.shortId,
                                              style: const TextStyle(
                                                  fontSize: 12,
                                                  fontFamily: 'monospace')),
                                          if (r.createdAt != null)
                                            Text(
                                                '${r.createdAt!.year}-${r.createdAt!.month.toString().padLeft(2, '0')}-${r.createdAt!.day.toString().padLeft(2, '0')}',
                                                style: TextStyle(
                                                    fontSize: 11,
                                                    color: dialogContext.her.muted)),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.copy,
                                          size: 16),
                                      padding: EdgeInsets.zero,
                                      constraints:
                                          const BoxConstraints(),
                                      tooltip: 'Copy transaction id',
                                      onPressed: () {
                                        Clipboard.setData(ClipboardData(
                                            text: r.txId));
                                        ScaffoldMessenger.of(
                                                dialogContext)
                                            .showSnackBar(
                                                const SnackBar(
                                                    content: Text(
                                                        'Transaction id copied')));
                                      },
                                    ),
                                    IconButton(
                                      icon: const Icon(
                                          Icons.open_in_new, size: 16),
                                      padding: EdgeInsets.zero,
                                      constraints:
                                          const BoxConstraints(),
                                      tooltip:
                                          'Copy block-explorer link',
                                      onPressed: () {
                                        final url = X402Service
                                            .explorerTxUrl(
                                                shown.network, r.txId);
                                        if (url == null) return;
                                        Clipboard.setData(
                                            ClipboardData(text: url));
                                        ScaffoldMessenger.of(
                                                dialogContext)
                                            .showSnackBar(
                                                const SnackBar(
                                                    content: Text(
                                                        'Explorer link copied')));
                                      },
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
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
    final her = context.her;
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
                    _kv(her, 'Name', report.userName),
                    _kv(her, 'Age', report.age),
                    _kv(her, 'Report date', report.generatedDate),
                    _kv(her, 'Reporting period', report.windowLabel),
                    _kv(her, 'Tracking history', report.trackingDuration),
                    _kv(her, 'Tracking mode', report.trackingMode),
                    _kv(her, 'Confidential Medical Record Summary',
                        'Private to the user'),
                  ],
                ),
              ),

              // ---- DISCLAIMER ----
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: Text(
                  'MEDICAL DISCLAIMER — This report is generated automatically from user-entered symptoms, cycle history, and physiological tracking data. HerCycle is an educational and health-tracking tool and is not a substitute for professional medical diagnosis, treatment, or medical advice.',
                  style: TextStyle(fontSize: 12, height: 1.5, color: her.ink),
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
                                        color: her.muted)),
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
                      Text(
                          'No tracked patterns crossed screening thresholds in this period.',
                          style:
                              TextStyle(color: her.muted, fontSize: 13)),
                    ...report.patterns.map((p) => Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.pink.withValues(alpha: 0.06),
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
                              _patternLine(her, 'Algorithm trigger', p.trigger),
                              _patternLine(her,
                                  'Observations', p.observations),
                              _patternLine(her, 'Cycles affected',
                                  '${p.cycleCount} • ${p.dates.take(4).join(', ')}'),
                              _patternLine(her,
                                  'Clinical context', p.context),
                              _patternLine(her,
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
                            color: her.card,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                                color: risk.isFlagged
                                    ? Colors.red.shade300
                                    : her.muted.withValues(alpha: 0.3)),
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
                                            color: her.muted,
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
                    ? Text('No tracked cycles in this period.',
                        style: TextStyle(color: her.muted, fontSize: 13))
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
                                  Border.all(color: her.muted.withValues(alpha: 0.3)),
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

              // ---- VISUAL: CYCLE LENGTH & BLEEDING ----
              FadeSlideIn(
                delay: const Duration(milliseconds: 120),
                child: _cycleBarCard(report),
              ),

              const SizedBox(height: 24),

              // ---- VISUAL: CYCLE PHASE PIE ----
              FadeSlideIn(
                delay: const Duration(milliseconds: 160),
                child: _phasePieCard(report),
              ),

              const SizedBox(height: 24),

              // ---- 4. TRENDS ----
              SectionCard(
                icon: Icons.trending_up,
                title: '4. Trend Analysis',
                child: report.trends.isEmpty
                    ? Text(
                        'Not enough complete cycles to compare trends.',
                        style: TextStyle(color: her.muted, fontSize: 13))
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
                                                        her.muted)),
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
                    ? Text('No symptoms logged in this period.',
                        style: TextStyle(color: her.muted, fontSize: 13))
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
                                                        her.muted)),
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

              // ---- VISUAL: SYMPTOM SHARE PIE ----
              FadeSlideIn(
                delay: const Duration(milliseconds: 200),
                child: _symptomPieCard(report),
              ),

              const SizedBox(height: 24),

              // ---- VISUAL: MOOD SPLIT PIE ----
              FadeSlideIn(
                delay: const Duration(milliseconds: 240),
                child: _moodPieCard(report),
              ),

              const SizedBox(height: 24),

              // ---- VISUAL: FLOW INTENSITY BARS ----
              FadeSlideIn(
                delay: const Duration(milliseconds: 280),
                child: _flowBarCard(report),
              ),

              const SizedBox(height: 24),

              // ---- VISUAL: MOOD TREND ----
              FadeSlideIn(
                delay: const Duration(milliseconds: 320),
                child: _moodTrendCard(report),
              ),

              const SizedBox(height: 24),

              // ---- VISUAL: PAIN TREND ----
              FadeSlideIn(
                delay: const Duration(milliseconds: 360),
                child: _painTrendCard(report),
              ),

              const SizedBox(height: 24),

              // ---- 6. INSIGHTS ----
              SectionCard(
                icon: Icons.lightbulb_outline,
                title: '6. Personalized Insights',
                child: report.insights.isEmpty
                    ? Text(
                        'Not enough tracked data for personalized insights yet — keep logging daily.',
                        style: TextStyle(color: her.muted, fontSize: 13))
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
                    ? Text('No attention flags in this period.',
                        style: TextStyle(color: her.muted, fontSize: 13))
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
                    _kv(her, 'Cycles analysed', '${report.cyclesAnalyzed}'),
                    _kv(her, 'Days logged',
                        '${report.daysLogged} of ~${report.spanDays} days'),
                    _kv(her, 'Reliability', report.reliability),
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
                      Text('No logs match this search.',
                          style:
                              TextStyle(color: her.muted, fontSize: 13))
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
                            color: Colors.pink.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(14),
                            border:
                                Border.all(color: her.muted.withValues(alpha: 0.3)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(log.date,
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: her.ink,
                                      fontSize: 13)),
                              const SizedBox(height: 4),
                              Text(
                                  details.isEmpty ? 'Empty log.' : details,
                                  style: TextStyle(
                                      fontSize: 12,
                                      height: 1.6,
                                      color: her.ink)),
                            ],
                          ),
                        );
                      }),
                    if (filtered.length > 60)
                      Text(
                          'Showing latest 60 of ${filtered.length} — the PDF includes all.',
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

  static const _pieColors = [
    Color(0xFFC26D81),
    Color(0xFFE29578),
    Color(0xFF83C5BE),
    Color(0xFFCE93D8),
    Color(0xFFF9C8D2),
    Color(0xFF81C784),
  ];

  static const _moodColors = [
    Color(0xFFC26D81),
    Color(0xFFE29578),
    Color(0xFF83C5BE),
    Color(0xFFCE93D8),
    Color(0xFF81C784),
    Color(0xFF64B5F6),
    Color(0xFFFFB74D),
    Color(0xFFA1887F),
  ];

  static const _phaseColors = {
    'Menstrual': Color(0xFFE53935),
    'Follicular': Color(0xFFFB8C00),
    'Ovulation': Color(0xFF2E9E57),
    'Luteal': Color(0xFF7B4B94),
    'Logged': Color(0xFF90A4AE),
  };

  Widget _chartLegendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(fontSize: 11, color: context.her.muted)),
      ],
    );
  }

  /// Grouped bars per cycle: total length vs bleeding days. Screen-only.
  Widget _cycleBarCard(ClinicalReport report) {
    final cycles =
        report.cycles.where((c) => c.length != null).toList();
    if (cycles.length < 2) {
      return SectionCard(
        icon: Icons.bar_chart_outlined,
        title: 'Cycle Length & Bleeding',
        child: Text(
            'Log at least 2 complete cycles to see lengths and bleeding days side by side.',
            style: TextStyle(color: context.her.muted, fontSize: 13)),
      );
    }
    final maxLen =
        cycles.map((c) => c.length!).reduce((a, b) => a > b ? a : b);
    return SectionCard(
      icon: Icons.bar_chart_outlined,
      title: 'Cycle Length & Bleeding',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _chartLegendDot(const Color(0xFFC26D81), 'Cycle days'),
              const SizedBox(width: 12),
              _chartLegendDot(const Color(0xFF83C5BE), 'Bleeding days'),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 210,
            child: BarChart(
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              BarChartData(
                maxY: (maxLen + 2).toDouble(),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (value) => FlLine(
                    color:
                        context.her.muted.withValues(alpha: 0.25),
                    strokeWidth: 1,
                  ),
                ),
                borderData: FlBorderData(
                  show: true,
                  border: Border.all(
                      color: context.her.muted.withValues(alpha: 0.4)),
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
                        style: TextStyle(
                            fontSize: 10, color: context.her.muted),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: 1,
                      getTitlesWidget: (value, meta) {
                        final i = value.toInt();
                        if (i < 0 || i >= cycles.length) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '#${cycles[i].number}',
                            style: TextStyle(
                                fontSize: 10,
                                color: context.her.muted),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                barTouchData: BarTouchData(
                  enabled: true,
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipColor: (_) => context.her.card,
                    getTooltipItem:
                        (group, groupIndex, rod, rodIndex) {
                      final c = cycles[group.x.toInt()];
                      return BarTooltipItem(
                        'Cycle #${c.number}\n',
                        TextStyle(
                            color: context.her.muted, fontSize: 11),
                        children: [
                          TextSpan(
                            text:
                                '${c.length} days • 🩸 ${c.bleedingDays}d',
                            style: TextStyle(
                                color: context.her.ink,
                                fontWeight: FontWeight.bold,
                                fontSize: 13),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                barGroups: [
                  for (var i = 0; i < cycles.length; i++)
                    BarChartGroupData(
                      x: i,
                      barsSpace: 4,
                      barRods: [
                        BarChartRodData(
                          toY: cycles[i].length!.toDouble(),
                          width: 16,
                          borderRadius:
                              const BorderRadius.vertical(
                                  top: Radius.circular(6)),
                          gradient: LinearGradient(
                            colors: [
                              const Color(0xFFC26D81),
                              const Color(0xFFC26D81)
                                  .withValues(alpha: 0.55),
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                        BarChartRodData(
                          toY: cycles[i].bleedingDays.toDouble(),
                          width: 16,
                          borderRadius:
                              const BorderRadius.vertical(
                                  top: Radius.circular(6)),
                          gradient: LinearGradient(
                            colors: [
                              const Color(0xFF83C5BE),
                              const Color(0xFF83C5BE)
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

  /// Pie of logged days per cycle phase (from tracked cycle records).
  Widget _phasePieCard(ClinicalReport report) {
    final counts = <String, int>{};
    for (final c in report.cycles) {
      for (final l in c.days) {
        final d = DateTime.tryParse(l.date);
        if (d == null) continue;
        final phase = ClinicalReportEngine.phaseOf(
            c, DateTime(d.year, d.month, d.day));
        final label = switch (phase) {
          CyclePhase.menstrual => 'Menstrual',
          CyclePhase.follicular => 'Follicular',
          CyclePhase.ovulation => 'Ovulation',
          CyclePhase.luteal => 'Luteal',
          CyclePhase.unknown => 'Logged',
        };
        counts[label] = (counts[label] ?? 0) + 1;
      }
    }
    if (counts.isEmpty) {
      return SectionCard(
        icon: Icons.pie_chart_outline,
        title: 'Cycle Phase Distribution',
        child: Text('Not enough tracked days for a phase split yet.',
            style: TextStyle(color: context.her.muted, fontSize: 13)),
      );
    }
    final total = counts.values.fold(0, (a, b) => a + b);
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return SectionCard(
      icon: Icons.pie_chart_outline,
      title: 'Cycle Phase Distribution',
      child: Column(
        children: [
          SizedBox(
            height: 200,
            child: Stack(
              alignment: Alignment.center,
              children: [
                PieChart(
                  duration: const Duration(milliseconds: 800),
                  curve: Curves.easeOutCubic,
                  PieChartData(
                    centerSpaceRadius: 44,
                    sectionsSpace: 3,
                    startDegreeOffset: -90,
                    sections: [
                      for (final e in entries)
                        PieChartSectionData(
                          value: e.value.toDouble(),
                          color: _phaseColors[e.key] ?? Colors.grey,
                          radius: 54,
                          title:
                              '${(e.value * 100 / total).round()}%',
                          titleStyle: TextStyle(
                              color: (_phaseColors[e.key] ??
                                          Colors.grey)
                                      .computeLuminance() >
                                  0.55
                                  ? const Color(0xFF4A4A4A)
                                  : Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold),
                        ),
                    ],
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$total days',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: context.her.ink)),
                    Text('tracked',
                        style: TextStyle(
                            fontSize: 11,
                            color: context.her.muted)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 6,
            children: [
              for (final e in entries)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: _phaseColors[e.key] ?? Colors.grey,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text('${e.key} ${(e.value * 100 / total).toStringAsFixed(1)}%',
                        style: TextStyle(
                            fontSize: 12,
                            color: context.her.ink)),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Pie of symptom share by logged days (top 6). Screen-only.
  Widget _symptomPieCard(ClinicalReport report) {
    final top = report.symptoms.take(6).toList();
    if (top.isEmpty) {
      return SectionCard(
        icon: Icons.pie_chart_outline,
        title: 'Symptom Share',
        child: Text('No symptoms logged in this period.',
            style: TextStyle(color: context.her.muted, fontSize: 13)),
      );
    }
    final total = top.fold<int>(0, (a, s) => a + s.occurrences);
    return SectionCard(
      icon: Icons.pie_chart_outline,
      title: 'Symptom Share',
      child: StatefulBuilder(
        builder: (c, setTouch) {
          var touched = -1;
          return Column(
            children: [
              SizedBox(
                height: 200,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    PieChart(
                      duration: const Duration(milliseconds: 700),
                      curve: Curves.easeOutCubic,
                      PieChartData(
                        centerSpaceRadius: 44,
                        sectionsSpace: 3,
                        startDegreeOffset: -90,
                        pieTouchData: PieTouchData(
                          touchCallback: (event, response) =>
                              setTouch(() {
                            touched = response?.touchedSection
                                    ?.touchedSectionIndex ??
                                -1;
                          }),
                        ),
                        sections: [
                          for (var i = 0; i < top.length; i++)
                            PieChartSectionData(
                              value: top[i].occurrences.toDouble(),
                              color:
                                  _pieColors[i % _pieColors.length],
                              radius: touched == i ? 64 : 54,
                              title: total == 0
                                  ? ''
                                  : '${(top[i].occurrences * 100 / total).round()}%',
                              titleStyle: TextStyle(
                                  color: _pieColors[
                                                  i % _pieColors.length]
                                              .computeLuminance() >
                                          0.55
                                      ? const Color(0xFF4A4A4A)
                                      : Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold),
                            ),
                        ],
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          touched >= 0 && touched < top.length
                              ? top[touched].name
                              : '$total days',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: context.her.ink),
                        ),
                        Text(
                          touched >= 0 && touched < top.length
                              ? '${top[touched].occurrences} logged days'
                              : 'logged',
                          style: TextStyle(
                              fontSize: 11,
                              color: context.her.muted),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              for (var i = 0; i < top.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color:
                              _pieColors[i % _pieColors.length],
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(top[i].name,
                            style:
                                const TextStyle(fontSize: 12)),
                      ),
                      Text('${top[i].occurrences}d',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: context.her.muted)),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// Pie of mood split by logged days. Screen-only.
  Widget _moodPieCard(ClinicalReport report) {
    final entries = report.moods.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (entries.isEmpty) {
      return SectionCard(
        icon: Icons.mood_outlined,
        title: 'Mood Split',
        child: Text('No moods logged in this period.',
            style: TextStyle(color: context.her.muted, fontSize: 13)),
      );
    }
    final total = entries.fold<int>(0, (a, e) => a + e.value);
    return SectionCard(
      icon: Icons.mood_outlined,
      title: 'Mood Split',
      child: Column(
        children: [
          SizedBox(
            height: 200,
            child: Stack(
              alignment: Alignment.center,
              children: [
                PieChart(
                  duration: const Duration(milliseconds: 800),
                  curve: Curves.easeOutCubic,
                  PieChartData(
                    centerSpaceRadius: 44,
                    sectionsSpace: 3,
                    startDegreeOffset: -90,
                    sections: [
                      for (var i = 0; i < entries.length; i++)
                        PieChartSectionData(
                          value: entries[i].value.toDouble(),
                          color:
                              _moodColors[i % _moodColors.length],
                          radius: 54,
                          title:
                              '${(entries[i].value * 100 / total).round()}%',
                          titleStyle: TextStyle(
                              color: _moodColors[
                                              i % _moodColors.length]
                                          .computeLuminance() >
                                      0.55
                                  ? const Color(0xFF4A4A4A)
                                  : Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold),
                        ),
                    ],
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$total days',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: context.her.ink)),
                    Text('with mood',
                        style: TextStyle(
                            fontSize: 11,
                            color: context.her.muted)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 6,
            children: [
              for (var i = 0; i < entries.length; i++)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color:
                            _moodColors[i % _moodColors.length],
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                        '${entries[i].key} ${(entries[i].value * 100 / total).toStringAsFixed(1)}%',
                        style: TextStyle(
                            fontSize: 12,
                            color: context.her.ink)),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Bars of flow-intensity days. Screen-only.
  Widget _flowBarCard(ClinicalReport report) {
    final flows = <String, int>{};
    for (final log in report.allLogs) {
      if (log.flowIntensity != 'None') {
        flows[log.flowIntensity] =
            (flows[log.flowIntensity] ?? 0) + 1;
      }
    }
    const order = ['Spotting', 'Light', 'Medium', 'Heavy'];
    final items = order.where(flows.containsKey).toList();
    if (items.isEmpty) {
      return SectionCard(
        icon: Icons.water_drop_outlined,
        title: 'Flow Intensity',
        child: Text('No flow days logged in this period.',
            style: TextStyle(color: context.her.muted, fontSize: 13)),
      );
    }
    final maxCount =
        items.map((k) => flows[k]!).reduce((a, b) => a > b ? a : b);
    return SectionCard(
      icon: Icons.water_drop_outlined,
      title: 'Flow Intensity',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _chartLegendDot(const Color(0xFFC26D81), 'Flow days'),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 200,
            child: BarChart(
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              BarChartData(
                maxY: (maxCount + 1).toDouble(),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (value) => FlLine(
                    color:
                        context.her.muted.withValues(alpha: 0.25),
                    strokeWidth: 1,
                  ),
                ),
                borderData: FlBorderData(
                  show: true,
                  border: Border.all(
                      color: context.her.muted.withValues(alpha: 0.4)),
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
                        style: TextStyle(
                            fontSize: 10, color: context.her.muted),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: 1,
                      getTitlesWidget: (value, meta) {
                        final i = value.toInt();
                        if (i < 0 || i >= items.length) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            items[i],
                            style: TextStyle(
                                fontSize: 10,
                                color: context.her.muted),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                barTouchData: BarTouchData(
                  enabled: true,
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipColor: (_) => context.her.card,
                    getTooltipItem:
                        (group, groupIndex, rod, rodIndex) {
                      final name = items[group.x.toInt()];
                      return BarTooltipItem(
                        '$name\n',
                        TextStyle(
                            color: context.her.muted, fontSize: 11),
                        children: [
                          TextSpan(
                            text:
                                '${flows[name]} day${flows[name] == 1 ? '' : 's'}',
                            style: TextStyle(
                                color: context.her.ink,
                                fontWeight: FontWeight.bold,
                                fontSize: 13),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                barGroups: [
                  for (var i = 0; i < items.length; i++)
                    BarChartGroupData(
                      x: i,
                      barRods: [
                        BarChartRodData(
                          toY: flows[items[i]]!.toDouble(),
                          width: 30,
                          borderRadius:
                              const BorderRadius.vertical(
                                  top: Radius.circular(8)),
                          gradient: LinearGradient(
                            colors: [
                              const Color(0xFFC26D81),
                              const Color(0xFFC26D81)
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

  /// Multi-line mood presence over the window. Screen-only.
  Widget _moodTrendCard(ClinicalReport report) {
    final byDate = <String, Map<String, int>>{};
    for (final log in report.allLogs) {
      if (log.mood.isEmpty) continue;
      byDate
          .putIfAbsent(log.date, () => {})
          .update(log.mood, (v) => v + 1, ifAbsent: () => 1);
    }
    final dates = byDate.keys.toList()..sort();
    if (dates.isEmpty) {
      return SectionCard(
        icon: Icons.show_chart,
        title: 'Mood Trend',
        child: Text('No moods logged in this period.',
            style: TextStyle(color: context.her.muted, fontSize: 13)),
      );
    }
    final names =
        byDate.values.expand((m) => m.keys).toSet().toList()..sort();
    return SectionCard(
      icon: Icons.show_chart,
      title: 'Mood Trend',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              for (var i = 0; i < names.length; i++)
                _chartLegendDot(
                    _moodColors[i % _moodColors.length], names[i]),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 210,
            child: LineChart(
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              LineChartData(
                minX: 0,
                maxX: (dates.length - 1).toDouble(),
                minY: 0,
                maxY: 1.5,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (value) => FlLine(
                    color:
                        context.her.muted.withValues(alpha: 0.25),
                    strokeWidth: 1,
                  ),
                ),
                borderData: FlBorderData(
                  show: true,
                  border: Border.all(
                      color: context.her.muted.withValues(alpha: 0.4)),
                ),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  leftTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval:
                          (dates.length / 4).ceilToDouble().clamp(1, 30),
                      getTitlesWidget: (value, meta) {
                        final i = value.toInt();
                        if (i < 0 || i >= dates.length) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            dates[i].length >= 10
                                ? dates[i].substring(5)
                                : dates[i],
                            style: TextStyle(
                                fontSize: 10,
                                color: context.her.muted),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                lineTouchData: const LineTouchData(enabled: true),
                lineBarsData: [
                  for (var m = 0; m < names.length; m++)
                    LineChartBarData(
                      spots: [
                        for (var i = 0; i < dates.length; i++)
                          FlSpot(
                            i.toDouble(),
                            (byDate[dates[i]]?[names[m]] ?? 0)
                                .toDouble(),
                          ),
                      ],
                      isCurved: true,
                      color: _moodColors[m % _moodColors.length],
                      barWidth: 2.5,
                      dotData:
                          const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: _moodColors[m % _moodColors.length]
                            .withValues(alpha: 0.12),
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

  /// Pain score (0–10) over the window. Screen-only.
  Widget _painTrendCard(ClinicalReport report) {
    final points = <String, int>{};
    for (final log in report.allLogs) {
      if (log.painScore > 0) points[log.date] = log.painScore;
    }
    final dates = points.keys.toList()..sort();
    if (dates.isEmpty) {
      return SectionCard(
        icon: Icons.show_chart,
        title: 'Pain Trend',
        child: Text('No pain scores logged in this period.',
            style: TextStyle(color: context.her.muted, fontSize: 13)),
      );
    }
    return SectionCard(
      icon: Icons.show_chart,
      title: 'Pain Trend (0–10)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _chartLegendDot(
                  const Color(0xFFE53935), 'Pain score'),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 210,
            child: LineChart(
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              LineChartData(
                minX: 0,
                maxX: (dates.length - 1).toDouble(),
                minY: 0,
                maxY: 10,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (value) => FlLine(
                    color:
                        context.her.muted.withValues(alpha: 0.25),
                    strokeWidth: 1,
                  ),
                ),
                borderData: FlBorderData(
                  show: true,
                  border: Border.all(
                      color: context.her.muted.withValues(alpha: 0.4)),
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
                      interval: 2,
                      getTitlesWidget: (value, meta) => Text(
                        value.toInt().toString(),
                        style: TextStyle(
                            fontSize: 10, color: context.her.muted),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval:
                          (dates.length / 4).ceilToDouble().clamp(1, 30),
                      getTitlesWidget: (value, meta) {
                        final i = value.toInt();
                        if (i < 0 || i >= dates.length) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            dates[i].length >= 10
                                ? dates[i].substring(5)
                                : dates[i],
                            style: TextStyle(
                                fontSize: 10,
                                color: context.her.muted),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                lineTouchData: LineTouchData(
                  enabled: true,
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) => context.her.card,
                    getTooltipItems: (spots) => spots
                        .map((s) => LineTooltipItem(
                              '${dates[s.x.toInt()]}\n',
                              TextStyle(
                                  color: context.her.muted,
                                  fontSize: 11),
                              children: [
                                TextSpan(
                                  text:
                                      '${s.y.toStringAsFixed(0)}/10',
                                  style: TextStyle(
                                      color: context.her.ink,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13),
                                ),
                              ],
                            ))
                        .toList(),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: [
                      for (var i = 0; i < dates.length; i++)
                        FlSpot(
                            i.toDouble(), points[dates[i]]!.toDouble()),
                    ],
                    isCurved: true,
                    color: const Color(0xFFE53935),
                    barWidth: 3,
                    dotData: FlDotData(
                      show: true,
                      getDotPainter:
                          (spot, percent, bar, index) =>
                              FlDotCirclePainter(
                        radius: 4,
                        color: context.her.card,
                        strokeWidth: 2.5,
                        strokeColor: const Color(0xFFE53935),
                      ),
                    ),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFFE53935)
                              .withValues(alpha: 0.30),
                          const Color(0xFFE53935)
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
}

class SectionCard extends StatelessWidget {
  // (State class closes here; chart helpers above are State members.)

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
        color: context.her.card,
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
        color: context.her.card,
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
      ),
    );
  }
}

Widget _kv(HerCycleColors her, String label, String value) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: Text(label,
              style: TextStyle(fontSize: 12, color: her.muted)),
        ),
        Expanded(
          child: Text(value,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: her.ink)),
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

Widget _patternLine(HerCycleColors her, String label, String value) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: RichText(
      text: TextSpan(
        style: TextStyle(fontSize: 12, height: 1.4, color: her.ink),
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
