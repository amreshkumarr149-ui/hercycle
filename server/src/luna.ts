/**
 * Log-grounded Luna brain.
 *
 * Order of answering (strong logic, no fabrication):
 *  1. Crisis patterns        -> supportive + professional-care redirect.
 *  2. Factual intents        -> answered deterministically from the summary.
 *  3. Interpretive intents   -> Gemini (if configured) with the summary
 *                               injected, then validated.
 *  4. Anything else / no key -> honest rule-based fallback.
 *
 * The validator rejects any AI reply that cites a specific date or score
 * absent from the payload, replacing it with the fallback.
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
  symptoms?: { name: string; days: string[]; avgScore: number | null }[] | null;
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
// Heavy-bleeding emergency phrasing -> urgent-care redirect, not tracking chat.
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
  words.some((w) => q.includes(w));

function payloadText(s: LunaSummary): string {
  return JSON.stringify(s ?? {});
}

function datesIn(text: string): string[] {
  return text.match(/\b\d{4}-\d{2}-\d{2}\b/g) ?? [];
}

/** Every specific date/score in the reply must exist in the payload. */
function grounded(reply: string, summary: LunaSummary): boolean {
  const payload = payloadText(summary);
  // Gate 1: every specific date cited must exist in the payload.
  for (const d of datesIn(reply)) {
    if (!payload.includes(d)) return false;
  }
  // Gate 2: severity scores ("6/10") are only legal when the user actually
  // logged symptoms/pain, and absurd values (>10) are always rejected.
  // (Single-digit substring matching against dates would be unsound, so the
  // gate is structural instead of textual.)
  const scoreClaims = [...reply.matchAll(/(\d+(?:\.\d+)?)\s*\/\s*10/g)];
  if (scoreClaims.length > 0) {
    if (scoreClaims.some((m) => Number(m[1]) > 10 || Number(m[1]) < 0)) {
      return false;
    }
    const hasScores = (summary.symptoms?.length ?? 0) > 0 ||
      (summary.painDays?.length ?? 0) > 0;
    if (!hasScores) return false;
  }
  // Gate 3: no diagnostic claims, ever.
  const lowered = reply.toLowerCase();
  for (const claim of DIAGNOSIS_CLAIMS) {
    if (lowered.includes(claim)) return false;
  }
  return true;
}

function fallback(): LunaReply {
  return {
    reply:
      "I can only answer from what's actually logged in your last 90 days — and I don't see that yet. Log a little more (periods, symptoms, moods) and ask me again! For anything medical, please check with a healthcare professional. 🌙",
    source: 'rules',
  };
}

function crisisReply(): LunaReply {
  return {
    reply:
      "I'm really glad you told me. I'm just a cycle-tracking assistant and can't help with this safely — please reach out right now to someone you trust, or contact a local crisis helpline or emergency services. You deserve support from real people. 💛",
    source: 'rules',
  };
}

