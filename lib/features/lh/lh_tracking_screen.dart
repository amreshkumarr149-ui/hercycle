import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:hercycle/core/app_theme.dart';
import 'package:hercycle/core/database_repository.dart';
import 'package:hercycle/models/lh_test_entry.dart';
import 'package:hercycle/providers/auth_user_provider.dart';
import 'lh_entry_bottom_sheet.dart';

class LhTrackingScreen extends StatefulWidget {
  final String initialDateStr;

  const LhTrackingScreen({
    super.key,
    required this.initialDateStr,
  });

  @override
  State<LhTrackingScreen> createState() => _LhTrackingScreenState();
}

class _LhTrackingScreenState extends State<LhTrackingScreen> {
  bool _loading = true;
  List<LhTestEntry> _tests = [];

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
      setState(() {
        _tests = list;
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
            const SnackBar(content: Text('LH test record saved & ovulation prediction updated ✓')),
          );
        },
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
              ? Center(
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
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _tests.length,
                  itemBuilder: (context, index) {
                    final test = _tests[index];
                    final isAi = test.entryType == LhEntryType.aiScan;
                    final isHigh = test.surgeStatus == LhSurgeStatus.high || test.surgeStatus == LhSurgeStatus.peak;

                    return Container(
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
                                      DateFormat('MMM d, yyyy • h:mm a').format(test.timestamp),
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
                                        isAi ? '🤖 AI Scan' : '✍️ Manual',
                                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isAi ? Colors.blue.shade700 : Colors.purple.shade700),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Text(
                                      isAi
                                          ? 'T/C Ratio: ${test.tcRatio?.toStringAsFixed(2) ?? "—"}'
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
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openAddModal,
        backgroundColor: const Color(0xFFC26D81),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Log LH Test'),
      ),
    );
  }
}
