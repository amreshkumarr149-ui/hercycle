import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hercycle/core/clinical_report_engine.dart';
import 'package:hercycle/core/telemetry_service.dart';

/// First-report-free, pay-after entitlement for the Deep Insight premium
/// report. Client-side flag (demo-grade; phase 2 moves enforcement into the
/// x402-verified endpoint). Rules never punish a failed generation: the free
/// chance is consumed only after a premium report renders successfully.
/// Entitlement for the Deep Insight screen:
/// - free: first report unused, generate immediately
/// - paid: an unused paid receipt exists, open + export without re-prompting
/// - locked: paywall (pay externally, verify tx id, then open)
enum PremiumAccess { free, paid, locked }

/// One recorded x402 payment for the "My payments" UI.
class PremiumReceipt {
  final String txId;
  final bool used;
  final DateTime? createdAt;
  final int? usdcMicro;

  const PremiumReceipt({
    required this.txId,
    required this.used,
    this.createdAt,
    this.usdcMicro,
  });

  String get shortId =>
      txId.length <= 12 ? txId : '${txId.substring(0, 6)}…${txId.substring(txId.length - 4)}';
}

class PremiumService {
  PremiumService._();
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static const String priceInr = '₹1';
  static const String priceUsdc = '~\$0.01 USDC';
  static const int priceInrPaise = 100;

  /// True when this user still has their free Deep Insight available.
  static Future<bool> isFreeAvailable(String uid) async {
    try {
      final doc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      return doc.data()?['freeReportUsed'] != true;
    } catch (_) {
      // Unreadable flag: fail open to the free path rather than demanding
      // payment for a state we cannot verify. The paid path still requires
      // a live server + wallet when those exist.
      return true;
    }
  }

  /// 3-state entitlement: free first report, paid (an unused receipt),
  /// or locked (paywall). Paid receipts are consumed at PDF export, so a
  /// just-paid user is never re-prompted for the report they unlocked.
  static Future<PremiumAccess> getAccess(String uid) async {
    try {
      if (await isFreeAvailable(uid)) return PremiumAccess.free;
      final unused = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('premiumReports')
          .where('used', isEqualTo: false)
          .limit(1)
          .get();
      if (unused.docs.isNotEmpty) return PremiumAccess.paid;
      return PremiumAccess.locked;
    } catch (_) {
      // Fail open to free on read errors (same rationale as above).
      return PremiumAccess.free;
    }
  }

  /// True when this exact transaction id was already redeemed.
  static Future<bool> txAlreadyUsed(String uid, String txId) async {
    try {
      final hit = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('premiumReports')
          .where('txId', isEqualTo: txId.trim())
          .limit(1)
          .get();
      return hit.docs.isNotEmpty;
    } catch (_) {
      // Unverifiable: treat as unused here; the server re-validates the
      // transaction itself, and failures surface at export time.
      return false;
    }
  }

  /// Consumes one unused paid receipt (marks used:true) for an export.
  /// Returns false when no unused receipt exists — caller must re-prompt
  /// for payment instead of generating the PDF.
  static Future<bool> consumePaidReceipt(String uid) async {
    try {
      final unused = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('premiumReports')
          .where('used', isEqualTo: false)
          .limit(1)
          .get();
      if (unused.docs.isEmpty) return false;
      await unused.docs.first.reference.update({'used': true});
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Marks the free report as consumed. Returns false when the write could
  /// not be confirmed (caller must NOT treat the freebie as spent).
  static Future<bool> consumeFreeReport(String uid) async {
    try {
      await _db
          .collection('users')
          .doc(uid)
          .set({'freeReportUsed': true}, SetOptions(merge: true));
      final check =
          await _db.collection('users').doc(uid).get().timeout(
                const Duration(seconds: 10),
              );
      return check.data()?['freeReportUsed'] == true;
    } catch (_) {
      return false;
    }
  }

  /// One recorded payment. Thin read model for the "My payments" UI.
  /// Never throws (callers get [] on failure, never a crash).
  ///
  /// Deliberately orderBy-only (no where clause): single-field ordering
  /// uses Firestore's automatic indexes, so this query can never fail
  /// with a missing-composite-index error. Failures are still recorded
  /// for Crashlytics visibility.
  static Future<List<PremiumReceipt>> listReceipts(String uid) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('premiumReports')
          .orderBy('createdAt', descending: true)
          .limit(20)
          .get();
      return receiptsFromMaps(snap.docs.map((d) => d.data()).toList());
    } catch (e) {
      await TelemetryService.recordError(e, StackTrace.current,
          reason: 'receipts-list');
      return [];
    }
  }

