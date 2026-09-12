import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hercycle/providers/auth_user_provider.dart';

/// Luna persona ids. Tone only — safety and facts are persona-independent
/// (enforced server-side). Unknown values degrade to [defaultPersona].
class LunaPersonas {
  static const List<String> ids = [
    'clinician',
    'caregiver',
    'sweetheart',
    'flirt',
    'bestie',
    'bigsis',
    'calm',
    'hype',
  ];

  static const Map<String, (String, String, String)> meta = {
    'clinician': ('🩺', 'Clinician', 'Clear, factual, direct'),
    'caregiver': ('🫶', 'Caregiver', 'Gentle and reassuring'),
    'sweetheart': ('💗', 'Sweetheart', 'Warm and encouraging'),
    'flirt': ('😏', 'Flirt', 'Playful and charming'),
    'bestie': ('🧡', 'Bestie', 'Casual, funny, honest'),
    'bigsis': ('👭', 'Big Sis', 'Protective and practical'),
    'calm': ('🧘', 'Calm One', 'Soft and grounding'),
    'hype': ('🎉', 'Hype Friend', 'Energetic and optimistic'),
  };

  static const String defaultPersona = 'caregiver';

  static String normalize(String? value) =>
      ids.contains(value) ? value! : defaultPersona;

  /// Static per-persona greetings (no health claims — safe offline too).
  static const Map<String, String> greetings = {
    'clinician':
        "Hello. I'm Luna — ask me about your recorded cycles, symptoms, or trends.",
    'caregiver':
        "Hello, and welcome. I'm Luna — tell me what's on your mind about your cycle. 🌙",
    'sweetheart':
        "Hiii! I'm Luna, so happy you're here! Ask me anything, lovely! 💗",
    'flirt':
        "Well hello there 😏 I'm Luna — your cycle, decoded with charm.",
    'bestie':
        "Heyy bestie! It's Luna!! Spill — what's up with your cycle today?? 💅",
    'bigsis':
        "Hey. Big-sis Luna here — I've got you. What's going on?",
    'calm':
        "Hello. I'm Luna. Take a breath… and tell me what's on your mind.",
    'hype':
        "HEYYY!! Luna here and we are DOING THIS!! Ask me anything!! 🎉",
  };
}

/// Selected Luna persona id, persisted on the user doc (cross-device).
/// Falls back to the default when logged out, offline, or unset. The
/// on-device offline fallback stays persona-neutral by design.
class LunaPersonaNotifier extends StateNotifier<String> {
  LunaPersonaNotifier(this.ref) : super(LunaPersonas.defaultPersona) {
    _load();
  }

  final Ref ref;

  Future<void> _load() async {
    try {
      final user = ref.read(authUserProvider).value ?? safeCurrentUser();
      if (user == null) return;
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final raw = doc.data()?['lunaPersona']?.toString();
      if (raw != null && LunaPersonas.ids.contains(raw)) {
        state = raw;
      }
    } catch (_) {
      // Offline / logged out: stay on the default.
    }
  }

  Future<void> setPersona(String id) async {
    if (!LunaPersonas.ids.contains(id)) return;
    state = id;
    try {
      final user = ref.read(authUserProvider).value ?? safeCurrentUser();
      if (user == null) return;
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set({'lunaPersona': id}, SetOptions(merge: true));
    } catch (_) {
      // Best-effort persistence; the in-memory persona still applies.
    }
  }
}

final lunaPersonaProvider =
    StateNotifierProvider<LunaPersonaNotifier, String>(
        (ref) => LunaPersonaNotifier(ref));
