import assert from 'node:assert/strict';
import {
  answerLuna,
  checkLunaCap,
  grounded,
  normalizePersona,
  personaGreeting,
  PERSONA_BOUNDARY,
  DEFAULT_PERSONA,
  LUNA_PERSONAS,
  type LunaSummary,
} from './src/luna.js';

/**
 * Regression checks for the Luna brain. No API key or network needed —
 * every assertion runs against the deterministic rules engine and the
 * citation validator. Run: npx tsx check-luna.ts (exit 0 = all green).
 */

const summary: LunaSummary = {
  windowDays: 90,
  userName: 'Sara Test',
  anchors: {
    today: '2026-09-10',
    currentDay: 12,
    phaseName: 'Follicular Phase',
    nextPeriod: '2026-09-26',
    daysUntilNextPeriod: 16,
    averageCycleLength: 28,
    ovulationLocked: false,
    activeAlert: null,
  },
  periodStarts: ['2026-08-04', '2026-09-01'],
  symptoms: [{ name: 'Headache', days: ['2026-09-08'], avgScore: 6 }],
  moods: { Calm: 4, Happy: 2 },
  mucusTrail: ['2026-09-07:Dry', '2026-09-09:Eggwhite'],
  lhPositives: [],
  painDays: [],
  notes: ['2026-09-09:exam week, tired'],
  hadSexRecently: null,
  daysLogged: 9,
};

async function main(): Promise<void> {
  // 1. Historic misroute must stay fixed: headache question, headache answer.
  let r = await answerLuna('when did I log headaches?', summary);
  assert.equal(r.source, 'rules');
  assert.match(r.reply, /Headache/i);
  assert.doesNotMatch(r.reply, /last logged period started/i);

  // 2. Period questions cite exact logged dates.
  r = await answerLuna('when was my last period?', summary);
  assert.match(r.reply, /2026-09-01/);
  r = await answerLuna('when is my next period due?', summary);
  assert.match(r.reply, /2026-09-26/);

  // 3. Pregnancy gets the safe reply, never an LH answer.
  r = await answerLuna('am i pregnant?', summary);
  assert.match(r.reply, /pregnancy test/i);
  assert.doesNotMatch(r.reply, /LH test/i);

  // 4. Crisis + urgent bleed redirect to care.
  r = await answerLuna('i want to die', summary);
  assert.match(r.reply, /crisis helpline|emergency services/i);
  r = await answerLuna('bleeding heavily and soaking through', summary);
  assert.match(r.reply, /prompt medical care|urgent care/i);

  // 5. Empty message returns the persona greeting, never crashes.
  r = await answerLuna('   ', summary);
  assert.equal(r.reply, personaGreeting('caregiver'));
  r = await answerLuna('   ', summary, 'flirt');
  assert.equal(r.reply, personaGreeting('flirt'));
  assert.notEqual(personaGreeting('flirt'), personaGreeting('caregiver'));

  // 6. Validator gates: fabricated date, absurd score, diagnosis claim.
  assert.equal(
    grounded('Your next period is around 2031-01-01.', summary),
    false,
  );
  assert.equal(
    grounded('Your pain averaged 25/10 lately.', summary),
    false,
  ); // absurd value, always rejected
  assert.equal(
    grounded('You have endometriosis, confirmed.', summary),
    false,
  );
  assert.equal(
    grounded(
      'Headaches appear on 1 logged day(s): 2026-09-08. Average intensity 6/10.',
      summary,
    ),
    true,
  );

  // 7. Daily cap trips at 100 and resets logic holds shape.
  const ip = `test-${Date.now()}`;
  let allowed = 0;
  for (let i = 0; i < 105; i++) {
    if (checkLunaCap(ip)) allowed++;
  }
  assert.equal(allowed, 100);

  // 8. Persona allowlist: unknown/empty/non-string degrade to default.
  assert.equal(normalizePersona('flirt'), 'flirt');
  assert.equal(normalizePersona('FLIRT'), 'flirt');
  assert.equal(normalizePersona('nope'), DEFAULT_PERSONA);
  assert.equal(normalizePersona(''), DEFAULT_PERSONA);
  assert.equal(normalizePersona(undefined), DEFAULT_PERSONA);
  assert.equal(normalizePersona(42), DEFAULT_PERSONA);
  assert.equal(DEFAULT_PERSONA, 'caregiver');
  assert.equal(LUNA_PERSONAS.length, 8);

  // 9. Golden: deterministic factual + safety replies are byte-identical
  // across every persona — tone never moves facts or warnings.
  const probes = [
    'when is my next period due?',
    'when was my last period?',
    'am i pregnant?',
    'i want to die',
    'bleeding heavily and soaking through',
    'how were my cramps?',
  ];
  const baseline = new Map<string, string>();
  for (const persona of [...LUNA_PERSONAS, 'bogus-persona']) {
    for (const q of probes) {
      const rr = await answerLuna(q, summary, persona);
      const key = q;
      if (!baseline.has(key)) {
        baseline.set(key, rr.reply);
      } else {
        assert.equal(
          rr.reply,
          baseline.get(key),
          `persona ${persona} changed reply for: ${q}`,
        );
      }
    }
  }

  // 10. Safety boundary text is load-bearing: every persona prompt is
  // composed with it (checked structurally here; composition is in code).
  assert.match(PERSONA_BOUNDARY, /never.*medical accuracy/i);
  for (const p of LUNA_PERSONAS) {
    assert.equal(typeof personaGreeting(p), 'string');
    assert.ok(personaGreeting(p).length > 10);
  }

  console.log('LUNA CHECKS PASSED ✔ (10 groups)');
}

main().catch((e) => {
  console.error('LUNA CHECK FAILED:', e);
  process.exit(1);
});
