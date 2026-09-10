import {
  ALGORAND_TESTNET_CAIP2,
  USDC_TESTNET_ASA_ID,
} from '@x402-avm/avm';

export interface ReceiptCheck {
  verified: boolean;
  txId: string;
  amount?: number;
  assetId?: number;
  receiver?: string;
  confirmedRound?: number;
  reason?: string;
}

const ALGOD = 'https://testnet-api.algonode.cloud';
const REQUIRED_MICRO_USDC = 10000; // $0.01 at 6 decimals

/**
 * Verifies a TestNet payment directly against Algorand chain state.
 * Accepts only a CONFIRMED asset-transfer of >= $0.01 TestNet USDC
 * (ASA 10458941) to the merchant address. Everything else — unknown id,
 * unconfirmed, wrong asset, short amount, wrong receiver — returns
 * verified:false with a specific reason. Pure read path: no keys needed.
 */
export async function verifyReceipt(
  txId: string,
  merchant: string,
): Promise<ReceiptCheck> {
  const id = (txId ?? '').trim();
  if (!/^[A-Z2-7]{52}$/.test(id)) {
    return { verified: false, txId: id, reason: 'Not a valid Algorand transaction id.' };
  }
  let res: Response;
  try {
    res = await fetch(
      `${ALGOD}/v2/transactions/${encodeURIComponent(id)}`,
      { headers: { accept: 'application/json' } },
    );
  } catch {
    return {
      verified: false,
      txId: id,
      reason: 'Could not reach the TestNet ledger. Check connection and retry.',
    };
  }
  if (res.status === 404) {
    return {
      verified: false,
      txId: id,
      reason: 'Transaction not found on Algorand TestNet.',
    };
  }
  if (!res.ok) {
    return {
      verified: false,
      txId: id,
      reason: `Ledger lookup failed (HTTP ${res.status}).`,
    };
  }
  const body = (await res.json()) as {
    transaction?: {
      'tx-type'?: string;
      'asset-transfer-transaction'?: {
        'asset-id'?: number;
        amount?: number;
        receiver?: string;
      };
    };
    'confirmed-round'?: number;
  };
  const txn = body.transaction;
  if (!txn || body['confirmed-round'] == null) {
    return {
      verified: false,
      txId: id,
      reason: 'Transaction found but not yet confirmed. Wait a few seconds and retry.',
    };
  }
  if (txn['tx-type'] !== 'axfer') {
    return {
      verified: false,
      txId: id,
      reason: `Not a token transfer (type: ${txn['tx-type'] ?? 'unknown'}). Pay $0.01 TestNet USDC to unlock.`,
    };
  }
  const xfer = txn['asset-transfer-transaction'] ?? {};
  const assetId = Number(xfer['asset-id']);
  const amount = Number(xfer.amount);
  const receiver = String(xfer.receiver ?? '');
  if (assetId !== Number(USDC_TESTNET_ASA_ID)) {
    return {
      verified: false,
      txId: id,
      reason: `Wrong asset (ASA ${Number.isFinite(assetId) ? assetId : '?'}). Pay TestNet USDC (ASA ${USDC_TESTNET_ASA_ID}).`,
    };
  }
  if (receiver !== merchant) {
    return {
      verified: false,
      txId: id,
      reason: 'Payment went to a different address, not the HerCycle merchant.',
    };
  }
  if (!Number.isFinite(amount) || amount < REQUIRED_MICRO_USDC) {
    return {
      verified: false,
      txId: id,
      reason: `Amount too low (${Number.isFinite(amount) ? amount / 1e6 : '?'} USDC). $0.01 USDC required.`,
    };
  }
  return {
    verified: true,
    txId: id,
    amount,
    assetId,
    receiver,
    confirmedRound: body['confirmed-round'] as number,
  };
}

export const RECEIPT_NETWORK = ALGORAND_TESTNET_CAIP2;
