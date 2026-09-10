import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:hercycle/core/database_repository.dart';
import 'package:hercycle/features/logging/daily_logging_screen.dart';
import 'package:intl/intl.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  DateTime _focusedDay = DateTime.now();
  DateTime _selectedDay = DateTime.now();
  Set<DateTime> _periodDays = {};
  Set<DateTime> _loggedDays = {};

  @override
  void initState() {
    super.initState();
    _loadMarkers();
  }

  DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  Future<void> _loadMarkers() async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return;
    try {
      final logs = await DatabaseRepository().getAllLogs(userId);
      if (!mounted) return;
      final periods = <DateTime>{};
      final logged = <DateTime>{};
      for (final log in logs) {
        final d = DateTime.tryParse(log.date);
        if (d == null) continue;
        final day = _dayOnly(d);
        logged.add(day);
        if (log.period) periods.add(day);
      }
      setState(() {
        _periodDays = periods;
        _loggedDays = logged;
      });
    } catch (_) {
      // Offline: calendar still works, just without markers.
    }
  }

  List<String> _eventsForDay(DateTime day) {
    final d = _dayOnly(day);
    if (_periodDays.contains(d)) return const ['period'];
    if (_loggedDays.contains(d)) return const ['log'];
    return const [];
  }

  Future<void> _openLog(String dateStr, [LogSection section = LogSection.all]) async {
    final saved = await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) =>
              DailyLoggingScreen(date: dateStr, initialSection: section)),
    );
    await _loadMarkers();
    if (!mounted) return;
    if (saved == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Log saved for $dateStr ✓')),
      );
    }
    // Refresh the details card below.
    setState(() {});
  }

  Future<String> _detailsFor(String dateStr) async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return 'Not logged in.';
    try {
      final log = await DatabaseRepository().getLog(userId, dateStr);
      if (log == null) return '';
      final parts = <String>[];
      parts.add(log.period ? '🩸 Period: yes (flow: ${log.flowIntensity})' : '🩸 Period: no');
      if (log.mood.isNotEmpty) parts.add('😊 Mood: ${log.mood}');
      if (log.symptoms.isNotEmpty) {
        final syms = log.symptoms.map((s) {
          final score = log.symptomIntensity[s];
          return score != null ? '$s $score/10' : s;
        }).join(', ');
        parts.add('💧 Symptoms: $syms');
      }
      if (log.mucus.isNotEmpty) parts.add('💧 Mucus: ${log.mucus}');
      if (log.lhTest.isNotEmpty) parts.add('⚲ LH: ${log.lhTest}');
      if (log.painScore > 0) parts.add('🤕 Pain: ${log.painScore}/10');
      if (log.pelvicPressure) parts.add('◉ Pelvic pressure: yes');
      if (log.backBowelPain) parts.add('◉ Back/bowel pain: yes');
      if (log.notes.trim().isNotEmpty) parts.add('📝 ${log.notes.trim()}');
      return parts.join('\n');
    } catch (_) {
      return 'Could not load (offline?).';
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedDateStr = DateFormat('yyyy-MM-dd').format(_selectedDay);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cycle Calendar', style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          TextButton.icon(
            onPressed: () {
              setState(() {
                _focusedDay = DateTime.now();
                _selectedDay = DateTime.now();
              });
            },
            icon: const Icon(Icons.today, size: 16, color: Color(0xFFC26D81)),
            label: const Text('Today', style: TextStyle(color: Color(0xFFC26D81), fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Calendar Container
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(color: Colors.pink.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4)),
                ],
              ),
              child: TableCalendar(
                firstDay: DateTime.utc(2020, 1, 1),
                lastDay: DateTime.utc(2030, 12, 31),
                focusedDay: _focusedDay,
                selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
                onDaySelected: (selectedDay, focusedDay) {
                  setState(() {
                    _selectedDay = selectedDay;
                    _focusedDay = focusedDay;
                  });
                },
                // Without this, swiping to another month snaps back to the
                // stale focusedDay on the next rebuild (e.g. markers load).
                onPageChanged: (focusedDay) {
                  _focusedDay = focusedDay;
                },
                eventLoader: _eventsForDay,
                calendarBuilders: CalendarBuilders(
                  markerBuilder: (context, date, events) {
                    if (events.isEmpty) return null;
                    final isPeriod = events.contains('period');
                    return Positioned(
                      bottom: 1,
                      child: Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isPeriod
                              ? const Color(0xFFE53935)
                              : Colors.grey.shade500,
                        ),
                      ),
                    );
                  },
                ),
                calendarStyle: CalendarStyle(
                  todayDecoration: BoxDecoration(
                    color: const Color(0xFFF9C8D2),
                    shape: BoxShape.circle,
                  ),
                  selectedDecoration: BoxDecoration(
                    color: const Color(0xFFC26D81),
                    shape: BoxShape.circle,
                  ),
                  markerDecoration: const BoxDecoration(
                    color: Colors.pinkAccent,
                    shape: BoxShape.circle,
                  ),
                ),
                headerStyle: const HeaderStyle(
                  formatButtonVisible: false,
                  titleCentered: true,
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Selected Date Section
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Container(
              key: ValueKey(selectedDateStr),
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(color: Colors.pink.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 3)),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Selected Date', style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w500)),
                          const SizedBox(height: 4),
                          Text(
                            DateFormat('MMMM dd, yyyy').format(_selectedDay),
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A)),
                          ),
                        ],
                      ),
                      ElevatedButton(
                        onPressed: () => _openLog(selectedDateStr),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFC26D81),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('Open Daily Log'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FutureBuilder<String>(
                    key: ValueKey('details-$selectedDateStr'),
                    future: _detailsFor(selectedDateStr),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Text('Loading saved log…', style: TextStyle(color: Colors.grey, fontSize: 13));
                      }
                      final text = snapshot.data ?? '';
                      if (text.isEmpty) {
                        return const Text(
                          'Nothing logged yet for this date.',
                          style: TextStyle(color: Colors.grey, fontSize: 13),
                        );
                      }
                      return Text(text, style: const TextStyle(fontSize: 13, height: 1.6, color: Color(0xFF4A4A4A)));
                    },
                  ),
                ],
              ),
              ),
            ),
            const SizedBox(height: 24),

            // Daily Log Section
            const Text('Daily Log', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A))),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 2.5,
              children: [
                _buildCategoryButton(Icons.water_drop, 'Period', selectedDateStr, LogSection.period),
                _buildCategoryButton(Icons.mood, 'Mood', selectedDateStr, LogSection.mood),
                _buildCategoryButton(Icons.medical_services_outlined, 'Physical Health', selectedDateStr, LogSection.symptoms),
                _buildCategoryButton(Icons.opacity, 'Mucus', selectedDateStr, LogSection.mucus),
              ],
            ),
            const SizedBox(height: 12),
            _buildFullWidthCategoryButton(Icons.science_outlined, 'LH Test', selectedDateStr, LogSection.lh),
            const SizedBox(height: 28),

            // Cycle Information Section
            const Text('Cycle Information', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A))),
            const SizedBox(height: 12),
            _buildInfoCard(
              icon: Icons.water_drop,
              title: 'Period',
              description: 'Your logged and predicted period days for this cycle.',
            ),
            const SizedBox(height: 12),
            _buildInfoCard(
              icon: Icons.auto_awesome,
              title: 'Fertile Window',
              description: 'Estimated fertile days based on your historical cycle data.',
            ),
            const SizedBox(height: 12),
            _buildInfoCard(
              icon: Icons.circle_outlined,
              title: 'Ovulation',
              description: 'Estimated ovulation day. Estimates may vary from cycle to cycle.',
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryButton(IconData icon, String title, String dateStr, [LogSection section = LogSection.all]) {
    return InkWell(
      onTap: () => _openLog(dateStr, section),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.pink.withValues(alpha: 0.04), blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFFC26D81), size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Color(0xFF4A4A4A)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFullWidthCategoryButton(IconData icon, String title, String dateStr, [LogSection section = LogSection.all]) {
    return InkWell(
      onTap: () => _openLog(dateStr, section),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.pink.withValues(alpha: 0.04), blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFFC26D81), size: 20),
            const SizedBox(width: 12),
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Color(0xFF4A4A4A)),
            ),
            const Spacer(),
            const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard({required IconData icon, required String title, required String description}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(color: Colors.pink.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 3))],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFF9C8D2).withValues(alpha: 0.3),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: const Color(0xFFC26D81), size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A))),
                const SizedBox(height: 4),
                Text(description, style: TextStyle(fontSize: 13, height: 1.4, color: Colors.grey[600])),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
