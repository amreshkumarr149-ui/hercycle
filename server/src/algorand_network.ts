import {
  ALGORAND_MAINNET_CAIP2,
  ALGORAND_TESTNET_CAIP2,
  DEFAULT_ALGOD_MAINNET,
  DEFAULT_ALGOD_TESTNET,
  USDC_MAINNET_ASA_ID,
  USDC_TESTNET_ASA_ID,
} from '@x402-avm/avm';

export type AlgorandNetworkName = 'testnet' | 'mainnet';

export interface AlgorandNetworkConfig {
  name: AlgorandNetworkName;
  /** Short human label: 'TestNet' / 'MainNet'. */
  label: string;
  /** Typed as the x402 CAIP-2 `${chain}:${genesis}` shape. */
  caip2: `${string}:${string}`;
  usdcAsaId: number;
  algodBase: string;
  explorerTxBase: string;
  /** Price copy for the fixed $0.01 report charge. */
  priceLabel: string;
  assetLabel: string;
}

/**
 * Single source of truth for which Algorand network the server settles on,
 * driven by ALGORAND_NETWORK (default 'testnet'). An explicit unknown value
 * fails fast at boot — silently settling on the wrong network (real money
 * vs play money) is the one outcome that must never happen.
 */
export function getNetworkConfig(): AlgorandNetworkConfig {
  const raw = (process.env.ALGORAND_NETWORK ?? 'testnet').trim().toLowerCase();
  if (raw === 'mainnet') {
    return {
      name: 'mainnet',
      label: 'MainNet',
      caip2: ALGORAND_MAINNET_CAIP2,
      usdcAsaId: Number(USDC_MAINNET_ASA_ID),
      algodBase: DEFAULT_ALGOD_MAINNET,
      explorerTxBase: 'https://lora.algokit.io/mainnet/transaction/',
      priceLabel: '$0.01 USDC',
      assetLabel: 'USDC',
    };
  }
  if (raw === 'testnet' || raw === '') {
    return {
      name: 'testnet',
      label: 'TestNet',
      caip2: ALGORAND_TESTNET_CAIP2,
      usdcAsaId: Number(USDC_TESTNET_ASA_ID),
      algodBase: DEFAULT_ALGOD_TESTNET,
      explorerTxBase: 'https://lora.algokit.io/testnet/transaction/',
      priceLabel: '$0.01 USDC',
      assetLabel: 'USDC (TestNet)',
    };
  }
  throw new Error(
    `Invalid ALGORAND_NETWORK=${JSON.stringify(process.env.ALGORAND_NETWORK)} (expected 'testnet' or 'mainnet')`,
  );
}

export function explorerTxUrl(
  net: AlgorandNetworkConfig,
  txId: string,
): string {
  return `${net.explorerTxBase}${encodeURIComponent((txId ?? '').trim())}`;
}
