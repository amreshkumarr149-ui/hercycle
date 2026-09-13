/**
 * HerCycle Luna AI
 *
 * Design:
 * 1. Crisis / emergency -> safe deterministic response
 * 2. Exact cycle-data questions -> deterministic response from HerCycle data
 * 3. Natural / interpretive questions -> Gemini using the 90-day summary
 * 4. Missing Gemini / failed validation -> honest fallback
 *
 * IMPORTANT:
 * - GEMINI_API_KEY must exist in server/.env
 * - Never put the Gemini API key in Flutter
 * - Never expose the Gemini API key to the client
 */

export interface LunaSummary {
  windowDays?: number;
  userName?: string;

  anchors?: {
    today?: string;
    currentDay?: number;
    phaseName?: string;
    nextPeriod?: string | null;
    daysUntilNextPeriod?: number;
    averageCycleLength?: number;
    ovulationLocked?: boolean;
    activeAlert?: string | null;
  };

  periodStarts?: string[] | null;

  symptoms?: {
    name: string;
    days: string[];
    avgScore: number | null;
  }[] | null;

  moods?: Record<string, number> | null;

  mucusTrail?: string[] | null;
  lhPositives?: string[] | null;
  painDays?: string[] | null;
  notes?: string[] | null;

  hadSexRecently?: string | null;

  daysLogged?: number;
}

export interface LunaReply {
  reply: string;
  source: 'rules' | 'ai';
}

/* ============================================================
   PERSONAS
   ============================================================ */

export const LUNA_PERSONAS = [
  'clinician',
  'caregiver',
  'sweetheart',
  'flirt',
  'bestie',
  'bigsis',
  'calm',
  'hype',
] as const;

export type LunaPersona = (typeof LUNA_PERSONAS)[number];

export const DEFAULT_PERSONA: LunaPersona = 'caregiver';

export function normalizePersona(value: unknown): LunaPersona {
  const normalized =
    typeof value === 'string' ? value.toLowerCase().trim() : '';

  return (LUNA_PERSONAS as readonly string[]).includes(normalized)
    ? (normalized as LunaPersona)
    : DEFAULT_PERSONA;
}

const PERSONA_STYLE: Record<LunaPersona, string> = {
  clinician:
    'Be clear, factual, direct and safety-focused. Use structured explanations when helpful. Avoid unnecessary emotional language.',

  caregiver:
    'Be gentle, patient, protective and reassuring. Explain things calmly and supportively.',

  sweetheart:
    'Be warm, affectionate and encouraging. Never create romantic or emotional dependency.',

  flirt:
    'Be playful and lightly teasing, but never sexualized. Health and safety always come first.',

  bestie:
    'Be casual, friendly, honest and conversational. Light humor is okay, but take symptoms seriously.',

  bigsis:
    'Be protective, honest and practical. Give useful next steps and gently call out risky decisions.',

  calm:
    'Be soft, patient and grounding. Give information in small, manageable pieces.',

  hype:
    'Be energetic, optimistic and encouraging, while never dismissing genuine symptoms or distress.',
};

export const PERSONA_BOUNDARY =
  'The persona controls tone, vocabulary, warmth, humor and sentence style ONLY. ' +
  'It must NEVER change medical accuracy, safety warnings, uncertainty, privacy rules, ' +
  'factual claims or professional-care recommendations. Never diagnose with certainty. ' +
  'Never present an estimate as proof.';

const PERSONA_GREETING: Record<LunaPersona, string> = {
  clinician:
    'Hello. I am Luna — ask me about your logged cycles and I will give you clear, factual answers.',

  caregiver:
    'Hello, and welcome. I am Luna — tell me what is on your mind about your cycle, and we will go through it gently together.',

  sweetheart:
    'Hiii! I am Luna, so happy you are here! Ask me anything about your cycle, lovely! 💗',

  flirt:
    'Well hello there 😏 I am Luna — your cycle, decoded with charm. What are we curious about today?',

  bestie:
    'Heyy bestie! It is Luna!! Spill — what is up with your cycle today?? 💅',

  bigsis:
    'Hey, little one. Big-sis Luna here — I have got you. What is going on with your cycle?',

  calm:
    'Hello. I am Luna. Take a breath… and tell me, one small piece at a time, what is on your mind.',

  hype:
    'HEYYY!! Luna here and we are DOING THIS!! Your cycle questions? Already handled!! 🎉',
};

