import 'dotenv/config';
import algosdk from 'algosdk';
import { x402Client, wrapFetchWithPayment, x402HTTPClient } from '@x402-avm/fetch';
import {
  toClientAvmSigner,
  ExactAvmScheme,
  ALGORAND_TESTNET_CAIP2,
} from '@x402-avm/avm';

/**
 * End-to-end x402 demo client for the HerCycle premium API.
 *
 *   1. Plain unpaid POST  -> must return 402 (proves the gate is live).
 *   2. Paying POST        -> 402 triggers TestNet USDC signing from
 *      AVM_MNEMONIC, retries with proof, facilitator settles, server
 *      returns the premium report JSON.
 *
 * Requires a funded payer: TestNet ALGO + TestNet USDC with ASA opt-in
 * (see README + gen-wallet.ts). Never commit AVM_MNEMONIC.
 */
const SERVER = process.env.SERVER_URL ?? 'http://localhost:4021';
const mnemonic = process.env.AVM_MNEMONIC ?? '';

const sampleBody = {
  windowDays: 180,
  profile: { name: 'Demo', typicalCycleLength: 28 },
  logs: [
    { date: '2026-06-01', period: true, symptoms: ['Cramps'], flowIntensity: 'Medium' },
    { date: '2026-06-02', period: true, symptoms: [], flowIntensity: 'Light' },
    { date: '2026-06-14', mucus: 'Eggwhite', lhTest: 'Positive' },
    { date: '2026-06-29', period: true, symptoms: ['Headache'], flowIntensity: 'Medium' },
    { date: '2026-07-27', period: true, symptoms: ['Cramps'], flowIntensity: 'Heavy' },
  ],
};

async function main(): Promise<void> {
  // Step 1: plain unpaid call — must be 402.
  const plain = await fetch(`${SERVER}/api/premium-report`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(sampleBody),
  });
  console.log('unpaid status:', plain.status, plain.statusText);
  if (plain.status !== 402) {
    throw new Error(`expected HTTP 402, got ${plain.status}`);
  }
  console.log('Gate is LIVE: unpaid request rejected with 402.\n');

  // Step 2: paying call.
  if (!mnemonic) {
    throw new Error('Set AVM_MNEMONIC in server/.env (funded TestNet payer).');
  }
  const { sk } = algosdk.mnemonicToSecretKey(mnemonic);
  const avmSigner = toClientAvmSigner(Buffer.from(sk).toString('base64'));
  console.log(`AVM signer (payer): ${avmSigner.address}`);

  const client = new x402Client();
  client.register(ALGORAND_TESTNET_CAIP2, new ExactAvmScheme(avmSigner));

  const fetchWithPayment = wrapFetchWithPayment(fetch, client);
  const paid = await fetchWithPayment(`${SERVER}/api/premium-report`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(sampleBody),
  });

  if (!paid.ok) {
    throw new Error(`paid call failed: ${paid.status} ${await paid.text()}`);
  }
  const settle = new x402HTTPClient(client).getPaymentSettleResponse((n) =>
    paid.headers.get(n),
  );
  console.log('\nPayment settled:');
  console.log(JSON.stringify(settle, null, 2));
  const data = (await paid.json()) as { report?: { reliability?: string } };
  console.log('\nPremium report reliability:', data.report?.reliability);
  console.log('\nEND-TO-END x402 FLOW COMPLETE ✔');
}

main().catch((e) => {
  console.error(e?.response?.data?.error ?? e);
  process.exit(1);
});