/** Deterministic factual intents. Returns null when no intent matches. */
function factual(message: string, s: LunaSummary): LunaReply | null {
  const q = message.toLowerCase().trim();
  const a = s.anchors ?? {};
  const name = s.userName ? `, ${s.userName.split(' ')[0]}` : '';

  // Next-period is checked first: it carries the distinctive words
  // (next/upcoming/due). Last-period must mention periods explicitly, so
  // "when did I log headaches" can no longer misroute here.
  if (
    has(q, 'next', 'upcoming', 'due') &&
    has(q, 'period', 'bleed', 'menstruat')
  ) {
    if (!a.nextPeriod) {
      return {
        reply: `I don't have enough logged yet to estimate your next period${name}. Log your last period date and I'll calculate it!`,
        source: 'rules',
      };
    }
    return {
      reply: `Your estimated next period is around ${a.nextPeriod}${a.daysUntilNextPeriod != null ? ` — about ${a.daysUntilNextPeriod} days away` : ''}. It's an estimate from your logged history, not a promise. 🌙`,
      source: 'rules',
    };
  }

  if (
    has(q, 'last period', 'period start', 'period began', 'first day') ||
    (has(q, 'when', 'which date', 'what date') &&
      has(q, 'period', 'bleed'))
  ) {
    if (!s.periodStarts || s.periodStarts.length === 0) {
      return {
        reply: `You have no period start logged in the last 90 days${name} — log one on the calendar and I'll track from there!`,
        source: 'rules',
      };
    }
    const last = s.periodStarts[s.periodStarts.length - 1];
    // Answer both readings at once ("when did it start" and "when is it"):
    // last start always, next estimate when available.
    const next = a.nextPeriod
      ? ` Estimated next: ${a.nextPeriod}.`
      : '';
    return {
      reply: `Your last logged period started on ${last}${s.periodStarts.length > 1 ? ` (you've logged ${s.periodStarts.length} starts in the last 90 days)` : ''}.${next} 🌸`,
      source: 'rules',
    };
  }

  // Pregnancy questions get a safe dedicated reply — never an LH answer.
  if (has(q, 'pregnant', 'pregnancy')) {
    const ctx =
      s.periodStarts && s.periodStarts.length > 0
        ? ` Your last logged period started ${s.periodStarts[s.periodStarts.length - 1]}.`
        : '';
    return {
      reply: `Only a pregnancy test can answer that reliably${name} — if your period is late, take one and talk to a healthcare professional.${ctx} I can help you track dates and symptoms either way. 💛`,
      source: 'rules',
    };
  }

  if (has(q, 'phase', 'where am i', 'cycle day', 'what day')) {
    const day = a.currentDay != null ? `Day ${a.currentDay}` : 'an unknown day';
    const phase = a.phaseName ?? 'an unconfirmed phase';
    return {
      reply: `You're on ${day} — ${phase}${name}. ${a.activeAlert ?? 'Keep logging and I’ll keep the picture sharp!'}`,
      source: 'rules',
    };
  }

  if (has(q, 'cramp')) {
    const c = (s.symptoms ?? []).find((x) => x.name.toLowerCase().includes('cramp'));
    if (!c) {
      return {
        reply: `No cramps logged in the last 90 days${name} — enjoy the calm! Tap Cramps on a day it happens and rate it 0–10 so I can track intensity.`,
        source: 'rules',
      };
    }
    const sev = c.avgScore != null ? ` averaging ${c.avgScore}/10` : '';
    return {
      reply: `You logged cramps on ${c.days.length} day(s)${sev}: ${c.days.slice(0, 5).join(', ')}. Heat, gentle movement and rest commonly help — and anything severe is worth mentioning to a professional. 💛`,
      source: 'rules',
    };
  }

  if (has(q, 'headache', 'migraine')) {
    const h = (s.symptoms ?? []).find((x) =>
      ['headache', 'migraine'].some((k) => x.name.toLowerCase().includes(k)),
    );
    if (!h) {
      return {
        reply: `No headaches in your last 90 days of logs${name}. Nice! I'll flag the pattern the moment one appears.`,
        source: 'rules',
      };
    }
    return {
      reply: `Headaches appear on ${h.days.length} logged day(s): ${h.days.slice(0, 5).join(', ')}. ${
        h.avgScore != null ? `Average intensity ${h.avgScore}/10. ` : ''
      }Notice if they cluster before bleeding — that's a classic pattern worth tracking.`,
      source: 'rules',
    };
  }

  if (has(q, 'mood', 'moody', 'feeling', 'feel', 'emotion')) {
    if (!s.moods || Object.keys(s.moods).length === 0) {
      return {
        reply: `No moods logged in the last 90 days${name}. Log one daily and I'll show you your emotional rhythm across phases! 😊`,
        source: 'rules',
      };
    }
    const top = Object.entries(s.moods).sort((a, b) => b[1] - a[1]);
    return {
      reply: `Your most logged mood lately is ${top[0][0]} (${top[0][1]} days)${top[1] ? `, followed by ${top[1][0]} (${top[1][1]})` : ''}. Mood shifts across phases are completely normal. 💛`,
      source: 'rules',
    };
  }

  if (has(q, 'mucus', 'discharge', 'cervical')) {
    if (!s.mucusTrail || s.mucusTrail.length === 0) {
      return {
        reply: `No mucus observations in the last 90 days${name}. Logging Dry → Creamy → Eggwhite helps pinpoint your fertile window!`,
        source: 'rules',
      };
    }
    const recent = s.mucusTrail.slice(-4).join(' · ');
    return {
      reply: `Your recent observations: ${recent}. A shift toward creamy/watery/eggwhite usually means the fertile window is opening — that's exactly what triggers my LH-test reminders! 🌸`,
      source: 'rules',
    };
  }

  if (has(q, 'lh', 'ovulation', 'ovulat', 'fertile', 'conceive', 'pregnant')) {
    const locked = a.ovulationLocked
      ? ' Your ovulation is currently LH-confirmed and locked in. ✨'
      : '';
    if (!s.lhPositives || s.lhPositives.length === 0) {
      return {
        reply: `No positive LH tests in the last 90 days${name}. Log one when the strip turns positive and I'll lock your ovulation + next period dates.${locked}`,
        source: 'rules',
      };
    }
    return {
      reply: `Positive LH test(s) on: ${s.lhPositives.slice(0, 4).join(', ')}.${locked}`,
      source: 'rules',
    };
  }

  if (has(q, 'pain', 'hurt', 'ache', 'sore') && !has(q, 'headache', 'cramp')) {
    if (!s.painDays || s.painDays.length === 0) {
      return {
        reply: `No high-pain days (7+/10) in the last 90 days${name}. Keep rating pain when it happens so I can spot timing patterns.`,
        source: 'rules',
      };
    }
    return {
      reply: `High-pain days logged: ${s.painDays.slice(0, 5).join(', ')}. Recurring severe pain is worth discussing with a healthcare professional — I can show dates, never diagnoses. 💛`,
      source: 'rules',
    };
  }

  if (has(q, 'sex', 'intimate', 'intercourse')) {
    if (!s.hadSexRecently) {
      return {
        reply: `You haven't recorded that either way${name} — it's optional in your profile and I only ever repeat back what you logged.`,
        source: 'rules',
      };
    }
    return {
      reply: `Per your own log: ${s.hadSexRecently}. That's your data talking, not me guessing. 🌙`,
      source: 'rules',
    };
  }

  if (has(q, 'note', 'diary', 'journal', 'wrote')) {
    if (!s.notes || s.notes.length === 0) {
      return {
        reply: `No diary notes in the last 90 days${name}. Jot anything on a day's log and I'll remember the highlights here!`,
        source: 'rules',
      };
    }
    return {
      reply: `You've written ${s.notes.length} note(s) lately, most recently ${s.notes[s.notes.length - 1].split(':')[0]}. Lovely journaling habit! 📝`,
      source: 'rules',
    };
  }

  if (
    has(q, 'summar', 'lately', 'how am i', "how'm i", 'overview', 'report', 'how have i')
  ) {
    const bits: string[] = [];
    bits.push(
      a.phaseName
        ? `You're in your ${a.phaseName}${a.currentDay != null ? ` (day ${a.currentDay})` : ''}`
        : `Tracking is just getting started`,
    );
    if (a.nextPeriod) bits.push(`next period around ${a.nextPeriod}`);
    const top = (s.symptoms ?? [])[0];
    if (top) bits.push(`top symptom: ${top.name} (${top.days.length} days)`);
    const moodTop = s.moods
      ? Object.entries(s.moods).sort((x, y) => y[1] - x[1])[0]
      : null;
    if (moodTop) bits.push(`top mood: ${moodTop[0]}`);
    bits.push(`${s.daysLogged ?? 0} days logged in 90 days`);
    return {
      reply: `Here's you lately${name}: ${bits.join(' • ')}. 🌙`,
      source: 'rules',
    };
  }

  return null;
}

const SYSTEM_PROMPT = `You are Luna, a warm menstrual-cycle companion inside the HerCycle app. Rules you must obey:
- Answer ONLY from the provided 90-day tracking summary. Every specific claim (dates, scores, counts) must come from it.
- Write calendar dates in yyyy-MM-dd format. Quote severity scores ONLY as written in the summary.
- If the data needed is missing, say exactly what to log instead of guessing.
- Never diagnose any condition, never say "you have X". Use "may be associated with" / "worth discussing with a healthcare professional".
- Short chat replies (2-4 sentences), warm tone, one emoji max.
- If the user describes an emergency or self-harm, respond supportively and urge immediate professional help.`;

async function askGemini(
  apiKey: string,
  message: string,
  summary: LunaSummary,
): Promise<string | null> {
  try {
    const res = await fetch(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent',
      {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-goog-api-key': apiKey,
        },
        // Never hang the chat pipeline past the client's own timeout.
        signal: AbortSignal.timeout(15000),
        body: JSON.stringify({
          system_instruction: { parts: [{ text: SYSTEM_PROMPT }] },
          contents: [
            {
              role: 'user',
              parts: [
                {
                  text: `90-day tracking summary (JSON, the ONLY source of truth):\n${JSON.stringify(summary)}\n\nUser question: ${message}`,
                },
              ],
            },
          ],
          generationConfig: { maxOutputTokens: 300, temperature: 0.4 },
        }),
      },
    );
    if (!res.ok) return null;
    const body = (await res.json()) as {
      candidates?: { content?: { parts?: { text?: string }[] } }[];
    };
    const text = body.candidates?.[0]?.content?.parts
      ?.map((p) => p.text ?? '')
      .join('')
      .trim();
    return text && text.length > 0 ? text : null;
  } catch {
    return null;
  }
}

