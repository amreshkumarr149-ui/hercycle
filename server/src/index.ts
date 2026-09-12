import 'dotenv/config';
import cors from 'cors';
import express from 'express';
import { paymentMiddleware, x402ResourceServer } from '@x402-avm/express';
import { HTTPFacilitatorClient } from '@x402-avm/core/server';
import { ExactAvmScheme } from '@x402-avm/avm/exact/server';
import { getNetworkConfig } from './algorand_network.js';
import { analyzePremium, type DailyLogInput } from './premium.js';
import { verifyReceipt } from './receipt.js';
import { answerLuna, checkLunaCap, type LunaSummary } from './luna.js';

/**
 * HerCycle Deep Insight premium API — every data route is gated by x402 on
 * Algorand (TestNet by default, MainNet via ALGORAND_NETWORK=mainnet),
 * settled through the GoPlausible facilitator.
 *
 * Unpaid request  -> 402 Payment Required (+ payment-required header)
 * Paid request    -> facilitator verifies + settles -> 200 + premium report
 */

const PORT = Number(process.env.PORT ?? 4021);
// Bind localhost only by default: health logs travel over this socket, so
// LAN-wide exposure must be an explicit choice (HOST=0.0.0.0), ideally
// behind TLS (tunnel/VPS) rather than raw LAN HTTP.
const HOST = process.env.HOST ?? '127.0.0.1';
const AVM_ADDRESS = process.env.AVM_ADDRESS ?? '';
const FACILITATOR_URL =
  process.env.FACILITATOR_URL ?? 'https://facilitator.goplausible.xyz';

// Minimal in-memory throttle (no new deps): the free /api/receipt route
// fans out to the public Algonode API, so bound it per IP.
const hits = new Map<string, number[]>();
const WINDOW_MS = 60_000;
const MAX_HITS = 30;
function throttle(
  req: express.Request,
  res: express.Response,
  next: express.NextFunction,
) {
  const ip = req.ip ?? 'unknown';
  const now = Date.now();
  const recent = (hits.get(ip) ?? []).filter((t) => now - t < WINDOW_MS);
  if (recent.length >= MAX_HITS) {
    res.status(429).json({ error: 'Rate limited. Slow down and retry.' });
    return;
  }
  recent.push(now);
  hits.set(ip, recent);
  next();
}

const NET = getNetworkConfig();

if (!AVM_ADDRESS) {
  console.error(
    `Missing environment variable: AVM_ADDRESS (merchant ${NET.label} address)`,
  );
  process.exit(1);
}

const facilitatorClient = new HTTPFacilitatorClient({ url: FACILITATOR_URL });
const resourceServer = new x402ResourceServer(facilitatorClient);
resourceServer.register(NET.caip2, new ExactAvmScheme());

const app = express();
app.use(cors());
app.use(express.json({ limit: '1mb' }));

// Free liveness probe (used by the app + judges to check the server).
app.get('/health', (_req, res) => {
  res.json({
    ok: true,
    service: 'hercycle-deep-insight',
    network: NET.caip2,
    networkName: NET.name,
    facilitator: FACILITATOR_URL,
    price: NET.priceLabel,
    explorerTxBase: NET.explorerTxBase,
  });
});

// ---- Free route: on-chain receipt verification ----
// Lets the app confirm an externally-made payment (any wallet) on the
// configured network and unlock exactly one report for it. Read-only
// against the ledger; the x402 middleware below only gates POST
// /api/premium-report.
app.get('/api/receipt/:txid', throttle, async (req, res) => {
  try {
    const result = await verifyReceipt(req.params.txid ?? '', AVM_ADDRESS, NET);
    res.json(result);
  } catch (err) {
    console.error('receipt check failed:', err);
    res.status(500).json({ verified: false, reason: 'Verification crashed.' });
  }
});

// ---- Free route: log-grounded Luna chat ----
// Deterministic factual answers come from the posted 90-day summary;
// interpretive ones use Gemini only when GEMINI_API_KEY is set, then pass
// a citation validator. Nothing is persisted.
app.post('/api/luna/chat', throttle, async (req, res) => {
  try {
    const { message, summary, persona } = (req.body ?? {}) as {
      message?: unknown;
      summary?: LunaSummary;
      persona?: unknown;
    };
    if (typeof message !== 'string' || message.trim().length === 0) {
      res.status(400).json({ error: 'Body must include message: string.' });
      return;
    }
    if (message.length > 500) {
      res
        .status(400)
        .json({ error: 'Message too long (500 characters max).' });
      return;
    }
    if (!checkLunaCap(req.ip ?? 'unknown')) {
      res.status(429).json({
        reply:
          "Luna's taking a breather — you've chatted a lot today! Come back tomorrow. 🌙",
        source: 'rules',
      });
      return;
    }
    const result = await answerLuna(message, summary ?? {}, persona);
    res.json(result);
  } catch (err) {
    console.error('luna chat failed:', err);
    res.status(500).json({
      reply:
        "Something hiccuped on my side — try again in a moment! Your rule-based answers still work offline. 🌙",
      source: 'rules',
    });
  }
});

// ---- x402 gate: exactly one paid route ----
app.use(
  paymentMiddleware(
    {
      'POST /api/premium-report': {
        accepts: [
          {
            scheme: 'exact',
            price: '$0.01',
            network: NET.caip2,
            payTo: AVM_ADDRESS,
            extra: { asset: String(NET.usdcAsaId) },
          },
        ],
        description:
          'HERcycle Deep Insight — 6-month cycle analysis, symptom patterns, irregularity trends and wellness recommendations',
        mimeType: 'application/json',
      },
    },
    resourceServer,
  ),
);

// ---- Paid handler: runs only after the facilitator confirms payment ----
app.post('/api/premium-report', throttle, (req, res) => {
  const { logs, profile, windowDays } = (req.body ?? {}) as {
    logs?: DailyLogInput[];
    profile?: { name?: string; typicalCycleLength?: number };
    windowDays?: number;
  };
  if (!Array.isArray(logs)) {
    res.status(400).json({ error: 'Body must include logs: DailyLogInput[]' });
    return;
  }
  const window =
    typeof windowDays === 'number' && windowDays > 0 && windowDays <= 730
      ? Math.floor(windowDays)
      : 180;
  try {
    const report = analyzePremium(logs, profile ?? {}, window);
    res.json({
      success: true,
      paid: true,
      asset: NET.assetLabel,
      network: NET.caip2,
      report,
      disclaimer:
        'Educational tracking summary only — not a medical diagnosis.',
    });
  } catch (err) {
    console.error('premium-report failed:', err);
    res.status(500).json({ error: 'Report generation failed' });
  }
});

app.listen(PORT, HOST, () => {
  console.log(`HerCycle x402 resource server on http://${HOST}:${PORT}`);
  console.log(`  network:          Algorand ${NET.label} (${NET.caip2})`);
  console.log(`  merchant (payTo): ${AVM_ADDRESS}`);
  console.log(`  facilitator:      ${FACILITATOR_URL}`);
  console.log(`  price:            ${NET.priceLabel} on Algorand ${NET.label}`);
  if (HOST !== '127.0.0.1' && HOST !== 'localhost') {
    console.warn(
      '  WARNING: bound to a non-loopback interface without TLS. ' +
        'Health logs cross the network in cleartext — use a tunnel/VPS.',
    );
  }
});
