import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hercycle/core/widgets/animations.dart';
import 'package:hercycle/core/luna_service.dart';
import 'package:hercycle/core/telemetry_service.dart';
import 'package:hercycle/core/x402_service.dart';
import 'package:hercycle/models/daily_log.dart';
import 'package:hercycle/providers/clinical_data_provider.dart';
import 'package:hercycle/providers/prediction_provider.dart';

class ChatMessage {
  final String text;
  final bool isUser;
  ChatMessage({required this.text, required this.isUser});
}

const _suggestions = [
  'Where am I in my cycle?',
  "When's my next period?",
  'How were my cramps?',
  'Summarize lately',
];

class LunaScreen extends ConsumerStatefulWidget {
  const LunaScreen({super.key});

  @override
  ConsumerState<LunaScreen> createState() => _LunaScreenState();
}

class _LunaScreenState extends ConsumerState<LunaScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _typing = false;
  final List<ChatMessage> _messages = [
    ChatMessage(
        text:
            "Hello! I'm Luna, your cycle assistant. Ask me anything about your recorded cycles, symptoms, or trends! 🌙",
        isUser: false),
  ];

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  String _fmtDay(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Builds the grounded 90-day summary from live providers. Returns null
  /// when signed out (rule engine handles that case on its own).
  Map<String, dynamic>? _buildSummary() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    final pred =
        Map<String, dynamic>.from(ref.read(predictionProvider).valueOrNull ?? {});
    final next = pred['nextPeriod'];
    if (next is DateTime) pred['nextPeriod'] = _fmtDay(next);
    final ovu = pred['ovulationDate'];
    if (ovu is DateTime) pred['ovulationDate'] = _fmtDay(ovu);
    final clinical = ref.read(clinicalDataProvider).value;
    final logs = (clinical?['logs'] as List<DailyLog>?) ?? [];
    final profile = clinical?['user'] as Map<String, dynamic>?;
    return LunaService.buildSummary(
        profile: profile, logs: logs, prediction: pred);
  }

  String _serverUrl() {
    final clinical = ref.read(clinicalDataProvider).value;
    final user = clinical?['user'] as Map<String, dynamic>?;
    return user?['x402ServerUrl']?.toString() ??
        X402Service.defaultServerUrl;
  }

  void _handleSubmitted(String text) async {
    final clean = text.trim();
    if (clean.isEmpty || _typing) return;
    _controller.clear();
    setState(() {
      _messages.add(ChatMessage(text: clean, isUser: true));
      _typing = true;
    });
    _scrollToBottom();

    String? reply;
    var usedAi = false;
    try {
      final summary = _buildSummary();
      if (summary != null) {
        reply = await LunaService.ask(
            serverUrl: _serverUrl(), message: clean, summary: summary);
        usedAi = reply != null;
      }
    } catch (_) {
      reply = null;
    }
    reply ??= await _ruleReply(clean);
    await TelemetryService.logEvent(usedAi ? 'luna_ai_reply' : 'luna_rule_reply');
    if (!mounted) return;
    setState(() {
      _typing = false;
      _messages.add(ChatMessage(text: reply!, isUser: false));
      // Bound session memory: keep the greeting plus the latest turns.
      const maxMessages = 101;
      if (_messages.length > maxMessages) {
        _messages.removeRange(1, _messages.length - (maxMessages - 1));
      }
    });
    _scrollToBottom();
  }

  /// On-device rule engine: answers period questions from tracked data,
  /// everything else with safe static replies. Never throws.
  Future<String> _ruleReply(String text) async {
    String reply =
        "I'm here to help you understand your cycle. Make sure you log your periods and daily symptoms regularly!";
    final query = text.toLowerCase();

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      if (query.contains('period') || query.contains('when')) {
        try {
          final profileDoc = await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .get();
          final data = profileDoc.data();
          final rawStart = data?['lastPeriodStartDate'];
          final DateTime? lastDate = rawStart is Timestamp
              ? rawStart.toDate()
              : (rawStart is String ? DateTime.tryParse(rawStart) : null);
          if (lastDate != null) {
            final rawLen = data?['typicalCycleLength'];
            final cycleLen = rawLen is int
                ? rawLen.clamp(15, 60)
                : (rawLen is num ? rawLen.toInt().clamp(15, 60) : 28);
            final today = DateTime.now();
            final todayDay =
                DateTime(today.year, today.month, today.day);
            final startDay = DateTime(
                lastDate.year, lastDate.month, lastDate.day);
            final diff = todayDay.difference(startDay).inDays;
            // Roll forward across elapsed cycles so the estimate is future-facing.
            final rolled = diff < 0
                ? startDay.add(Duration(days: cycleLen))
                : startDay.add(
                    Duration(days: ((diff ~/ cycleLen) + 1) * cycleLen));
            reply =
                "Your last recorded period started on ${startDay.toLocal().toString().split(' ')[0]}. Your estimated next period is around ${rolled.toLocal().toString().split(' ')[0]}!";
          } else {
            reply =
                "You haven't set your last period date yet. Go to your profile or log a period to get accurate predictions!";
          }
        } catch (_) {
          reply =
              "I couldn't reach your cycle data right now (offline?). Try again when you're back online!";
        }
      } else if (query.contains('symptom') ||
          query.contains('headache') ||
          query.contains('cramp')) {
        reply =
            "Tracking your physical symptoms like cramps or headaches every cycle helps you notice recurring patterns before your period starts.";
      } else if (query.contains('mood') ||
          query.contains('feel')) {
        reply =
            "Mood fluctuations are completely normal throughout different phases of your cycle due to changing hormone levels.";
      }
    }
    return reply;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Luna Assistant 🌙',
            style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length + (_typing ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == _messages.length) {
                  return const Align(
                    alignment: Alignment.centerLeft,
                    child: PulseGlow(
                      duration: Duration(milliseconds: 900),
                      child: Text('● ● ●',
                          style: TextStyle(
                              fontSize: 18, color: Color(0xFFC26D81))),
                    ),
                  );
                }
                final msg = _messages[index];
                return FadeSlideIn(
                  key: ValueKey('luna-$index'),
                  duration: const Duration(milliseconds: 250),
                  slideOffset: 12,
                  child: Align(
                    alignment: msg.isUser
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      constraints: BoxConstraints(
                          maxWidth:
                              MediaQuery.of(context).size.width * 0.75),
                      decoration: BoxDecoration(
                        color: msg.isUser
                            ? const Color(0xFFC26D81)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withValues(alpha: 0.03),
                              blurRadius: 5,
                              offset: const Offset(0, 2)),
                        ],
                      ),
                      child: Text(
                        msg.text,
                        style: TextStyle(
                          color: msg.isUser
                              ? Colors.white
                              : const Color(0xFF4A4A4A),
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _suggestions.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) => ActionChip(
                label: Text(_suggestions[i],
                    style: const TextStyle(fontSize: 12)),
                onPressed:
                    _typing ? null : () => _handleSubmitted(_suggestions[i]),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.white,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: 'Ask Luna a question...',
                      border: InputBorder.none,
                      filled: false,
                    ),
                    onSubmitted: _handleSubmitted,
                  ),
                ),
                IconButton(
                  icon: _typing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send,
                          color: Color(0xFFC26D81)),
                  onPressed: _typing
                      ? null
                      : () => _handleSubmitted(_controller.text),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