export function personaGreeting(persona: unknown): string {
  return PERSONA_GREETING[normalizePersona(persona)];
}

/* ============================================================
   SAFETY
   ============================================================ */

const CRISIS = [
  'suicide',
  'suicidal',
  'kill myself',
  'kill me',
  'want to die',
  'end my life',
  'end it all',
  'self-harm',
  'self harm',
  'hurt myself',
];

const URGENT_BLEED = [
  'bleeding heavily',
  'bleeding a lot',
  'bleeding nonstop',
  'bleeding through',
  'cant stop bleeding',
  "can't stop bleeding",
  'soaking through',
  'emergency',
];

const DIAGNOSIS_CLAIMS = [
  'you have ',
  'you suffer from',
  'diagnosed with',
  'diagnosis is',
];

const has = (q: string, ...words: string[]) =>
  words.some((word) => q.includes(word));

/* ============================================================
   GROUNDING / VALIDATION
   ============================================================ */

function payloadText(summary: LunaSummary): string {
  return JSON.stringify(summary ?? {});
}

function datesIn(text: string): string[] {
  return text.match(/\b\d{4}-\d{2}-\d{2}\b/g) ?? [];
}

/**
 * Ensures AI does not invent:
 * - dates
 * - severity scores
 * - diagnoses
 */
export function grounded(
  reply: string,
  summary: LunaSummary,
): boolean {
  const payload = payloadText(summary);

  /* Every date must exist in the supplied summary. */
  for (const date of datesIn(reply)) {
    if (!payload.includes(date)) {
      console.warn(
        `[Luna] Rejected AI reply because date ${date} was not in summary.`,
      );
      return false;
    }
  }

  /* Scores such as 7/10 require actual symptom/pain data. */
  const scoreClaims = [
    ...reply.matchAll(/(\d+(?:\.\d+)?)\s*\/\s*10/g),
  ];

  if (scoreClaims.length > 0) {
    if (
      scoreClaims.some((match) => {
        const value = Number(match[1]);
        return value > 10 || value < 0;
      })
    ) {
      return false;
    }

    const hasScores =
      (summary.symptoms?.length ?? 0) > 0 ||
      (summary.painDays?.length ?? 0) > 0;

    if (!hasScores) {
      return false;
    }
  }

  /* No diagnostic claims. */
  const lowered = reply.toLowerCase();

  for (const claim of DIAGNOSIS_CLAIMS) {
    if (lowered.includes(claim)) {
      console.warn(
        `[Luna] Rejected AI reply because it contained a diagnostic claim.`,
      );
      return false;
    }
  }

  return true;
}

/* ============================================================
   FALLBACK
   ============================================================ */

const FALLBACK_TAILOR: Record<LunaPersona, string> = {
  clinician:
    'Log periods, symptoms and moods so future answers can be specific. For medical concerns, consult a healthcare professional.',

  caregiver:
    'Log a little more when you feel up to it — periods, symptoms and moods — and we can look at the pattern together. For medical concerns, a healthcare professional is the right next step.',

  sweetheart:
    'Log a little more, lovely — periods, symptoms and moods — and I will have much more to work with. For medical concerns, please see a healthcare professional. 💗',

  flirt:
    'Give me a little more to work with — log those periods and symptoms and I can spot patterns. Medical concerns? No detours: talk to a professional. 😏',

  bestie:
    'Bestie, give me some DATA to work with! Log your periods, symptoms and moods and I can look for patterns. Medical stuff goes to a professional. 💅',

  bigsis:
    'Here is the deal: log your periods, symptoms and moods, then ask me again and I can give you a more useful answer. Medical concerns belong with a professional.',

  calm:
    'No rush. When you are ready, log a little — periods, symptoms and moods — and ask again. For medical concerns, a professional is the safest path.',

  hype:
    'We need DATA, superstar! Log those periods, symptoms and moods and come back — then Luna can spot useful patterns. Medical concerns = professional care. 🎉',
};

function fallback(persona: LunaPersona): LunaReply {
  return {
    reply:
      `I can only answer from what is actually logged in your recent HerCycle history. ` +
      `${FALLBACK_TAILOR[persona]}`,

    source: 'rules',
  };
}

/* ============================================================
   CRISIS RESPONSES
   ============================================================ */

