# HerCycle Deep Insight — x402 Premium API (Algorand TestNet)

`POST /api/premium-report` serves the 6-month premium cycle analysis **only
after a $0.01 USDC payment** settles on Algorand TestNet through the
GoPlausible facilitator. Unpaid calls get HTTP `402 Payment Required`.

## 1. Wallets (one-time)

```bash
npx tsx gen-wallet.ts payer      # save address + mnemonic privately
npx tsx gen-wallet.ts merchant   # save address -> AVM_ADDRESS
```

Fund **both** addresses:

1. TestNet ALGO — [Lora faucet](https://lora.algokit.io/testnet/fund)
2. Opt **both** into TestNet USDC (ASA `10458941`) — via Lora or Pera/Lute
3. TestNet USDC — [Circle faucet](https://faucet.circle.com/) (Algorand TestNet)

## 2. Configure

```bash
cp .env.example .env
```

```env
ALGORAND_NETWORK=testnet
AVM_ADDRESS=<merchant address>
FACILITATOR_URL=https://facilitator.goplausible.xyz
AVM_MNEMONIC=<payer 25-word mnemonic, test client only>
PORT=4021
```

Never commit `.env`.

> **Networks:** `ALGORAND_NETWORK=testnet` (default, play money) or
> `mainnet` (**real money** — the merchant address, USDC ASA
> (`31566704`), ledger endpoint, receipt checks and the 402 terms all
> switch together). Anything else fails fast at boot. `/health` reports
> the active `networkName` plus an `explorerTxBase` for receipt links.

## 3. Run + prove the gate

```bash
npm run dev
# in another terminal:
curl -s -o /dev/null -w "%{http_code}\n" -X POST localhost:4021/api/premium-report \
  -H 'content-type: application/json' -d '{"logs":[]}'
# -> 402
```

## 4. End-to-end paid flow (the demo)

```bash
npm run test:e2e
```

Expected: `unpaid status: 402` → payer address → settlement JSON with
`success: true` + TestNet `transaction` id → premium report summary.
Paste the transaction id into
[Algorand TestNet explorer](https://testnet.explorer.perawallet.app/) as the
live proof. Settled volume also appears on the
[facilitator dashboard](https://facilitator.goplausible.xyz/dashboard).

## Verifying a payment (receipt route)

`GET /api/receipt/:txid` checks the id directly against Algorand TestNet
(free Algonode API, no key) and returns `{verified:true, ...}` only for a
**confirmed** transfer of ≥ $0.01 TestNet USDC (ASA `10458941`) **to**
`AVM_ADDRESS`. Try it with a bogus id:

```bash
curl -s localhost:4021/api/receipt/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
# {"verified":false,"txId":"...","reason":"Transaction not found on Algorand TestNet."}
```

The Flutter app uses this route for its "Verify payment & open report"
flow: pay from any wallet → paste the tx id → verified → receipt recorded →
report opens → export consumes exactly one receipt (one report per pay).

## API contract

`POST /api/premium-report` — body `{ logs: DailyLogInput[], profile?, windowDays? }`
(price `$0.01` USDC, `algorand:SGO1GKSzyE7IEPItTxCByw9x8FmnrCDexi9/cOUJOiI=`).

- Unpaid → `402` + `payment-required` header (machine-readable terms)
- Paid   → `200` + `{ success, paid, asset, report, disclaimer }`
- Bad body → `400`

`GET /health` is free (liveness probe).

`POST /api/luna/chat` — body `{ message: string (≤500 chars), summary: LunaSummary }`
(log-grounded assistant; free route, throttled + 100/day/IP cap).

- Factual intents (period dates, symptom history, moods, LH, notes) answered
  deterministically from the posted 90-day summary — no LLM needed.
- Interpretive questions use Gemini **only** when `GEMINI_API_KEY` is set
  (Google AI Studio, free tier); every AI reply must cite dates/scores
  present in the summary and contain zero diagnostic claims, or it is
  replaced by the honest fallback. Without a key, all interpretive
  questions get the fallback — the endpoint never errors for lack of AI.
- Crisis and heavy-bleeding phrasing short-circuit to care redirects.
- `400` bad body · `429` daily cap (with usable reply) · `500` safe fallback.
- Regression suite: `npm run check:luna` (7 groups, no key/network needed).

## Privacy & security posture

- **Health data:** `POST /api/premium-report` bodies are analysed in-memory
  per request and never persisted, logged, or cached. Request bodies never
  appear in logs (only error objects, which carry no log content).
- **Secrets:** payer mnemonics live only in local `.env` (git-ignored —
  verify with `git check-ignore -v server/.env` before the first push).
  Nothing secret is required in the repo: no API keys (facilitator is
  keyless), no service accounts.
- **Transport:** the server binds `127.0.0.1` by default. Set `HOST=0.0.0.0`
  only deliberately (e.g. on-device demo over LAN), and prefer a TLS
  tunnel/VPS for anything beyond localhost — the server warns on boot when
  bound non-local without TLS.
- **Abuse:** free routes are throttled (30 req/min/IP, in-memory) since
  `/api/receipt` fans out to the public Algonode API.
- **Known demo-grade tradeoffs (documented, not hidden):**
  1. The first-free flag and receipt ledger are client-enforced; a user
     editing their own Firestore doc could re-arm free reports. Phase 2
     moves enforcement into the x402-verified endpoint.
  2. A TestNet tx id is bearer value: anyone holding someone else's tx id
     could redeem that $0.01 of value. Irrelevant on valueless TestNet;
     mainnet needs payer-bound payloads.
