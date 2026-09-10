/**
 * Premium Deep Insight analysis — TypeScript mirror of the HerCycle
 * clinical engine core, focused on the 6-month deep pass served behind x402.
 *
 * Deterministic, tracked-data-only: every number derives from the posted
 * logs. Missing data yields "Insufficient Data", never fabricated values.
 */

export interface DailyLogInput {
  date: string; // yyyy-MM-dd
  period?: boolean;
  symptoms?: string[];
  mood?: string;
  mucus?: string;
  lhTest?: string;
  flowIntensity?: string; // None | Light | Medium | Heavy
  painScore?: number;
  symptomIntensity?: Record<string, number>;
  notes?: string;
}

export interface ProfileInput {
  name?: string;
  typicalCycleLength?: number;
  typicalPeriodLength?: number;
}

export interface CycleRecord {
  number: number;
  start: string;
  end: string | null;
  length: number | null;
  bleedingDays: number;
  ovulationConfirmed: boolean;
  ovulationDay: number | null; // 1-indexed day within cycle
}

export interface PremiumReport {
  windowLabel: string;
  generatedAt: string;
  cyclesAnalyzed: number;
  cycles: CycleRecord[];
  baselines: { name: string; value: string; reference: string; tag: string }[];
  patterns: {
    name: string;
    trigger: string;
    observations: string;
    cycleCount: number;
    dates: string[];
  }[];
  trends: { name: string; indicator: string; detail: string }[];
  symptomSummary: {
    name: string;
    occurrences: number;
    avgSeverity: string;
    cyclesAffected: number;
    recent: string;
  }[];
  recommendations: string[];
  reliability: string;
  summary: string[];
}

