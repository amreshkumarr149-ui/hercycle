import 'dart:typed_data';

import 'package:hercycle/core/clinical_report_engine.dart';
import 'package:hercycle/core/disease_risk_screener.dart';
import 'package:hercycle/models/daily_log.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

final _rose = PdfColor.fromHex('#C26D81');
final _ink = PdfColor.fromHex('#4A4A4A');
final _muted = PdfColor.fromHex('#8A8A8A');

/// The PDF uses standard Helvetica (WinAnsi). Emoji, arrows and dingbats
/// outside that encoding would render blank or throw during layout, so every
/// dynamic string passes through here. Accented Latin text is preserved.
String _pdf(String s) {
  var out = s
      .replaceAll('↑', 'up ')
      .replaceAll('↓', 'down ')
      .replaceAll('→', '-')
      .replaceAll('•', '-')
      .replaceAll('—', '-')
      .replaceAll('–', '-')
      .replaceAll('“', '"')
      .replaceAll('”', '"')
      .replaceAll('‘', "'")
      .replaceAll('’', "'")
      .replaceAll('⚠', '!')
      .replaceAll('✓', 'OK ')
      .replaceAll('◉', '-')
      .replaceAll('⚲', '-')
      .replaceAll('★', '*')
      .replaceAll('♡', '<3')
      .replaceAll('✨', '')
      .replaceAll('⭐', '*');
  // Strip remaining astral-plane characters (emoji live here).
  out = out.replaceAll(RegExp(r'[\u{10000}-\u{10FFFF}]', unicode: true), '');
  return out;
}

pw.Widget _sectionTitle(int number, String title) {
  return pw.Padding(
    padding: const pw.EdgeInsets.only(top: 14, bottom: 6),
    child: pw.Row(
      children: [
        pw.Container(
          width: 26,
          height: 26,
          alignment: pw.Alignment.center,
          decoration: pw.BoxDecoration(
            color: _rose,
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(13)),
          ),
          child: pw.Text('$number',
              style: pw.TextStyle(
                  color: PdfColors.white,
                  fontWeight: pw.FontWeight.bold,
                  fontSize: 13)),
        ),
        pw.SizedBox(width: 8),
        pw.Text(title,
            style: pw.TextStyle(
                fontSize: 15,
                fontWeight: pw.FontWeight.bold,
                color: _ink)),
      ],
    ),
  );
}

pw.Widget _bullet(String text, {bool bold = false}) {
  return pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 4),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('•  ',
            style: pw.TextStyle(color: _rose, fontSize: 11)),
        pw.Expanded(
            child: pw.Text(_pdf(text),
                style: pw.TextStyle(
                    fontSize: 11,
                    height: 1.4,
                    color: _ink,
                    fontWeight: bold
                        ? pw.FontWeight.bold
                        : pw.FontWeight.normal))),
      ],
    ),
  );
}

pw.Widget _kv(String label, String value) {
  return pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 3),
    child: pw.Row(
      children: [
        pw.SizedBox(
            width: 170,
            child: pw.Text(_pdf(label),
                style: pw.TextStyle(
                    fontSize: 11,
                    color: _muted,
                    fontWeight: pw.FontWeight.bold))),
        pw.Expanded(
            child: pw.Text(_pdf(value),
                style: const pw.TextStyle(fontSize: 11))),
      ],
    ),
  );
}