function crisisReply(): LunaReply {
  return {
    reply:
      "I'm really glad you told me. I'm only a cycle-tracking assistant and can't safely handle this situation. Please reach out right now to someone you trust, a local crisis helpline, or emergency services. You deserve support from real people. 💛",

    source: 'rules',
  };
}

function urgentBleedReply(): LunaReply {
  return {
    reply:
      'Heavy bleeding that will not stop or is soaking through protection needs prompt medical care. Please contact a doctor, urgent-care service or emergency services now. Your logged flow and pain history may help them understand what is happening. 💛',

    source: 'rules',
  };
}

/* ============================================================
   DETERMINISTIC FACTUAL QUESTIONS
   ============================================================ */

function factual(
  message: string,
  summary: LunaSummary,
): LunaReply | null {
  const q = message.toLowerCase().trim();

  const anchors = summary.anchors ?? {};

  const name = summary.userName
    ? `, ${summary.userName.split(' ')[0]}`
    : '';

  /* ----------------------------------------------------------
     NEXT PERIOD
     ---------------------------------------------------------- */

  const askingNextPeriod =
    has(
      q,
      'next period',
      'upcoming period',
      'next menstruation',
      'when will my period',
      'when is my period',
      'period due',
      'period coming',
      'period come',
    );

  if (askingNextPeriod) {
    if (!anchors.nextPeriod) {
      return {
        reply:
          `I don't have enough logged information to estimate your next period${name}. ` +
          `Log your period start date and I'll calculate it from your history.`,

        source: 'rules',
      };
    }

    return {
      reply:
        `Your estimated next period is around ${anchors.nextPeriod}` +
        `${
          anchors.daysUntilNextPeriod != null
            ? ` — about ${anchors.daysUntilNextPeriod} days away`
            : ''
        }. ` +
        `Remember, that is an estimate from your logged history, not a promise. 🌙`,

      source: 'rules',
    };
  }

  /* ----------------------------------------------------------
     LAST PERIOD
     ---------------------------------------------------------- */

  const askingLastPeriod =
    has(
      q,
      'last period',
      'last menstrual period',
      'period started',
      'period start date',
      'when did my period start',
      'when was my last period',
    );

  if (askingLastPeriod) {
    if (
      !summary.periodStarts ||
      summary.periodStarts.length === 0
    ) {
      return {
        reply:
          `You don't have a period start logged in the last 90 days${name}. ` +
          `Log one on the calendar and I'll track it from there.`,

        source: 'rules',
      };
    }

    const last =
      summary.periodStarts[
        summary.periodStarts.length - 1
      ];

    return {
      reply:
        `Your last logged period started on ${last}` +
        `${
          summary.periodStarts.length > 1
            ? `, and you've logged ${summary.periodStarts.length} period starts in the last 90 days`
            : ''
        }. 🌸`,

      source: 'rules',
    };
  }

  /* ----------------------------------------------------------
     PREGNANCY
     ---------------------------------------------------------- */

  if (has(q, 'pregnant', 'pregnancy', 'am i pregnant')) {
    const lastPeriod =
      summary.periodStarts &&
      summary.periodStarts.length > 0
        ? ` Your last logged period started ${summary.periodStarts[summary.periodStarts.length - 1]}.`
        : '';

    return {
      reply:
        `Only a pregnancy test can reliably answer whether you are pregnant. ` +
        `If your period is late, consider taking a test and speaking with a healthcare professional.` +
        `${last} I can still help you track your cycle and symptoms. 💛`,

      source: 'rules',
    };
  }

  /* ----------------------------------------------------------
     CURRENT PHASE
     ---------------------------------------------------------- */

  const askingPhase =
    has(
      q,
      'what phase am i in',
      'which phase am i in',
      'current phase',
      'cycle phase',
      'what day of my cycle',
      'cycle day',
      'where am i in my cycle',
    );

  if (askingPhase) {
    const day =
      anchors.currentDay != null
        ? `Day ${anchors.currentDay}`
        : 'an unknown cycle day';

    const phase =
      anchors.phaseName ?? 'an unconfirmed phase';

    return {
      reply:
        `You're on ${day} — ${phase}${name}. ` +
        `${anchors.activeAlert ?? 'Keep logging and I will keep the picture updated.'}`,

      source: 'rules',
    };
  }

  /* ----------------------------------------------------------
     CRAMPS
     ---------------------------------------------------------- */

  const askingCramps =
    has(
      q,
      'cramps',
      'cramp',
      'my cramps',
      'cramping',
    );

  if (askingCramps) {
    const cramps = (summary.symptoms ?? []).find((item) =>
      item.name.toLowerCase().includes('cramp'),
    );

    if (!cramps) {
      return {
        reply:
          `I don't see cramps logged in your last 90 days${name}. ` +
          `When they happen, log them and rate the intensity so I can track the pattern.`,

        source: 'rules',
      };
    }

    const severity =
      cramps.avgScore != null
        ? ` Average intensity: ${cramps.avgScore}/10.`
        : '';

    return {
      reply:
        `You logged cramps on ${cramps.days.length} day(s).${severity} ` +
        `Heat, gentle movement and rest commonly help, while severe or persistent pain is worth discussing with a healthcare professional. 💛`,

      source: 'rules',
    };
  }

  /* ----------------------------------------------------------
     HEADACHE
     ---------------------------------------------------------- */

  const askingHeadache =
    has(
      q,
      'headache history',
      'headaches',
      'my headache',
      'headache pattern',
      'migraine history',
    );

  if (askingHeadache) {
    const headache = (summary.symptoms ?? []).find(
      (item) =>
        item.name.toLowerCase().includes('headache') ||
        item.name.toLowerCase().includes('migraine'),
    );

    if (!headache) {
      return {
        reply:
          `I don't see headaches logged in your last 90 days${name}. ` +
          `If you get one, log it so Luna can look for patterns over time.`,

        source: 'rules',
      };
    }

    const severity =
      headache.avgScore != null
        ? ` Average intensity: ${headache.avgScore}/10.`
        : '';

    return {
      reply:
        `Headaches appear on ${headache.days.length} logged day(s).${severity} ` +
        `If you notice them repeatedly around a particular cycle phase, logging that pattern can be useful to discuss with a healthcare professional.`,

      source: 'rules',
    };
  }

  /* ----------------------------------------------------------
     MOOD
     ---------------------------------------------------------- */

  const askingMoodData =
    has(
      q,
      'mood history',
      'mood pattern',
      'moods logged',
      'most common mood',
      'most logged mood',
      'mood lately',
    );

  if (askingMoodData) {
    if (
      !summary.moods ||
      Object.keys(summary.moods).length === 0
    ) {
      return {
        reply:
          `I don't see mood data logged in your last 90 days${name}. ` +
          `Try logging your mood regularly and I can help you spot patterns.`,

        source: 'rules',
      };
    }

    const top = Object.entries(summary.moods).sort(
      (a, b) => b[1] - a[1],
    );

    return {
      reply:
        `Your most logged mood is ${top[0][0]} (${top[0][1]} days)` +
        `${
          top[1]
            ? `, followed by ${top[1][0]} (${top[1][1]} days)`
            : ''
        }. Mood patterns can vary across cycles, so your own tracking is the most useful reference. 💛`,

      source: 'rules',
    };
  }

  /* ----------------------------------------------------------
     CERVICAL MUCUS
     ---------------------------------------------------------- */

  const askingMucus =
    has(
      q,
      'mucus history',
      'mucus pattern',
      'cervical mucus history',
      'discharge history',
    );

  if (askingMucus) {
    if (
      !summary.mucusTrail ||
      summary.mucusTrail.length === 0
    ) {
      return {
        reply:
          `I don't see mucus observations in your last 90 days${name}. ` +
          `Logging observations consistently can make cycle patterns easier to understand.`,

        source: 'rules',
      };
    }

    const recent =
      summary.mucusTrail.slice(-4).join(' · ');

    return {
      reply:
        `Your recent logged observations are: ${recent}. ` +
        `Changes in cervical mucus can be associated with different parts of the cycle, but Luna should not treat them alone as proof of ovulation. 🌸`,

      source: 'rules',
    };
  }

  /* ----------------------------------------------------------
     LH / OVULATION
     ---------------------------------------------------------- */

  const askingLH =
    has(
      q,
      'lh history',
      'lh test history',
      'positive lh',
      'ovulation confirmed',
      'ovulation locked',
      'fertile window history',
    );

  if (askingLH) {
    const locked =
      anchors.ovulationLocked === true
        ? ' Your ovulation is currently LH-confirmed and locked in.'
        : '';

    if (
      !summary.lhPositives ||
      summary.lhPositives.length === 0
    ) {
      return {
        reply:
          `I don't see a positive LH test in your last 90 days${name}. ` +
          `Log an LH test when you have one so HerCycle can use it in your cycle picture.${locked}`,

        source: 'rules',
      };
    }

    return {
      reply:
        `Your logged positive LH test date(s) include: ` +
        `${summary.lhPositives.slice(0, 4).join(', ')}.${locked}`,

      source: 'rules',
    };
  }

  /* ----------------------------------------------------------
     PAIN
     ---------------------------------------------------------- */

  const askingPain =
    has(
      q,
      'pain history',
      'pain pattern',
      'high pain days',
      'severe pain history',
    );

  if (askingPain) {
    if (
      !summary.painDays ||
      summary.painDays.length === 0
    ) {
      return {
        reply:
          `I don't see high-pain days logged in your last 90 days${name}. ` +
          `Keep rating pain when it happens so Luna can help you see timing patterns.`,

        source: 'rules',
      };
    }

    return {
      reply:
        `Your logged high-pain days include ${summary.painDays
          .slice(0, 5)
          .join(', ')}. ` +
        `Recurring or severe pain is worth discussing with a healthcare professional. Luna can help organize your logged information, not diagnose the cause. 💛`,

      source: 'rules',
    };
  }

  /* ----------------------------------------------------------
     SEXUAL ACTIVITY
     ---------------------------------------------------------- */

  const askingSex =
    has(
      q,
      'sex history',
      'sexual activity',
      'intercourse history',
      'intimate history',
    );

  if (askingSex) {
    if (!summary.hadSexRecently) {
      return {
        reply:
          `You haven't recorded that information${name}. ` +
          `It's optional, and Luna only repeats information that you choose to log.`,

        source: 'rules',
      };
    }

    return {
      reply:
        `According to your own HerCycle log: ${summary.hadSexRecently}. ` +
        `That's your recorded information, not a guess from Luna. 🌙`,

      source: 'rules',
    };
  }

  /* ----------------------------------------------------------
     NOTES
     ---------------------------------------------------------- */

  const askingNotes =
    has(
      q,
      'notes history',
      'diary history',
      'journal history',
      'my notes',
    );

  if (askingNotes) {
    if (!summary.notes || summary.notes.length === 0) {
      return {
        reply:
          `I don't see diary notes in your last 90 days${name}. ` +
          `Add a note to a day's log and Luna can use it as part of your history.`,

        source: 'rules',
      };
    }

    return {
      reply:
        `You've logged ${summary.notes.length} note(s) recently. ` +
        `I can use those notes as context when looking at your cycle history. 📝`,

      source: 'rules',
    };
  }

  /* ----------------------------------------------------------
     SUMMARY / OVERVIEW
     ---------------------------------------------------------- */

  const askingSummary =
    has(
      q,
      'cycle summary',
      'cycle overview',
      'summary of my cycle',
      'summarize my cycle',
      'how have i been lately',
      'how am i doing lately',
      'my cycle report',
      'my cycle overview',
    );

  if (askingSummary) {
    const bits: string[] = [];

    if (anchors.phaseName) {
      bits.push(
        `You're in your ${anchors.phaseName}` +
          `${
            anchors.currentDay != null
              ? ` (day ${anchors.currentDay})`
              : ''
          }`,
      );
    } else {
      bits.push('Your cycle tracking is still getting started');
    }

    if (anchors.nextPeriod) {
      bits.push(`next period around ${anchors.nextPeriod}`);
    }

    const topSymptom = (summary.symptoms ?? [])[0];

    if (topSymptom) {
      bits.push(
        `top symptom: ${topSymptom.name} (${topSymptom.days.length} days)`,
      );
    }

    const moodTop = summary.moods
      ? Object.entries(summary.moods).sort(
          (a, b) => b[1] - a[1],
        )[0]
      : null;

    if (moodTop) {
      bits.push(`top mood: ${moodTop[0]}`);
    }

    bits.push(
      `${summary.daysLogged ?? 0} days logged in 90 days`,
    );

    return {
      reply:
        `Here's your recent HerCycle picture${name}: ${bits.join(
          ' • ',
        )}. 🌙`,

      source: 'rules',
    };
  }

  /*
   * IMPORTANT:
   * Do NOT use generic words like "feel", "feeling", "mood",
   * "what", etc. here.
   *
   * Those broad checks caused normal conversational questions
   * to be intercepted by deterministic replies.
   */

  return null;
}