const day = (d: Date) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(
    d.getDate(),
  ).padStart(2, '0')}`;

function parseDay(s: string): Date | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s ?? '');
  if (!m) return null;
  const d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  return isNaN(d.getTime()) ? null : d;
}

const isBleeding = (l: DailyLogInput) =>
  l.period === true || (l.flowIntensity ?? 'None') !== 'None';

export function analyzePremium(
  logs: DailyLogInput[],
  profile: ProfileInput,
  windowDays = 180,
  now: Date = new Date(),
): PremiumReport {
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const typicalCycle = Math.min(
    60,
    Math.max(15, Math.round(profile.typicalCycleLength ?? 28)),
  );

  // Sanitize: drop malformed + future-dated logs, sort chronologically.
  const entries = logs
    .map((log) => ({ date: parseDay(log.date), log }))
    .filter(
      (e): e is { date: Date; log: DailyLogInput } =>
        e.date !== null && e.date <= today,
    )
    .sort((a, b) => a.date.getTime() - b.date.getTime());

  const cutoff = new Date(today);
  cutoff.setDate(cutoff.getDate() - (windowDays - 1));

  // Period starts from FULL history (keeps intervals correct), then keep
  // cycles overlapping the window.
  const bleedDays = new Set(
    entries.filter((e) => isBleeding(e.log)).map((e) => day(e.date)),
  );
  const starts: Date[] = [];
  for (const key of bleedDays) {
    const d = parseDay(key)!;
    const prev = new Date(d);
    prev.setDate(prev.getDate() - 1);
    if (!bleedDays.has(day(prev))) starts.push(d);
  }
  starts.sort((a, b) => a.getTime() - b.getTime());

  const cycles: CycleRecord[] = [];
  starts.forEach((start, i) => {
    const end = i + 1 < starts.length ? starts[i + 1] : null;
    if (end && end < cutoff) return;
    if (!end && start < cutoff) return;
    const stop = end ?? new Date(today.getTime() + 86400000);
    let bleed = 0;
    const cursor = new Date(start);
    while (cursor < stop) {
      if (bleedDays.has(day(cursor))) bleed++;
      cursor.setDate(cursor.getDate() + 1);
    }
    const length = end
      ? Math.round((end.getTime() - start.getTime()) / 86400000)
      : null;
    // Confirmed ovulation: first positive LH in-window + 1 day.
    let confirmed: Date | null = null;
    for (const e of entries) {
      if (
        e.date >= start &&
        (end === null || e.date < end) &&
        (e.log.lhTest ?? '').toLowerCase() === 'positive'
      ) {
        confirmed = new Date(e.date);
        confirmed.setDate(confirmed.getDate() + 1);
        break;
      }
    }
    const anchorLen = length ?? typicalCycle;
    const estDay = Math.min(89, Math.max(0, anchorLen - 15));
    void estDay;
    cycles.push({
      number: cycles.length + 1,
      start: day(start),
      end: end ? day(end) : null,
      length,
      bleedingDays: bleed,
      ovulationConfirmed: confirmed !== null,
      ovulationDay: confirmed
        ? Math.round(
            (confirmed.getTime() - start.getTime()) / 86400000,
          ) + 1
        : null,
    });
  });

  const complete = cycles.filter(
    (c): c is CycleRecord & { length: number; end: string } =>
      c.length !== null && c.end !== null,
  );

  // ---- Baselines ----
  const baselines: PremiumReport['baselines'] = [];
  const insufficient = (n: string) =>
    baselines.push({
      name: n,
      value: 'Insufficient Data',
      reference: 'Needs 2+ complete cycles',
      tag: 'Insufficient Data',
    });
  if (complete.length >= 2) {
    const lens = complete.map((c) => c.length as number);
    const avg = lens.reduce((a, b) => a + b, 0) / lens.length;
    const variation = Math.max(...lens) - Math.min(...lens);
    baselines.push({
      name: 'Average Cycle Length',
      value: `${avg.toFixed(1)} days`,
      reference: 'Typical reference: 21–35 days',
      tag: avg > 35 ? 'Elevated' : avg < 21 ? 'Lower than typical' : 'Normal',
    });
    baselines.push({
      name: 'Cycle-to-cycle variation',
      value: `${variation} days`,
      reference: 'Up to ~7 days is commonly seen',
      tag:
        variation > 10
          ? 'Variable'
          : variation > 7
            ? 'Somewhat variable'
            : 'Normal',
    });
    const bleeds = complete.map((c) => c.bleedingDays);
    const avgBleed = bleeds.reduce((a, b) => a + b, 0) / bleeds.length;
    baselines.push({
      name: 'Average Bleeding Duration',
      value: `${avgBleed.toFixed(1)} days`,
      reference: 'Typical reference: 2–7 days',
      tag:
        avgBleed > 8
          ? 'Elevated'
          : avgBleed < 2
            ? 'Lower than typical'
            : 'Normal',
    });
    const pains: number[] = [];
    for (const c of complete) {
      const startD = parseDay(c.start);
      const endD = parseDay(c.end);
      if (!startD || !endD) continue;
      for (const l of entries) {
        if (
          l.date >= startD &&
          l.date < endD &&
          (l.log.painScore ?? 0) > 0
        ) {
          pains.push(l.log.painScore!);
        }
      }
    }
    baselines.push({
      name: 'Average Pain Score',
      value:
        pains.length === 0
          ? 'No pain logged'
          : `${(pains.reduce((a, b) => a + b, 0) / pains.length).toFixed(1)}/10 across ${pains.length} days`,
      reference: 'Severe pain is not typical — worth discussing',
      tag:
        pains.length === 0
          ? 'Normal'
          : pains.reduce((a, b) => a + b, 0) / pains.length >= 7
            ? 'Elevated'
            : 'Mild',
    });
  } else {
    [
      'Average Cycle Length',
      'Cycle-to-cycle variation',
      'Average Bleeding Duration',
      'Average Pain Score',
    ].forEach(insufficient);
  }

  // ---- Patterns ----
  const patterns: PremiumReport['patterns'] = [];
  if (complete.length >= 2) {
    const long = complete.filter((c) => (c.length as number) > 35);
    if (long.length > 0) {
      patterns.push({
        name: 'Unusually long cycles',
        trigger: 'Cycle length above 35 days',
        observations: `Observed lengths: ${long.map((c) => `${c.length}d`).join(', ')}.`,
        cycleCount: long.length,
        dates: long.map((c) => c.start),
      });
    }
    const lens = complete.map((c) => c.length as number);
    const variation = Math.max(...lens) - Math.min(...lens);
    if (lens.length >= 3 && variation > 10) {
      patterns.push({
        name: 'Irregular cycle timing',
        trigger: 'Cycle-to-cycle variation above 10 days',
        observations: `Range observed: ${Math.min(...lens)}–${Math.max(...lens)} days across ${lens.length} cycles.`,
        cycleCount: lens.length,
        dates: complete.map((c) => c.start),
      });
    }
    const late = complete.filter((c) => (c.length as number) > typicalCycle + 7);
    if (late.length > 0) {
      patterns.push({
        name: 'Possible missed or late period',
        trigger: 'Cycle longer than typical length + 7 days',
        observations: `Affected starts: ${late.map((c) => c.start).join(', ')}.`,
        cycleCount: late.length,
        dates: late.map((c) => c.start),
      });
    }
  }
  // Prolonged bleeding (gap-aware runs within window).
  {
    const inWindowBleed = [...bleedDays]
      .map(parseDay)
      .filter((d): d is Date => d !== null && d >= cutoff)
      .sort((a, b) => a.getTime() - b.getTime());
    let run = 0;
    let prev: Date | null = null;
    const episodes: string[] = [];
    for (const d of inWindowBleed) {
      run =
        prev && d.getTime() - prev.getTime() === 86400000 ? run + 1 : 1;
      if (run > 8) episodes.push(`${day(d)} (+${run} days)`);
      prev = d;
    }
    if (episodes.length > 0) {
      patterns.push({
        name: 'Prolonged bleeding',
        trigger: 'Bleeding logged for more than 8 consecutive days',
        observations: `Episodes: ${episodes.join('; ')}.`,
        cycleCount: 0,
        dates: episodes,
      });
    }
  }

  // ---- Trends (first half vs second half) ----
  const trends: PremiumReport['trends'] = [];
  if (complete.length >= 2) {
    const half = Math.ceil(complete.length / 2);
    const first = complete.slice(0, half);
    const second = complete.slice(half);
    const avg = (xs: number[]) =>
      xs.length === 0 ? 0 : xs.reduce((a, b) => a + b, 0) / xs.length;
    const arrow = (d: number, t: number) =>
      d >= t ? '↑' : d <= -t ? '↓' : '→';
    const dLen =
      avg(second.map((c) => c.length as number)) -
      avg(first.map((c) => c.length as number));
    trends.push({
      name: 'Cycle length',
      indicator: arrow(dLen, 2),
      detail: `${dLen >= 0 ? '+' : ''}${dLen.toFixed(1)} days vs earlier cycles`,
    });
    const painOf = (cs: typeof complete) => {
      const ps: number[] = [];
      for (const c of cs) {
        const startD = parseDay(c.start);
        const endD = parseDay(c.end);
        if (!startD || !endD) continue;
        for (const e of entries) {
          if (
            e.date >= startD &&
            e.date < endD &&
            (e.log.painScore ?? 0) > 0
          ) {
            ps.push(e.log.painScore!);
          }
        }
      }
      return avg(ps);
    };
    const dPain = painOf(second) - painOf(first);
    trends.push({
      name: 'Pain',
      indicator: dPain >= 2 ? '⚠' : arrow(dPain, 1),
      detail: `${dPain >= 0 ? '+' : ''}${dPain.toFixed(1)} points vs earlier cycles`,
    });
    const conf = complete.filter((c) => c.ovulationConfirmed).length;
    trends.push({
      name: 'Ovulation consistency',
      indicator: conf === 0 ? '→' : conf === complete.length ? '✓' : '→',
      detail:
        conf === 0
          ? 'No LH-confirmed ovulations yet'
          : `${conf} of ${complete.length} cycles LH-confirmed`,
    });
  }

  // ---- Symptom summary + recommendations ----
  const occ = new Map<string, number>();
  const sev = new Map<string, number[]>();
  const cyc = new Map<string, Set<number>>();
  const recent = new Map<string, string>();
  for (const c of cycles) {
    for (const e of entries) {
      if (e.date < parseDay(c.start)! || (c.end && e.date >= parseDay(c.end)!)) {
        continue;
      }
      for (const s of e.log.symptoms ?? []) {
        occ.set(s, (occ.get(s) ?? 0) + 1);
        const rating = e.log.symptomIntensity?.[s];
        if (typeof rating === 'number') {
          if (!sev.has(s)) sev.set(s, []);
          sev.get(s)!.push(rating);
        }
        if (!cyc.has(s)) cyc.set(s, new Set());
        cyc.get(s)!.add(c.number);
        recent.set(s, day(e.date));
      }
    }
  }
  const symptomSummary = [...occ.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 8)
    .map(([name, count]) => {
      const ratings = sev.get(name) ?? [];
      return {
        name,
        occurrences: count,
        avgSeverity:
          ratings.length === 0
            ? '—'
            : `${(ratings.reduce((a, b) => a + b, 0) / ratings.length).toFixed(1)}/10`,
        cyclesAffected: cyc.get(name)?.size ?? 0,
        recent: recent.get(name) ?? '',
      };
    });

  const recommendations: string[] = [];
  if (complete.length >= 2) {
    const lens = complete.map((c) => c.length as number);
    const variation = Math.max(...lens) - Math.min(...lens);
    recommendations.push(
      variation <= 7
        ? `Wellness suggestion (educational): your cycle length has been steady (variation ${variation} days) — keeping your logging routine preserves this clarity.`
        : `Wellness suggestion (educational): your cycle timing varies by ${variation} days — tracking sleep and stress alongside your cycle can reveal personal rhythms worth discussing with a professional.`,
    );
    if (symptomSummary.length > 0) {
      recommendations.push(
        `Wellness suggestion (educational): ${symptomSummary[0].name} is your most logged symptom (${symptomSummary[0].occurrences} days) — noting what helps builds your personal care playbook.`,
      );
    }
    if (!complete.some((c) => c.ovulationConfirmed)) {
      recommendations.push(
        'Wellness suggestion (educational): log LH tests through your fertile window to turn estimated ovulation into confirmed ovulation.',
      );
    }
  } else {
    recommendations.push(
      'Wellness suggestion (educational): keep logging daily — consistent data is the foundation of every insight here.',
    );
  }

  const reliability =
    complete.length >= 3
      ? 'High'
      : complete.length >= 2
        ? 'Moderate'
        : 'Insufficient';

  const summary: string[] =
    complete.length >= 2
      ? [
          `Overall Tracking Summary: ${complete.length} complete cycles analysed over the past ${windowDays} days.`,
          reliability === 'High'
            ? 'Cycle regularity looks steady — keep your logging routine.'
            : 'Keep logging daily to strengthen these insights.',
          complete.some((c) => c.ovulationConfirmed)
            ? 'Ovulation confirmed by LH peak in at least one cycle.'
            : 'Ovulation estimated only — LH tests would confirm it.',
        ]
      : [
          'Overall Tracking Summary: not enough complete cycles yet — log daily (period, symptoms, LH tests) and return for a fuller picture.',
        ];

  return {
    windowLabel: `Past ${windowDays} days`,
    generatedAt: day(today),
    cyclesAnalyzed: complete.length,
    cycles,
    baselines,
    patterns,
    trends,
    symptomSummary,
    recommendations: recommendations.slice(0, 6),
    reliability,
    summary,
  };
}
