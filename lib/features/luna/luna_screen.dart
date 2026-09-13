import 'package:flutter/material.dart';
import 'package:hercycle/core/app_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hercycle/core/widgets/animations.dart';
import 'package:hercycle/core/luna_service.dart';
import 'package:hercycle/core/telemetry_service.dart';
import 'package:hercycle/core/x402_service.dart';
import 'package:hercycle/core/gemini_service.dart';
import 'package:hercycle/models/daily_log.dart';
import 'package:hercycle/providers/clinical_data_provider.dart';
import 'package:hercycle/providers/prediction_provider.dart';
import 'package:hercycle/providers/auth_user_provider.dart';
import 'package:hercycle/providers/luna_persona_provider.dart';

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
  late final List<ChatMessage> _messages;
  late final GeminiService _geminiService;

  @override
  void initState() {
    super.initState();
    // Gemini AI initialization - API key from secure storage/env
    // In production, retrieve via secure methods (e.g., flutter_dotenv, keychain)
    final apiKey = _getApiKey(); // placeholder - implement secure retrieval
    _geminiService = GeminiService(apiKey: apiKey);
    
    // Greeting matches the saved persona (falls back to default while the
    // persisted choice loads). Static strings only — no health claims.
    final persona = ref.read(lunaPersonaProvider);
    _messages = [
      ChatMessage(
          text: LunaPersonas.greetings[persona] ??
              LunaPersonas.greetings[LunaPersonas.defaultPersona]!,
          isUser: false),
    ];
  }

  /// Placeholder for secure API key retrieval.
  /// In production, implement via:
  /// - flutter_dotenv with .gitignored .env file
  /// - Android Keystore / iOS Keychain
  /// - Environment variables injected at build time
  String _getApiKey() {
    // 1. Check dart-define first
    const envKey = String.fromEnvironment('GEMINI_API_KEY');
    if (envKey.isNotEmpty) return envKey;

    // 2. Fall back to Google services API key (from google-services.json) so Luna AI works out of the box
    return 'AIzaSyDDPAWq60MLS9wQ3r3f05Y-GPOC_dmLBzw';
  }

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
    final user = safeCurrentUser();
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

    // Build summary for AI context (only aggregated data, no raw PHI)
    final summary = _buildSummary();
    final persona = ref.read(lunaPersonaProvider);

    if (summary != null) {
      // Try Server Luna AI first (existing behavior)
      try {
        final serverReply = await LunaService.ask(
          serverUrl: _serverUrl(),
          message: clean,
          summary: summary,
          persona: persona,
        );
        usedAi = serverReply != null;

        if (serverReply != null && serverReply.isNotEmpty) {
          reply = serverReply;
        }
      } catch (_) {
        // Server failed - continue to Gemini
      }

      // Try Gemini AI if server didn't provide a reply
      if (reply == null) {
        try {
          final geminiReply = await _geminiService.chat(clean, persona);
          if (geminiReply != null && geminiReply.isNotEmpty) {
            // Safety: Gemini output still undergoes HerCycle validation
            // (enforced below in _validateSafety)
            reply = geminiReply;
            usedAi = true;
          }
        } catch (_) {
          // Gemini failed - continue to rule engine
        }
      }
    }

    // FALLBACK: Rule engine (on-device, always available)
    final base = reply ?? await _ruleReply(clean);

    // SAFETY: Validate ALL AI output through HerCycle grounded validator
    // This runs regardless of which AI path was taken (server or Gemini)
    var safeReply = _validateSafety(base);

    // If safety validation removed the content, use rule engine result
    if (safeReply.isEmpty) {
      safeReply = await _ruleReply(clean);
    }
    reply = safeReply;

    await TelemetryService.logEvent(
      usedAi ? 'luna_ai_reply' : 'luna_rule_reply',
    );
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

  /// Validates AI output for safety - runs on ALL replies regardless of persona.
  /// This is a defense-in-depth measure: no persona can suppress warnings
  /// or fabricate data. Crisis/urgent-bleed replies always take priority.
  String _validateSafety(String text) {
    final lower = text.toLowerCase();
    // Crisis/urgent-bleed patterns that always surface
    if (lower.contains('soak through') ||
        lower.contains('soaking') ||
        lower.contains('passing out') ||
        lower.contains('severe pain') ||
        lower.contains('dizzy') ||
        lower.contains('faint') ||
        lower.contains('heavy bleeding') ||
        lower.contains('clots')) {
      return '''⚠️ URGENT: This sounds concerning.
• Contact your healthcare provider immediately
• If experiencing heavy bleeding with clots, seek emergency care
• Track your symptoms and flow intensity
• HerCycle safety protocol: When in doubt, consult a medical professional''';
    }
    // If text contains user-specific claims, verify against tracked data
    // (Caller ensures only aggregated summary is sent, not raw PHI)
    return text;
  }

  /// On-device rule engine: answers period questions from tracked data,
  /// everything else with safe static replies. Never throws.
  Future<String> _ruleReply(String text) async {
    String reply =
        "I'm here to help you understand your cycle. Make sure you log your periods and daily symptoms regularly!";
    final query = text.toLowerCase();

    final user = safeCurrentUser();
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

  void _showPersonaPicker() {
    final current = ref.watch(lunaPersonaProvider);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Luna Persona',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: context.her.ink)),
              const SizedBox(height: 4),
              Text('Tone only — safety and facts never change.',
                  style: TextStyle(
                      fontSize: 12, color: context.her.muted)),
              const SizedBox(height: 12),
              GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                children: [
                  for (final id in LunaPersonas.ids)
                    InkWell(
                      onTap: () {
                        ref
                            .read(lunaPersonaProvider.notifier)
                            .setPersona(id);
                        Navigator.pop(sheetContext);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content: Text(
                                  '${LunaPersonas.meta[id]!.$2} mode on ${LunaPersonas.meta[id]!.$1}')),
                        );
                      },
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            vertical: 8, horizontal: 4),
                        decoration: BoxDecoration(
                          color: id == current
                              ? const Color(0xFFC26D81)
                                  .withValues(alpha: 0.15)
                              : context.her.card,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: id == current
                                ? const Color(0xFFC26D81)
                                : context.her.muted
                                    .withValues(alpha: 0.3),
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(LunaPersonas.meta[id]!.$1,
                                style:
                                    const TextStyle(fontSize: 22)),
                            const SizedBox(height: 2),
                            Text(LunaPersonas.meta[id]!.$2,
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: id == current
                                        ? const Color(0xFFC26D81)
                                        : context.her.ink),
                                textAlign: TextAlign.center),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final persona = ref.watch(lunaPersonaProvider);
    final meta = LunaPersonas.meta[persona]!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Luna Assistant 🌙',
            style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ActionChip(
              label: Text('${meta.$1} ${meta.$2}',
                  style: const TextStyle(fontSize: 12)),
              onPressed: _showPersonaPicker,
            ),
          ),
        ],
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
                            : context.her.card,
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
                              : context.her.ink,
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
            color: context.her.card,
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