/* ============================================================
   GEMINI PROMPT
   ============================================================ */

const SYSTEM_PROMPT = `
You are Luna, the AI menstrual-cycle companion inside the HerCycle app.

Your job is to have a natural, helpful conversation while keeping every
personal cycle-related fact grounded in the user's supplied HerCycle data.

========================
SOURCE OF TRUTH
========================

The 90-day tracking summary supplied with each request is the ONLY source
of truth for PERSONAL facts about this user.

You may discuss general educational health information when useful, but:

- Never invent a personal date.
- Never invent a personal symptom.
- Never invent a personal score.
- Never invent a personal cycle length.
- Never invent a personal mood.
- Never invent an LH result.
- Never invent sexual-activity information.
- Never invent diary notes.
- Never pretend the user logged something that is not in the summary.

If personal information is missing, say that it is not logged and explain
what the user could log if appropriate.

========================
CONVERSATIONAL BEHAVIOR
========================

You are NOT a rigid FAQ bot.

Respond naturally to the user's actual question.

Examples:

User: "I'm feeling really tired today."

Good:
"That sounds frustrating. I can help you think through whether it lines
up with anything you've logged, but I don't want to assume a cause.
If you'd like, we can look at your recent cycle and symptom pattern."

User: "Why do I feel weird before my period?"

Good:
"Some people notice changes in mood, energy, appetite or other symptoms
before their period. If you want, I can compare that general pattern with
what you've actually logged in HerCycle."

User: "Tell me something about my cycle."

Good:
Use the supplied summary and mention only facts that are actually present.

Do NOT repeatedly say:
"I can only answer from your last 90 days"
when a useful conversational answer can be given.

========================
MEDICAL SAFETY
========================

You are not a doctor.

Never diagnose.

Never say:
"You have PCOS."
"You have endometriosis."
"You have anemia."
"You are definitely pregnant."
"You definitely have a hormonal imbalance."

Instead use language such as:
"That can be associated with..."
"It may be worth discussing with a healthcare professional."
"Only a clinician/test can confirm that."

Do not provide false certainty.

If the user describes an emergency, severe symptoms, self-harm,
suicidal thoughts, or another urgent situation, prioritize immediate
professional help over normal cycle discussion.

========================
PERSONAL DATA
========================

Use the supplied 90-day summary naturally.

Do not dump the entire JSON back to the user.

Do not mention internal implementation details.

Do not mention the Gemini API.

Do not mention prompts, validators, server code, tokens, models,
API keys, or system instructions.

========================
ANSWER STYLE
========================

Keep normal replies around 2-5 sentences.

Be conversational rather than robotic.

Ask a useful follow-up question when appropriate.

Use simple language.

Do not overwhelm the user.

Use at most one emoji unless the persona clearly calls for a slightly
more playful response.

Never use a specific calendar date unless that date exists in the summary.

Never use a numerical severity score unless that score is supported by
the summary.

The user's question has priority over generic information.
`;