function urgentBleedReply(): LunaReply {
  return {
    reply:
      'Soaking through protection or bleeding that will not stop needs prompt medical care — please contact your doctor, urgent care, or emergency services now. Your logged flow and pain history will help them help you. 💛',
    source: 'rules',
  };
}

// Per-IP daily budget for AI-era abuse control (factual intents bypass it;
// they cost nothing). Pruned on every check so memory stays bounded.
const LUNA_DAILY_CAP = 100;
const lunaUsage = new Map<string, { day: string; count: number }>();

export function checkLunaCap(ip: string): boolean {
  const today = new Date().toISOString().slice(0, 10);
  const entry = lunaUsage.get(ip);
  if (!entry || entry.day !== today) {
    // Prune stale entries while we're here.
    for (const [k, v] of lunaUsage) {
      if (v.day !== today) lunaUsage.delete(k);
    }
    lunaUsage.set(ip, { day: today, count: 1 });
    return true;
  }
  if (entry.count >= LUNA_DAILY_CAP) return false;
  entry.count++;
  return true;
}

export async function answerLuna(
  message: string,
  summary: LunaSummary,
): Promise<LunaReply> {
  const q = (message ?? '').toLowerCase();
  if (!q.trim()) {
    return { reply: 'Ask me anything about your logged cycles! 🌙', source: 'rules' };
  }
  if (CRISIS.some((c) => q.includes(c))) return crisisReply();
  if (URGENT_BLEED.some((c) => q.includes(c))) return urgentBleedReply();

  const fact = factual(message, summary);
  if (fact) return fact;

  const key = process.env.GEMINI_API_KEY ?? '';
  if (key) {
    const ai = await askGemini(key, message.trim(), summary);
    if (ai && grounded(ai, summary)) {
      return { reply: ai, source: 'ai' };
    }
  }
  return fallback();
}