  /// Pure mapper: Firestore maps -> newest-first receipts. Corrupt dates
  /// sort last, corrupt amounts become null. Unit-tested.
  static List<PremiumReceipt> receiptsFromMaps(
      List<Map<String, dynamic>> maps) {
    final out = maps.map((m) {
      DateTime? at;
      final raw = m['createdAt'];
      if (raw is Timestamp) {
        at = raw.toDate();
      } else if (raw is String) {
        at = DateTime.tryParse(raw);
      }
      return PremiumReceipt(
        txId: (m['txId'] ?? '').toString(),
        used: m['used'] == true,
        createdAt: at,
        usdcMicro: (m['usdcMicro'] is num)
            ? (m['usdcMicro'] as num).toInt()
            : int.tryParse('${m['usdcMicro'] ?? ''}'),
      );
    }).toList();
    out.sort((a, b) {
      final at = a.createdAt;
      final bt = b.createdAt;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return out;
  }

  /// Records a paid-report receipt (called after a verified x402 payment).
  /// Receipts start unused; one is consumed per PDF export.
  static Future<void> addReceipt(
    String uid, {
    required String txId,
    required int inrPaise,
    required String usdcMicro,
    required String fxRate,
  }) async {
    await _db.collection('users').doc(uid).collection('premiumReports').add({
      'txId': txId.trim(),
      'inrPaise': inrPaise,
      'usdcMicro': usdcMicro,
      'fxRate': fxRate,
      'used': false,
      'createdAt': Timestamp.fromDate(DateTime.now()),
    });
  }

  /// Deterministic wellness recommendations derived ONLY from the computed
  /// report model. Educational suggestions, never diagnoses.
  static List<String> buildRecommendations(ClinicalReport report) {
    final out = <String>[];
    double? cycleVariation;
    double? avgBleed;
    double? avgPain;
    for (final b in report.baselines) {
      final num = RegExp(r'([\d.]+)').firstMatch(b.value)?.group(1);
      final v = num == null ? null : double.tryParse(num);
      if (v == null) continue;
      if (b.name == 'Average Cycle Length') {
        // variation row carries the spread; handled below via tag instead.
      } else if (b.name == 'Cycle-to-cycle variation') {
        cycleVariation = v;
      } else if (b.name == 'Average Bleeding Duration') {
        avgBleed = v;
      } else if (b.name == 'Average Pain Score') {
        avgPain = v;
      }
    }
    if (cycleVariation != null && cycleVariation > 10) {
      out.add(
          'Wellness suggestion (educational): your cycle timing varies by ${cycleVariation.toStringAsFixed(0)} days — tracking sleep and stress alongside your cycle can reveal personal rhythms worth discussing with a professional.');
    } else if (report.cyclesAnalyzed >= 2) {
      out.add(
          'Wellness suggestion (educational): your cycle timing looks steady — keeping your current logging routine preserves this clarity.');
    }
    if (avgBleed != null && avgBleed > 7) {
      out.add(
          'Wellness suggestion (educational): your bleeding averages ${avgBleed.toStringAsFixed(1)} days — iron-rich foods and rest during bleeding days are commonly recommended topics to raise with your doctor.');
    }
    if (avgPain != null && avgPain >= 4) {
      out.add(
          'Wellness suggestion (educational): your average pain is ${avgPain.toStringAsFixed(1)}/10 — heat therapy, gentle movement and a pain diary are worth discussing with a healthcare professional.');
    }
    final hasConfirmed = report.cycles.any((c) => c.ovulationConfirmed);
    if (!hasConfirmed && report.cyclesAnalyzed >= 1) {
      out.add(
          'Wellness suggestion (educational): log LH tests through your fertile window to turn estimated ovulation into confirmed ovulation.');
    }
    if (report.symptoms.isNotEmpty) {
      out.add(
          'Wellness suggestion (educational): ${report.symptoms.first.name} appears most often — noting what helps on those days builds your personal care playbook.');
    }
    if (out.isEmpty) {
      out.add(
          'Wellness suggestion (educational): keep logging daily — consistent data is the foundation of every insight on this page.');
    }
    return out.take(6).toList();
  }
}