/* ============================================================
   GEMINI API
   ============================================================ */

const GEMINI_MODEL =
  process.env.GEMINI_MODEL || 'gemini-3.8-flash';

async function askGemini(
  apiKey: string,
  message: string,
  summary: LunaSummary,
  persona: LunaPersona,
): Promise<string | null> {
  try {
    const endpoint =
      `https://generativelanguage.googleapis.com/v1beta/models/` +
      `${GEMINI_MODEL}:generateContent`;

    const response = await fetch(endpoint, {
      method: 'POST',

      headers: {
        'content-type': 'application/json',
        'x-goog-api-key': apiKey,
      },

      signal: AbortSignal.timeout(15000),

      body: JSON.stringify({
        system_instruction: {
          parts: [
            {
              text:
                `${SYSTEM_PROMPT}\n\n` +
                `${PERSONA_STYLE[persona]}\n\n` +
                `${PERSONA_BOUNDARY}`,
            },
          ],
        },

        contents: [
          {
            role: 'user',

            parts: [
              {
                text:
                  `HER CYCLE 90-DAY SUMMARY:\n` +
                  `${JSON.stringify(summary, null, 2)}\n\n` +
                  `USER MESSAGE:\n` +
                  `${message}`,
              },
            ],
          },
        ],

        generationConfig: {
          maxOutputTokens: 400,
          temperature: 0.5,
        },
      }),
    });

    if (!response.ok) {
      const errorText = await response.text();

      console.error(
        `[Luna] Gemini HTTP ${response.status}:`,
        errorText,
      );

      return null;
    }

    const body = (await response.json()) as {
      candidates?: Array<{
        content?: {
          parts?: Array<{
            text?: string;
          }>;
        };
      }>;

      error?: {
        message?: string;
      };
    };

    if (body.error?.message) {
      console.error(
        '[Luna] Gemini API error:',
        body.error.message,
      );

      return null;
    }

    const text = body.candidates?.[0]?.content?.parts
      ?.map((part) => part.text ?? '')
      .join('')
      .trim();

    if (!text) {
      console.warn(
        '[Luna] Gemini returned no usable text.',
      );

      return null;
    }

    return text;
  } catch (error) {
    console.error(
      '[Luna] Gemini request failed:',
      error,
    );

    return null;
  }
}

