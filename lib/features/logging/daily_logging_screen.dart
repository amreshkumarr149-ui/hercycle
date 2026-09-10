import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hercycle/core/database_repository.dart';
import 'package:hercycle/core/notification_service.dart';
import 'package:hercycle/core/sync_service.dart';
import 'package:hercycle/core/telemetry_service.dart';
import 'package:hercycle/models/daily_log.dart';
import 'package:hercycle/providers/prediction_provider.dart';
import 'package:hercycle/providers/clinical_data_provider.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Which category of the daily log to show. Calendar category cards open
/// a focused mini-form for just one section; [all] shows the full form.
enum LogSection { all, period, symptoms, mood, mucus, lh }

extension LogSectionLabel on LogSection {
  String get title {
    switch (this) {
      case LogSection.all:
        return 'Daily Log';
      case LogSection.period:
        return 'Period';
      case LogSection.symptoms:
        return 'Physical Symptoms';
      case LogSection.mood:
        return 'Mood';
      case LogSection.mucus:
        return 'Mucus';
      case LogSection.lh:
        return 'LH Test';
    }
  }
}

class DailyLoggingScreen extends ConsumerStatefulWidget {
  final String date;
  final LogSection initialSection;
  const DailyLoggingScreen({
    super.key,
    required this.date,
    this.initialSection = LogSection.all,
  });

  @override
  ConsumerState<DailyLoggingScreen> createState() => _DailyLoggingScreenState();
}

class _DailyLoggingScreenState extends ConsumerState<DailyLoggingScreen> {
  bool _period = false;
  final List<String> _symptoms = [];
  String _mood = '';
  String _mucus = '';
  String _lhTest = '';
  String _flowIntensity = 'None';
  double _painScore = 0;
  double _crampScore = 0;
  bool _pelvicPressure = false;
  bool _backBowelPain = false;
  bool _isLoading = false;
  final _notesController = TextEditingController();

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  final List<String> _availableSymptoms = const ['Cramps', 'Headache', 'Bloating', 'Fatigue'];
  final List<String> _availableMoods = const ['Happy', 'Calm', 'Irritable', 'Sad'];
  final List<String> _availableMucus = const ['Dry', 'Sticky', 'Creamy', 'Watery', 'Eggwhite'];
  final List<String> _availableLh = const ['Not tested', 'Negative', 'Positive'];
  final List<String> _availableFlow = const ['None', 'Light', 'Medium', 'Heavy'];

  bool get _showAll => widget.initialSection == LogSection.all;
  bool _shows(LogSection s) => _showAll || widget.initialSection == s;

  @override
  void initState() {
    super.initState();
    _loadExistingLog();
  }

