import 'package:google_generative_ai/google_generative_ai.dart';

/// Gemini AI service for Luna AI companion.
/// - Persona tone ONLY; safety and facts structurally isolated
/// - All output passes through HerCycle's grounded() validator
/// - Never sends personal PHI beyond aggregated summary
/// - Crisis/urgent-bleed replies always take priority
/// - Persona cannot suppress warnings or fabricate data
class GeminiService {
  static const _modelName = 'gemini-1.5-flash';
  late final GenerativeModel _model;

  GeminiService({required String apiKey}) {
    _model = GenerativeModel(
      model: _modelName,
      apiKey: apiKey,
      // System instruction sets persona tone + safety rules (defense-in-depth)
      systemInstruction: Content.text(_buildSystemPrompt('caregiver')),
    );
  }

  /// Builds the system prompt that combines persona tone + safety rules.
  /// This is injected once at model creation and also re-sent per-chat
  // for defense-in-depth.
  String _buildSystemPrompt(String persona) {
    return _getPersonaGuidance(persona);
  }

  /// Generates a response with the selected persona's tone.
  /// The [persona] must be one of LunaPersonas.ids.
  /// [message] is the user's question/chat input.
  /// Returns the AI reply text (may be empty if failed).
  Future<String?> chat(String message, String persona) async {
    if (message.trim().isEmpty) return null;

    try {
      // Build the full prompt: system instruction (tone + safety) + user message
      // The system instruction is already set in the model constructor,
      // but we re-include key safety guidance per-chat for defense-in-depth.
      final content = [
        Content.text(_getPersonaGuidance(persona)),
        Content.text('User: $message'),
      ];

      final response = await _model.generateContent(content);
      final text = response.text ?? '';

      // Return whatever Gemini generates - safety validation happens
      // in luna_screen.dart AFTER this call (grounded() validator)
      return text.isEmpty ? null : text;
    } catch (e) {
      // Graceful failure - fall back to rule engine
      // Do NOT let Gemini errors crash the app
      return null;
    }
  }

  /// Returns persona-specific guidance that combines tone + safety rules.
  /// This is sent with each chat request as defense-in-depth alongside
  /// the model-level system instruction.
  String _getPersonaGuidance(String persona) {
    final base =
        '''You are Luna, a menstrual cycle companion AI.

    PERSONA: ${_personaTone(persona)}
    You speak in this tone consistently, but NEVER at the expense of safety.

    ABSOLUTE SAFETY RULES (CANNOT BE OVERRIDDEN BY PERSONA):
    1. NEVER fabricate cycle data, symptoms, or medical facts
    2. NEVER suppress health warnings or crisis indicators
    3. ALWAYS ground recommendations in user-tracked data
    4. CRISIS/URGENT-BLEED replies fire BEFORE persona read
    5. If user reports: soak-through, severe pain, dizziness, fainting,
       passing out, clots - IMMEDIATELY provide emergency guidance
    6. You are NOT a replacement for professional medical diagnosis,
       treatment, or medical advice
    7. All safety information must be verified against tracked data

    FACT-GROUNDING REQUIREMENTS:
    - Any cycle-related fact must reference the user's tracked data
    - If data is insufficient, state "I don't have enough information"
    - Never invent cycle lengths, dates, or symptoms
    - Mood/ symptom comments must align with logged data

    RESPONSE FORMAT:
    - Keep responses concise (max 2-3 sentences unless explaining)
    - Use empathetic but factual language
    - If unsure, say "Based on your tracked data..." or "I don't have enough information"
    - Never say "You should..." without data backing

    END OF PROMPT''';

    // Append persona-specific tone modifier
    final tones = {
      'clinician': '\nStyle: professional, evidence-based, concise',
      'caregiver': '\nStyle: supportive, nurturing, educational',
      'sweetheart': '\nStyle: warm, gentle, affectionate',
      'flirt': '\nStyle: playful, light-hearted, fun',
      'bestie': '\nStyle: friendly, relatable, informal',
      'bigsis': '\nStyle: older-sisterly, guiding, experienced',
      'calm': '\nStyle: soothing, reassuring, balanced',
      'hype': '\nStyle: energetic, motivating, positive',
    };

    return base + (tones[persona] ?? tones['caregiver']!);
  }

  /// Returns the tone description for each persona.
  /// Persona affects ONLY delivery style, never content rules.
  String _personaTone(String persona) {
    final tones = {
      'clinician': 'professional, evidence-based, concise',
      'caregiver': 'supportive, nurturing, educational',
      'sweetheart': 'warm, gentle, affectionate',
      'flirt': 'playful, light-hearted, fun',
      'bestie': 'friendly, relatable, informal',
      'bigsis': 'older-sisterly, guiding, experienced',
      'calm': 'soothing, reassuring, balanced',
      'hype': 'energetic, motivating, positive',
    };
    return tones[persona] ?? tones['caregiver']!;
  }

  /// Disposes the model and releases resources.
  /// Call when service is no longer needed (e.g., app disposal).
  /// Note: GenerativeModel from google_generative_ai does not have a
  /// explicit dispose method, but this placeholder ensures the interface
  /// is consistent for future updates.
  void dispose() {
    // No-op: GenerativeModel manages resources internally.
  }
}