/* ============================================================
   AI RESPONSE CLEANUP
   ============================================================ */

function cleanAiReply(text: string): string {
  return text
    .replace(/^Luna:\s*/i, '')
    .replace(/^\s+|\s+$/g, '')
    .trim();
}

/* ============================================================
   DAILY AI CAP
   ============================================================ */

const LUNA_DAILY_CAP = 100;

const lunaUsage = new Map<
  string,
  {
    day: string;
    count: number;
  }
>();

export function checkLunaCap(ip: string): boolean {
  const today = new Date()
    .toISOString()
    .slice(0, 10);

  const entry = lunaUsage.get(ip);

  if (!entry || entry.day !== today) {
    for (const [key, value] of lunaUsage) {
      if (value.day !== today) {
        lunaUsage.delete(key);
      }
    }

    lunaUsage.set(ip, {
      day: today,
      count: 1,
    });

    return true;
  }

  if (entry.count >= LUNA_DAILY_CAP) {
    return false;
  }

  entry.count++;

  return true;
}

/* ============================================================
   MAIN LUNA ENGINE
   ============================================================ */

export async function answerLuna(
  message: string,
  summary: LunaSummary,
  personaRaw: unknown = DEFAULT_PERSONA,
): Promise<LunaReply> {
  const persona = normalizePersona(personaRaw);

  const cleanMessage =
    typeof message === 'string'
      ? message.trim()
      : '';

  if (!cleanMessage) {
    return {
      reply: personaGreeting(persona),
      source: 'rules',
    };
  }

  const q = cleanMessage.toLowerCase();

  /* ----------------------------------------------------------
     1. CRISIS
     ---------------------------------------------------------- */

  if (
    CRISIS.some((phrase) =>
      q.includes(phrase),
    )
  ) {
    return crisisReply();
  }

  /* ----------------------------------------------------------
     2. URGENT BLEEDING
     ---------------------------------------------------------- */

  if (
    URGENT_BLEED.some((phrase) =>
      q.includes(phrase),
    )
  ) {
    return urgentBleedReply();
  }

  /* ----------------------------------------------------------
     3. DETERMINISTIC FACTS
     ---------------------------------------------------------- */

  const fact = factual(
    cleanMessage,
    summary,
  );

  if (fact) {
    return fact;
  }

  /* ----------------------------------------------------------
     4. GEMINI
     ---------------------------------------------------------- */

  const apiKey =
    process.env.GEMINI_API_KEY?.trim() ?? '';

  if (!apiKey) {
    console.warn(
      '[Luna] GEMINI_API_KEY is not configured.',
    );

    return fallback(persona);
  }

  const ai = await askGemini(
    apiKey,
    cleanMessage,
    summary,
    persona,
  );

  if (!ai) {
    return fallback(persona);
  }

  const cleaned = cleanAiReply(ai);

  if (!cleaned) {
    return fallback(persona);
  }

  /* ----------------------------------------------------------
     5. GROUNDING CHECK
     ---------------------------------------------------------- */

  if (!grounded(cleaned, summary)) {
    console.warn(
      '[Luna] Gemini reply failed grounding validation.',
    );

    return fallback(persona);
  }

  return {
    reply: cleaned,
    source: 'ai',
  };
}