  Future<void> _loadExistingLog() async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return;
    try {
      final existingLog = await DatabaseRepository().getLog(userId, widget.date);
      if (existingLog != null && mounted) {
        setState(() {
          _period = existingLog.period;
          _symptoms
            ..clear()
            ..addAll(existingLog.symptoms);
          _mood = existingLog.mood;
          _mucus = existingLog.mucus;
          _lhTest = existingLog.lhTest;
          _flowIntensity = existingLog.flowIntensity;
          _painScore = existingLog.painScore.toDouble().clamp(0, 10);
          _crampScore = (existingLog.symptomIntensity['Cramps'] ?? 0).toDouble().clamp(0, 10);
          _pelvicPressure = existingLog.pelvicPressure;
          _backBowelPain = existingLog.backBowelPain;
          _notesController.text = existingLog.notes;
        });
      }
    } catch (_) {
      // Offline / read failure: keep blank form rather than crashing.
    }
  }

  @override
  Widget build(BuildContext context) {
    final section = widget.initialSection;
    return Scaffold(
      appBar: AppBar(
          title: Text(section == LogSection.all
              ? 'Log for ${widget.date}'
              : '${section.title} • ${widget.date}')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_shows(LogSection.period)) ...[
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [BoxShadow(color: Colors.pink.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 3))],
                ),
                child: Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  child: SwitchListTile(
                    title: const Text('Period', style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: const Text('Did your period occur on this date?'),
                    value: _period,
                    onChanged: (val) => setState(() => _period = val),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text('Flow Intensity', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A))),
              const SizedBox(height: 4),
              const Text('Needed for fibroid pattern screening', style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: _availableFlow.map((flow) => ChoiceChip(
                  label: Text(flow),
                  selected: _flowIntensity == flow,
                  onSelected: (selected) => setState(() => _flowIntensity = selected ? flow : 'None'),
                )).toList(),
              ),
              const SizedBox(height: 20),
            ],

            if (_shows(LogSection.symptoms)) ...[
              const Text('Physical Symptoms', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A))),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: _availableSymptoms.map((symptom) => FilterChip(
                  label: Text(symptom),
                  selected: _symptoms.contains(symptom),
                  onSelected: (selected) {
                    setState(() {
                      if (selected) {
                        _symptoms.add(symptom);
                      } else {
                        _symptoms.remove(symptom);
                      }
                    });
                  },
                )).toList(),
              ),
              const SizedBox(height: 12),
              if (_symptoms.contains('Cramps')) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Cramp intensity (0-10)', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A))),
                    Text('${_crampScore.round()}/10', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFFC26D81))),
                  ],
                ),
                Slider(
                  value: _crampScore,
                  min: 0,
                  max: 10,
                  divisions: 10,
                  label: _crampScore.round().toString(),
                  onChanged: (val) => setState(() => _crampScore = val),
                ),
                const SizedBox(height: 8),
              ],
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Pain Score (0-10)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A))),
                  Text('${_painScore.round()}/10', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFFC26D81))),
                ],
              ),
              Slider(
                value: _painScore,
                min: 0,
                max: 10,
                divisions: 10,
                label: _painScore.round().toString(),
                onChanged: (val) => setState(() => _painScore = val),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                title: const Text('Pelvic pressure', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: const Text('Heaviness or pressure in pelvic area'),
                value: _pelvicPressure,
                onChanged: (val) => setState(() => _pelvicPressure = val),
              ),
              SwitchListTile(
                title: const Text('Severe back / bowel pain', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: const Text('Severe lower back or bowel pain today'),
                value: _backBowelPain,
                onChanged: (val) => setState(() => _backBowelPain = val),
              ),
              const SizedBox(height: 20),
            ],

            if (_shows(LogSection.mood)) ...[
              const Text('Mood', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A))),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: _availableMoods.map((mood) => ChoiceChip(
                  label: Text(mood),
                  selected: _mood == mood,
                  onSelected: (selected) => setState(() => _mood = selected ? mood : ''),
                )).toList(),
              ),
              const SizedBox(height: 20),
            ],

            if (_shows(LogSection.mucus)) ...[
              const Text('Cervical Mucus', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A))),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: _availableMucus.map((mucus) => ChoiceChip(
                  label: Text(mucus),
                  selected: _mucus == mucus,
                  onSelected: (selected) => setState(() => _mucus = selected ? mucus : ''),
                )).toList(),
              ),
              const SizedBox(height: 20),
            ],

            if (_shows(LogSection.lh)) ...[
              const Text('LH Test', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A))),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: _availableLh.map((test) => ChoiceChip(
                  label: Text(test),
                  selected: _lhTest == test,
                  onSelected: (selected) => setState(() => _lhTest = selected ? test : ''),
                )).toList(),
              ),
              const SizedBox(height: 20),
            ],

            const Text('Notes (optional)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A))),
            const SizedBox(height: 8),
            TextField(
              controller: _notesController,
              decoration: const InputDecoration(
                hintText: 'Anything worth remembering about this day…',
                prefixIcon: Icon(Icons.edit_note),
              ),
              maxLines: 3,
              minLines: 1,
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isLoading ? null : () async {
                  final intensity = <String, int>{};
                  if (_symptoms.contains('Cramps')) {
                    intensity['Cramps'] = _crampScore.round();
                  }
                  final log = DailyLog(
                    date: widget.date,
                    period: _period,
                    symptoms: _symptoms,
                    mood: _mood,
                    mucus: _mucus,
                    lhTest: _lhTest,
                    flowIntensity: _flowIntensity,
                    painScore: _painScore.round(),
                    pelvicPressure: _pelvicPressure,
                    backBowelPain: _backBowelPain,
                    symptomIntensity: intensity,
                    notes: _notesController.text,
                  );
                  final userId = FirebaseAuth.instance.currentUser?.uid;
                  if (userId == null) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("User not logged in")));
                    return;
                  }
                  setState(() => _isLoading = true);
                  final ctx = context;
                  try {
                    DailyLog? before;
                    try {
                      before = await DatabaseRepository()
                          .getLog(userId, widget.date);
                    } catch (_) {}
                    await DatabaseRepository().saveLog(userId, log);
                    await SyncService.markSynced(ref, userId, widget.date);
                    await TelemetryService.logEvent('daily_log_saved');
                    // State-machine triggers -> instant local notifications.
                    final wasWet = before != null &&
                        NotificationService.isWetMucus(before.mucus);
                    if (NotificationService.isWetMucus(log.mucus) &&
                        !wasWet) {
                      NotificationService.notifyMucusShift();
                    }
                    final wasPositive =
                        before?.lhTest.toLowerCase() == 'positive';
                    if (log.lhTest.toLowerCase() == 'positive' &&
                        !wasPositive) {
                      NotificationService.notifyLhPeak();
                    }
                    // Refresh dashboard predictions + clinical reports so the
                    // new log is reflected immediately (no restart needed).
                    ref.invalidate(predictionProvider);
                    ref.invalidate(clinicalDataProvider);
                    if (!mounted) return;
                    // ignore: use_build_context_synchronously
                    Navigator.pop(ctx, true);
                  } catch (e) {
                    // Offline: queue for later instead of losing the entry.
                    await SyncService.enqueue(ref, userId, log);
                    await TelemetryService.recordError(e, StackTrace.current,
                        reason: 'daily-log-save');
                    if (!mounted) return;
                    // ignore: use_build_context_synchronously
                    ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                        content: Text(
                            'No connection — saved on this device, will sync later')));
                  } finally {
                    if (mounted) setState(() => _isLoading = false);
                  }
                },
                child: _isLoading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Text('Save Log'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
