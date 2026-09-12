import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hercycle/core/app_theme.dart';
import 'package:hercycle/core/database_repository.dart';
import 'package:hercycle/core/relief_ranking.dart';
import 'package:hercycle/core/sync_service.dart';
import 'package:hercycle/core/telemetry_service.dart';
import 'package:hercycle/features/home/home_screen.dart' show todayLogProvider;
import 'package:hercycle/models/daily_log.dart';
import 'package:hercycle/providers/prediction_provider.dart';
import 'package:hercycle/providers/auth_user_provider.dart';
import 'package:intl/intl.dart';

/// Cramp SOS: breathing pacer + the user's own remedies ranked by their
/// history + one-tap episode logging. Comfort only — never medical advice.
class SosScreen extends ConsumerStatefulWidget {
  const SosScreen({super.key});

  @override
  ConsumerState<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends ConsumerState<SosScreen> {
  List<RankedRelief> _ranked = const [];
  bool _loadingRanks = true;
  double _pain = 5;
  final Set<String> _selected = {};
  bool? _helped;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadRanks();
  }

  /// Aggregates relief totals across all logged days. Best-effort: any
  /// failure leaves the canonical untried list.
  Future<void> _loadRanks() async {
    try {
      final userId = safeCurrentUid();
      if (userId == null) {
        if (mounted) setState(() => _loadingRanks = false);
        return;
      }
      final logs = await DatabaseRepository().getAllLogs(userId);
      final totals = aggregateReliefs(
          logs.map((l) => {'reliefTried': l.reliefTried, 'reliefHelped': l.reliefHelped}));
      if (!mounted) return;
      setState(() {
        _ranked =
            rankReliefs(tried: totals.tried, helped: totals.helped);
        _loadingRanks = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _ranked = rankReliefs(tried: const {}, helped: const {});
        _loadingRanks = false;
      });
    }
  }

  Future<void> _saveEpisode() async {
    if (_saving || _selected.isEmpty) return;
    setState(() => _saving = true);
    final userId = safeCurrentUid();
    if (userId == null) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('You are not logged in.')));
      }
      return;
    }
    final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
    DailyLog? existing;
    try {
      existing = await DatabaseRepository().getLog(userId, todayStr);
    } catch (_) {
      existing = null;
    }
    final merged = recordEpisode(
      tried: existing?.reliefTried ?? const {},
      helped: existing?.reliefHelped ?? const {},
      reliefs: _selected.toList(),
      helpedIt: _helped == true,
    );
    final log = DailyLog(
      date: todayStr,
      period: existing?.period ?? false,
      symptoms: existing?.symptoms ?? const [],
      mood: existing?.mood ?? '',
      mucus: existing?.mucus ?? '',
      lhTest: existing?.lhTest ?? '',
      flowIntensity: existing?.flowIntensity ?? 'None',
      painScore: existing == null
          ? _pain.round()
          : (_pain.round() > existing.painScore
              ? _pain.round()
              : existing.painScore),
      pelvicPressure: existing?.pelvicPressure ?? false,
      backBowelPain: existing?.backBowelPain ?? false,
      notes: existing?.notes ?? '',
      symptomIntensity: existing?.symptomIntensity ?? const {},
      reliefTried: merged.tried,
      reliefHelped: merged.helped,
      intimacy: existing?.intimacy ?? false,
    );
    try {
      await DatabaseRepository().saveLog(userId, log);
      await SyncService.markSynced(ref, userId, todayStr);
      await TelemetryService.logEvent('sos_episode');
    } catch (e) {
      await SyncService.enqueue(ref, userId, log);
      await TelemetryService.recordError(e, StackTrace.current,
          reason: 'sos-save');
    }
    if (!mounted) return;
    ref.invalidate(todayLogProvider);
    ref.invalidate(predictionProvider);
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('SOS episode logged 💗 Feel better soon.')));
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cramp SOS',
            style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _BreathPacer(),
            const SizedBox(height: 20),
            Text('How bad is it right now?',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: context.her.ink)),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _pain,
                    min: 0,
                    max: 10,
                    divisions: 10,
                    label: _pain.round().toString(),
                    onChanged: (v) => setState(() => _pain = v),
                  ),
                ),
                Text('${_pain.round()}/10',
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFC26D81))),
              ],
            ),
            const SizedBox(height: 12),
            Text('What have you tried?',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: context.her.ink)),
            const SizedBox(height: 4),
            Text(
              _loadingRanks
                  ? 'Loading your history…'
                  : _ranked.any((r) => r.hasVerdict)
                      ? 'Ranked by what helped you before'
                      : 'No verdicts yet — try things and rate them',
              style:
                  TextStyle(fontSize: 12, color: context.her.muted),
            ),
            const SizedBox(height: 8),
            if (_loadingRanks)
              const Center(
                  child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(),
              ))
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _ranked.map((r) {
                  final on = _selected.contains(r.name);
                  return FilterChip(
                    label: Text('${r.name} • ${r.verdict}'),
                    selected: on,
                    onSelected: (sel) => setState(() {
                      if (sel) {
                        _selected.add(r.name);
                      } else {
                        _selected.remove(r.name);
                      }
                    }),
                  );
                }).toList(),
              ),
            const SizedBox(height: 16),
            Text('Did it help?',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: context.her.ink)),
            const SizedBox(height: 8),
            SegmentedButton<bool?>(
              segments: const [
                ButtonSegment(
                    value: true,
                    label: Text('Yes'),
                    icon: Icon(Icons.thumb_up_outlined)),
                ButtonSegment(
                    value: false,
                    label: Text('No'),
                    icon: Icon(Icons.thumb_down_outlined)),
                ButtonSegment(
                    value: null,
                    label: Text('Skip'),
                    icon: Icon(Icons.remove)),
              ],
              selected: {_helped},
              onSelectionChanged: (s) =>
                  setState(() => _helped = s.first),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed:
                  (_saving || _selected.isEmpty) ? null : _saveEpisode,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.favorite),
              label: Text(_saving ? 'Saving…' : 'Log SOS episode'),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: const Text(
                'Severe, sudden or unusual pain? Talk to a doctor promptly — SOS is comfort, not care.',
                style: TextStyle(fontSize: 12, height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Slow breathing pacer: 4s inhale / 4s exhale loop with a glowing circle.
class _BreathPacer extends StatefulWidget {
  const _BreathPacer();

  @override
  State<_BreathPacer> createState() => _BreathPacerState();
}

class _BreathPacerState extends State<_BreathPacer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _inhale = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat(reverse: true);
    _controller.addStatusListener((status) {
      if (!mounted) return;
      setState(() {
        _inhale = status != AnimationStatus.reverse;
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFF9C8D2), Color(0xFFC26D81)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          ScaleTransition(
            scale: Tween(begin: 0.92, end: 1.08).animate(
              CurvedAnimation(
                  parent: _controller, curve: Curves.easeInOut),
            ),
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.35),
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.8),
                    width: 2),
              ),
              child: const Icon(Icons.air,
                  color: Colors.white, size: 40),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _inhale ? 'Breathe in…' : 'Breathe out…',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