/// Builds the premium HerCycle clinical report PDF. Everything rendered
/// comes from [report] (tracked data only) — nothing is invented here.
Future<Uint8List> buildClinicalPdf({
  required ClinicalReport report,
  required List<RiskAssessmentResult> screener,
  required List<DailyLog> history,
}) async {
  final pdf = pw.Document();

  pw.Widget headerBlock() {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('HerCycle',
                style: pw.TextStyle(
                    fontSize: 22,
                    fontWeight: pw.FontWeight.bold,
                    color: _rose)),
            pw.Text('CONFIDENTIAL',
                style: pw.TextStyle(
                    fontSize: 10,
                    fontWeight: pw.FontWeight.bold,
                    color: _muted)),
          ],
        ),
        pw.Text('Clinical Health Report',
            style: pw.TextStyle(
                fontSize: 16,
                fontWeight: pw.FontWeight.bold,
                color: _ink)),
        pw.SizedBox(height: 8),
        _kv('Report date', report.generatedDate),
        _kv('Reporting period', report.windowLabel),
        _kv('Name', _pdf(report.userName)),
        _kv('Age', _pdf(report.age)),
        _kv('Tracking history', _pdf(report.trackingDuration)),
        _kv('Tracking mode', _pdf(report.trackingMode)),
        _kv('Confidential Medical Record Summary', 'Private to the user'),
      ],
    );
  }

  pw.Widget disclaimerBlock() {
    return pw.Container(
      margin: const pw.EdgeInsets.only(top: 10),
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: _rose, width: 1),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
      ),
      child: pw.Text(
        'MEDICAL DISCLAIMER — This report is generated automatically from user-entered symptoms, cycle history, and physiological tracking data. HerCycle is an educational and health-tracking tool and is not a substitute for professional medical diagnosis, treatment, or medical advice.',
        style: const pw.TextStyle(fontSize: 10, height: 1.4),
      ),
    );
  }

  final flaggedScreener = screener.where((r) => r.isFlagged).toList();

  // Full-Unicode embedding so non-Latin names/notes render. Falls back to
  // Helvetica (plus the _pdf() sanitizer above) when offline.
  pw.ThemeData theme;
  try {
    theme = pw.ThemeData.withFont(
      base: await PdfGoogleFonts.nunitoRegular(),
      bold: await PdfGoogleFonts.nunitoBold(),
      italic: await PdfGoogleFonts.nunitoItalic(),
    );
  } catch (_) {
    theme = pw.ThemeData.withFont(
      base: pw.Font.helvetica(),
      bold: pw.Font.helveticaBold(),
      italic: pw.Font.helveticaOblique(),
    );
  }

  pdf.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      theme: theme,
      footer: (ctx) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('Confidential Medical Record Summary • HerCycle',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey)),
          pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey)),
        ],
      ),
      build: (ctx) => [
        headerBlock(),
        disclaimerBlock(),
        _sectionTitle(1, 'Baseline Cycle Averages'),
        pw.TableHelper.fromTextArray(
          headers: const ['Metric', 'Your value', 'Reference', 'Reading'],
          headerStyle: pw.TextStyle(
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
              fontSize: 10),
          headerDecoration: pw.BoxDecoration(color: _rose),
          cellStyle: const pw.TextStyle(fontSize: 10),
          data: report.baselines
              .map((b) =>
                  [_pdf(b.name), _pdf(b.value), _pdf(b.reference), _pdf(b.tag)])
              .toList(),
        ),
        _sectionTitle(2, 'Automated Pattern Screening'),
        if (report.patterns.isEmpty && flaggedScreener.isEmpty)
          pw.Text('No tracked patterns crossed screening thresholds in this period.',
              style: const pw.TextStyle(fontSize: 11)),
        ...report.patterns.map((p) => pw.Container(
              margin: const pw.EdgeInsets.only(bottom: 8),
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey300),
                borderRadius:
                    const pw.BorderRadius.all(pw.Radius.circular(8)),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(_pdf('PATTERN IDENTIFIED: ${p.name}'),
                      style: pw.TextStyle(
                          fontWeight: pw.FontWeight.bold,
                          color: _rose,
                          fontSize: 11)),
                  pw.SizedBox(height: 4),
                  pw.Text(_pdf('Algorithm trigger: ${p.trigger}'),
                      style: const pw.TextStyle(fontSize: 10)),
                  pw.Text(_pdf('Supporting observations: ${p.observations}'),
                      style: const pw.TextStyle(fontSize: 10)),
                  pw.Text(
                      _pdf('Cycles showing the pattern: ${p.cycleCount} - Dates: ${p.dates.take(6).join(', ')}'),
                      style: const pw.TextStyle(fontSize: 10)),
                  pw.Text(_pdf('Clinical context: ${p.context}'),
                      style: const pw.TextStyle(fontSize: 10)),
                  pw.Text(_pdf('Recommended next step: ${p.nextStep}'),
                      style: const pw.TextStyle(fontSize: 10)),
                ],
              ),
            )),
        ...flaggedScreener.map((r) => pw.Container(
              margin: const pw.EdgeInsets.only(bottom: 8),
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.red200),
                borderRadius:
                    const pw.BorderRadius.all(pw.Radius.circular(8)),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(_pdf('PATTERN IDENTIFIED: ${r.title}'),
                      style: pw.TextStyle(
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.red800,
                          fontSize: 11)),
                  pw.Text(_pdf(r.description),
                      style: const pw.TextStyle(fontSize: 10)),
                ],
              ),
            )),
        _sectionTitle(3, 'Detailed Cycle Phase Logs'),
        if (report.cycles.isEmpty)
          pw.Text('No tracked cycles in this period.',
              style: const pw.TextStyle(fontSize: 11)),
        if (report.cycles.length > 12)
          pw.Text(
              'Showing the 12 most recent of ${report.cycles.length} cycles in this window.',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey)),
        ...report.cycles
            .skip(report.cycles.length > 12 ? report.cycles.length - 12 : 0)
            .map((c) {
          final ovuLabel = c.ovulationConfirmed
              ? 'confirmed ${_d(c.confirmedOvulation!)}'
              : (c.estimatedOvulation != null
                  ? 'estimated ${_d(c.estimatedOvulation!)}'
                  : 'not enough data');
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 8, bottom: 4),
                child: pw.Text(
                  _pdf('Cycle #${c.number} - ${_d(c.start)} to ${c.end != null ? _d(c.end!) : 'ongoing'}'
                  ' - ${c.length != null ? '${c.length} days' : 'length TBD'}'
                  ' - bleeding ${c.bleedingDays}d - ovulation $ovuLabel'),
                  style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold, fontSize: 11),
                ),
              ),
              if (c.days.isEmpty)
                pw.Text('No day-level logs in this cycle.',
                    style: const pw.TextStyle(fontSize: 10)),
              if (c.days.isNotEmpty)
                pw.TableHelper.fromTextArray(
                  headers: const [
                    'Date', 'Phase', 'Mucus', 'LH', 'Flow', 'Pain', 'Symptoms', 'Notes'
                  ],
                  headerStyle: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.white,
                      fontSize: 8),
                  headerDecoration: pw.BoxDecoration(color: _rose),
                  cellStyle: const pw.TextStyle(fontSize: 8),
                  data: c.days.map((l) {
                    final d = DateTime.tryParse(l.date);
                    final ph = d == null
                        ? '—'
                        : ClinicalReportEngine.phaseLabel(
                            ClinicalReportEngine.phaseOf(c, d));
                    final syms = l.symptoms.map((s) {
                      final sc = l.symptomIntensity[s];
                      return sc != null ? '$s $sc/10' : s;
                    }).join(', ');
                    final notes = l.notes.trim();
                    return [
                      _pdf(l.date),
                      _pdf(ph),
                      _pdf(l.mucus.replaceAll('\n', ' ')),
                      _pdf(l.lhTest),
                      _pdf(l.flowIntensity),
                      _pdf('${l.painScore}'),
                      _pdf(syms),
                      _pdf(notes.length > 40
                          ? '${notes.substring(0, 40)}...'
                          : notes),
                    ];
                  }).toList(),
                ),
            ],
          );
        }),
        _sectionTitle(4, 'Trend Analysis'),
        if (report.trends.isEmpty)
          pw.Text('Not enough complete cycles to compare trends.',
              style: const pw.TextStyle(fontSize: 11)),
        if (report.trends.isNotEmpty)
          pw.TableHelper.fromTextArray(
            headers: const ['Area', 'Trend', 'Detail'],
            headerStyle: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
                fontSize: 10),
            headerDecoration: pw.BoxDecoration(color: _rose),
            cellStyle: const pw.TextStyle(fontSize: 10),
            data: report.trends
                .map((t) =>
                    [_pdf(t.name), _pdf(t.indicator), _pdf(t.detail)])
                .toList(),
          ),
        _sectionTitle(5, 'Symptom Summary'),
        if (report.symptoms.isEmpty)
          pw.Text('No symptoms logged in this period.',
              style: const pw.TextStyle(fontSize: 11)),
        if (report.symptoms.isNotEmpty)
          pw.TableHelper.fromTextArray(
            headers: const [
              'Symptom', 'Frequency', 'Avg severity', 'Cycles', 'Typical phase', 'Recent'
            ],
            headerStyle: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
                fontSize: 10),
            headerDecoration: pw.BoxDecoration(color: _rose),
            cellStyle: const pw.TextStyle(fontSize: 10),
            data: report.symptoms
                .map((s) => [
                      _pdf(s.name),
                      _pdf('${s.occurrences}'),
                      _pdf(s.avgSeverity),
                      _pdf('${s.cyclesAffected}'),
                      _pdf(s.typicalPhase),
                      _pdf(s.recent)
                    ])
                .toList(),
          ),
        _sectionTitle(6, 'Personalized Insights'),
        if (report.insights.isEmpty)
          pw.Text(
              'Not enough tracked data for personalized insights yet — keep logging daily.',
              style: const pw.TextStyle(fontSize: 11)),
        ...report.insights.map(_bullet),
        _sectionTitle(7, 'Health Attention Flags'),
        if (report.urgentMessage != null)
          pw.Container(
            margin: const pw.EdgeInsets.only(bottom: 8),
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              color: PdfColors.red50,
              border: pw.Border.all(color: PdfColors.red, width: 1.5),
              borderRadius:
                  const pw.BorderRadius.all(pw.Radius.circular(8)),
            ),
            child: pw.Text(_pdf(report.urgentMessage!),
                style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.red900,
                    fontSize: 11,
                    height: 1.4)),
          ),
        if (report.attentionFlags.isEmpty && report.urgentMessage == null)
          pw.Text('No attention flags in this period.',
              style: const pw.TextStyle(fontSize: 11)),
        ...report.attentionFlags.map(_bullet),
        _sectionTitle(8, 'Data Quality'),
        _kv('Cycles analysed', '${report.cyclesAnalyzed}'),
        _kv('Days logged', '${report.daysLogged} of ~${report.spanDays} days'),
        _kv('Reliability', report.reliability),
        pw.Text(_pdf(report.dataQualityNote),
            style: const pw.TextStyle(fontSize: 11, height: 1.4)),
        _sectionTitle(9, 'Report Summary'),
        ...report.summaryBullets.map(_bullet),
        _sectionTitle(10, 'Log History (date-wise)'),
        if (history.isEmpty)
          pw.Text('No logs in the selected view.',
              style: const pw.TextStyle(fontSize: 11)),
        if (history.isNotEmpty) ...[
          if (history.length > 500)
            pw.Text(
                'Showing the 500 most recent of ${history.length} entries.',
                style:
                    const pw.TextStyle(fontSize: 10, color: PdfColors.grey)),
          pw.TableHelper.fromTextArray(
            headers: const [
              'Date', 'Period', 'Mood', 'Symptoms', 'Pain', 'Mucus / LH'
            ],
            headerStyle: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
                fontSize: 9),
            headerDecoration: pw.BoxDecoration(color: _rose),
            cellStyle: const pw.TextStyle(fontSize: 9),
            data: history.take(500).map((log) {
              final syms = log.symptoms.map((s) {
                final sc = log.symptomIntensity[s];
                return sc != null ? '$s $sc/10' : s;
              }).join(', ');
              final ml = [
                if (log.mucus.isNotEmpty)
                  log.mucus.replaceAll('\n', ' '),
                if (log.lhTest.isNotEmpty) 'LH:${log.lhTest}',
              ].join(' ');
              return [
                _pdf(log.date),
                _pdf(log.period ? 'Yes (${log.flowIntensity})' : 'No'),
                _pdf(log.mood),
                _pdf(syms),
                _pdf('${log.painScore}'),
                _pdf(ml),
              ];
            }).toList(),
          ),
        ],
        pw.SizedBox(height: 16),
        pw.Text('Confidential Medical Record Summary — generated by HerCycle from user-tracked data. Not a medical diagnosis.',
            style: const pw.TextStyle(
                fontSize: 9,
                color: PdfColors.grey,
                fontStyle: pw.FontStyle.italic)),
      ],
    ),
  );

  return pdf.save();
}

String _d(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
