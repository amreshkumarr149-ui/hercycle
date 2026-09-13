import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:hercycle/core/app_theme.dart';
import 'package:hercycle/models/lh_test_entry.dart';

/// PRD §33 — LH test detail view (AI vs manual layouts).
class LhTestDetailScreen extends StatelessWidget {
  final LhTestEntry entry;

  const LhTestDetailScreen({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final isAi = entry.entryType == LhEntryType.aiScan;
    return Scaffold(
      appBar: AppBar(
        title: const Text('LH Test',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            DateFormat('MMMM d, yyyy').format(entry.timestamp),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          Text(
            DateFormat('h:mm a').format(entry.timestamp),
            style: TextStyle(color: context.her.muted),
          ),
          const SizedBox(height: 12),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: isAi
                  ? Colors.blue.withValues(alpha: 0.1)
                  : Colors.purple.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              isAi ? 'AI SCAN' : 'MANUAL ENTRY',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: isAi ? Colors.blue.shade700 : Colors.purple.shade700,
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (isAi) ...[
            _row(context, 'T/C Ratio',
                entry.tcRatio?.toStringAsFixed(2) ?? '--'),
            if (entry.rawRatio != null)
              _row(context, 'Raw ratio', entry.rawRatio!.toStringAsFixed(2)),
            _row(context, 'Status', entry.surgeStatus.name.toUpperCase()),
            if (entry.surgeVelocity != null)
              _row(context, 'LH speed',
                  '${entry.surgeVelocity! >= 0 ? '+' : ''}${entry.surgeVelocity!.toStringAsFixed(2)}/day'),
            if (entry.expectedVelocity != null)
              _row(context, 'Expected speed',
                  '${entry.expectedVelocity!.toStringAsFixed(2)}/day'),
            if (entry.reliability != null)
              _row(context, 'Reliability',
                  '${(entry.reliability! * 100).round()}%'),
            if (entry.imageUrl != null && entry.imageUrl!.isNotEmpty)
              _row(context, 'Image', entry.imageUrl!),
          ] else ...[
            _row(
                context,
                'Result',
                entry.manualResult == LhManualResult.positive
                    ? 'POSITIVE'
                    : 'NEGATIVE'),
          ],
          if (entry.predictedOvulationDate != null)
            _row(
                context,
                'Predicted ovulation',
                DateFormat('MMM d, yyyy')
                    .format(entry.predictedOvulationDate!)),
          if (entry.predictionConfidence != null)
            _row(context, 'Confidence',
                '${(entry.predictionConfidence! * 100).round()}%'),
          if (entry.notes != null && entry.notes!.isNotEmpty)
            _row(context, 'Notes', entry.notes!),
          const SizedBox(height: 12),
          Text(
            'LH tracking is a prediction aid, not a medical diagnosis.',
            style: TextStyle(
                fontSize: 12, fontStyle: FontStyle.italic, color: context.her.muted),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String k, String v) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.her.card,
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: context.her.muted.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(k,
                style: TextStyle(fontSize: 12, color: context.her.muted)),
          ),
          Expanded(
            child: Text(v,
                style:
                    const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          ),
        ],
      ),
    );
  }
}
