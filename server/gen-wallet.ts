import algosdk from 'algosdk';

/**
 * Generates Algorand TestNet accounts for the x402 demo.
 *   npx tsx gen-wallet.ts payer      -> prints payer address + mnemonic
 *   npx tsx gen-wallet.ts merchant   -> prints merchant address (AVM_ADDRESS)
 *
 * Fund both with TestNet ALGO (Lora faucet), opt both into TestNet USDC,
 * fund both with TestNet USDC (Circle faucet). NEVER commit mnemonics.
 */
const account = algosdk.generateAccount();
console.log('address :', account.addr.toString());
console.log('mnemonic:', algosdk.secretKeyToMnemonic(account.sk));
