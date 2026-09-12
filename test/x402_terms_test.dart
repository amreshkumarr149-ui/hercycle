import 'package:flutter_test/flutter_test.dart';
import 'package:hercycle/core/premium_service.dart';
import 'package:hercycle/core/x402_service.dart';

void main() {
  group('X402Terms network flexibility', () {
    test('labels testnet and mainnet, truncates unknown ids', () {
      expect(
        const X402Terms(
                price: '\$0.01',
                network: 'algorand:SGO1GKSzyE7IEPItTxCByw9x8FmnrCDexi9/cOUJOiI=',
                payTo: 'X',
                asset: 'Y')
            .networkLabel,
        'TestNet',
      );
      expect(
        const X402Terms(
                price: '\$0.01',
                network: 'algorand:wGHE2Pwdvd7S12BL5FaOP20EGYesN73ktiC1qzkkit8=',
                payTo: 'X',
                asset: 'Y')
            .networkLabel,
        'MainNet',
      );
      expect(
        const X402Terms(
                price: '?', network: '?', payTo: 'X', asset: 'Y')
            .networkLabel,
        '?',
      );
    });

    test('mainnet flag only on mainnet ids', () {
      expect(X402Terms.fallback.isMainnet, isFalse);
      expect(
        const X402Terms(
                price: 'x', network: 'algorand:MAINNET', payTo: 'x', asset: 'x')
            .isMainnet,
        isTrue,
      );
    });

    test('explorer links per network, null when unknown or blank', () {
      const testnet =
          'algorand:SGO1GKSzyE7IEPItTxCByw9x8FmnrCDexi9/cOUJOiI=';
      const mainnet =
          'algorand:wGHE2Pwdvd7S12BL5FaOP20EGYesN73ktiC1qzkkit8=';
      expect(
        X402Service.explorerTxUrl(testnet, 'ABC123'),
        'https://lora.algokit.io/testnet/transaction/ABC123',
      );
      expect(
        X402Service.explorerTxUrl(mainnet, 'ABC123'),
        'https://lora.algokit.io/mainnet/transaction/ABC123',
      );
      expect(
        X402Service.explorerAccountUrl(testnet, 'ADDR'),
        'https://lora.algokit.io/testnet/account/ADDR',
      );
      expect(X402Service.explorerTxUrl('mystery-net', 'ABC'), isNull);
      expect(X402Service.explorerTxUrl(testnet, '   '), isNull);
      expect(X402Service.explorerAccountUrl(testnet, ''), isNull);
    });

    test('fallback terms stay testnet-shaped', () {
      expect(X402Terms.fallback.networkLabel, 'TestNet');
      expect(X402Terms.fallback.facilitator, '');
    });
  });

  group('PremiumReceipt', () {
    test('shortId truncates long ids, passes short ones through', () {
      expect(
        const PremiumReceipt(txId: 'ABC', used: false).shortId,
        'ABC',
      );
      expect(
        const PremiumReceipt(
                txId: 'ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890', used: true)
            .shortId,
        contains('…'),
      );
    });
  });
}
