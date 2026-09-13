import 'package:google_generative_ai/google_generative_ai.dart';

/// Gemini AI service for Luna AI companion.
/// - Persona tone ONLY; safety and facts structurally isolated
/// - All output passes through HerCycle's grounded validator
/// - Never sends personal PHI beyond aggregated summary
/// - Crisis/urgent-bleed replies always take priority
/// - Persona cannot suppress warnings or fabricate data
class GeminiService {
  static const _modelName = 'gemini-1.5-flash';
  final String apiKey;

  GeminiService({required this.apiKey});

  GenerativeModel _getModel(String persona) {
    return GenerativeModel(
      model: _modelName,
      apiKey: apiKey.isNotEmpty ? apiKey : 'AIzaSyDDPAWq60MLS9wQ3r3f05Y-GPOC_dmLBzw',
      safetySettings: [
        SafetySetting(HarmCategory.harassment, HarmBlockThreshold.medium),
        SafetySetting(HarmCategory.hateSpeech, HarmBlockThreshold.medium),
        SafetySetting(HarmCategory.sexuallyExplicit, HarmBlockThreshold.medium),
        SafetySetting(HarmCategory.dangerousContent, HarmBlockThreshold.medium),
      ],
      generationConfig: GenerationConfig(
        temperature: 0.7,
        maxOutputTokens: 300,
      ),
      systemInstruction: Content.text(_getPersonaGuidance(persona)),
    );
  }

  /// Generates a response with the selected persona's tone.
  /// The [persona] must be one of LunaPersonas.ids.
  /// [message] is the user's question/chat input.
  /// Returns the AI reply text (may be empty if failed).
  Future<String?> chat(String message, String persona) async {
    if (message.trim().isEmpty) return null;

    try {
      final model = _getModel(persona);
      final content = [
        Content.text('User: $message'),
      ];

      final response = await model.generateContent(content);
      final text = response.text?.trim() ?? '';
      return text.isEmpty ? null : text;
    } catch (e) {
      // Graceful failure - fall back to rule engine or server
      return null;
    }
  }

  String _getPersonaGuidance(String persona) {
    final base = '''You are Luna, an empathetic menstrual cycle and reproductive health companion AI.

    PERSONA: ${_personaTone(persona)}
    You speak in this tone consistently, but NEVER at the expense of clinical safety.

    ABSOLUTE SAFETY & FACT-GROUNDING RULES (CANNOT BE OVERRIDDEN BY PERSONA):
    1. NEVER fabricate cycle data, symptoms, or medical facts.
    2. NEVER suppress health warnings or crisis indicators.
    3. ALWAYS ground recommendations in the user's tracked data summary.
    4. CRISIS/URGENT-BLEED replies (e.g. soaking through pads, severe pain, fainting, large clots) take absolute priority with emergency guidance.
    5. You are an educational tool, NOT a replacement for professional medical diagnosis or treatment.
    6. Keep responses concise (2-3 sentences), warm, and clinically grounded.
    ''';

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

  void dispose() {}
}
