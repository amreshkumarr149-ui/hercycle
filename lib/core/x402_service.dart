import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

/// Live payment terms for the Deep Insight premium endpoint, read from the
/// server's real HTTP 402 response — never hardcoded.
///
/// Flow: POST /api/premium-report unpaid -> 402 + `payment-required` header
/// (base64 JSON with an `accepts` list). This parses the first accepted
/// term so the pay dialog always shows exactly what the chain expects.
class X402Terms {
  final String price;
  final String network;
  final String payTo;
  final String asset;

  /// Who settles the payment (host only, e.g. facilitator.goplausible.xyz).
  /// Empty when the server didn't advertise one.
  final String facilitator;

  const X402Terms({
    required this.price,
    required this.network,
    required this.payTo,
    required this.asset,
    this.facilitator = '',
  });

  /// Short pill label: TestNet / MainNet, else a truncated raw id.
  String get networkLabel {
    if (isMainnet) return 'MainNet';
    if (isTestnet) return 'TestNet';
    final raw = network.trim();
    return raw.length <= 18 ? raw : '${raw.substring(0, 17)}…';
  }

  /// True when these terms settle on Algorand MainNet (real money).
  bool get isMainnet => X402Service.isMainnetNetwork(network);

  /// True when these terms settle on Algorand TestNet (play money).
  bool get isTestnet => X402Service.isTestnetNetwork(network);

  /// Fallback shown when the server is unreachable (matches server defaults).
  static const fallback = X402Terms(
    price: '\$0.01',
    network: 'algorand:SGO1GKSzyE7IEPItTxCByw9x8FmnrCDexi9/cOUJOiI=',
    payTo: 'V6LK562WQZ3CQMA2THCVGZZUR5ZLCLTRNJQMBEQXZAIM53Q5FMLZ75U2TA',
    asset: '10458941 (TestNet USDC)',
  );
}

class X402Service {
  X402Service._();

  /// Default base URL. Works for Chrome web builds; on-device builds need
  /// the machine's LAN address (editable in the pay dialog, saved per user).
  static const defaultServerUrl = 'http://localhost:4021';

  /// Block-explorer URL for a transaction on the given network, or null
  /// when the network is unrecognized or the id is blank. No new
  /// dependencies: callers copy the URL to the clipboard.
  static String? explorerTxUrl(String network, String txId) {
    final base = _explorerBase(network);
    final id = txId.trim();
    if (base == null || id.isEmpty) return null;
    return '$base/transaction/$id';
  }

  /// Block-explorer URL for an account (e.g. the merchant), or null when
  /// the network is unrecognized or the address is blank.
  static String? explorerAccountUrl(String network, String address) {
    final base = _explorerBase(network);
    final addr = address.trim();
    if (base == null || addr.isEmpty) return null;
    return '$base/account/$addr';
  }

  /// Known CAIP-2 genesis hashes (mirror the server's @x402-avm
  /// constants). Real network ids carry no 'testnet'/'mainnet' substring,
  /// so detection matches hashes first, plain words second.
  static const _testnetGenesis =
      'SGO1GKSzyE7IEPItTxCByw9x8FmnrCDexi9/cOUJOiI=';
  static const _mainnetGenesis =
      'wGHE2Pwdvd7S12BL5FaOP20EGYesN73ktiC1qzkkit8=';

  static bool isMainnetNetwork(String network) {
    final n = network.toLowerCase();
    return n.contains('mainnet') ||
        n.contains(_mainnetGenesis.toLowerCase());
  }

  static bool isTestnetNetwork(String network) {
    if (isMainnetNetwork(network)) return false;
    final n = network.toLowerCase();
    return n.contains('testnet') ||
        n.contains(_testnetGenesis.toLowerCase());
  }

  static String? _explorerBase(String network) {
    if (isMainnetNetwork(network)) {
      return 'https://lora.algokit.io/mainnet';
    }
    if (isTestnetNetwork(network)) {
      return 'https://lora.algokit.io/testnet';
    }
    return null;
  }

  /// POSTs a minimal unpaid probe and parses the 402 terms.
  /// Returns null when the server is unreachable or misbehaving.
  static Future<X402Terms?> fetchTerms({required String serverUrl}) async {
    try {
      final res = await http
          .post(
            Uri.parse('$serverUrl/api/premium-report'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({
              'logs': [],
              'profile': {},
              'windowDays': 180,
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 402) return null;
      final header = res.headers['payment-required'];
      if (header == null || header.isEmpty) return null;
      final decoded =
          jsonDecode(utf8.decode(base64.decode(header.trim())))
              as Map<String, dynamic>;
      final accepts = decoded['accepts'];
      final first = accepts is List && accepts.isNotEmpty
          ? accepts.first as Map<String, dynamic>
          : null;
      if (first == null) return null;
      final extra = first['extra'];
      final extraMap = extra is Map ? extra : <String, dynamic>{};
      // v2 payloads carry amount in base units + decimals; legacy ones a
      // ready-made price string. Prefer the exact on-chain numbers.
      final assetId = (first['asset'] ?? extraMap['asset'])?.toString() ?? '';
      final assetName = extraMap['name']?.toString() ?? '';
      final decimals =
          int.tryParse(extraMap['decimals']?.toString() ?? '6') ?? 6;
      String price = (first['price'] ?? '').toString();
      final micro = int.tryParse(first['amount']?.toString() ?? '');
      if (micro != null) {
        final units = micro / math.pow(10, decimals);
        final name = assetName.isNotEmpty ? ' $assetName' : '';
        price = '\$$units$name';
      }
      if (price.isEmpty) price = '?';
      final network = (first['network'] ?? '?').toString();
      final isMain = X402Service.isMainnetNetwork(network);
      final facilitatorRaw = (decoded['facilitator'] ?? '').toString();
      String facilitatorHost = '';
      try {
        facilitatorHost =
            facilitatorRaw.isEmpty ? '' : Uri.parse(facilitatorRaw).host;
      } catch (_) {
        facilitatorHost = '';
      }
      return X402Terms(
        price: price,
        network: network,
        payTo: (first['payTo'] ?? '?').toString(),
        asset: assetId.isEmpty
            ? (isMain ? 'USDC' : 'TestNet USDC')
            : (isMain ? '$assetId (USDC)' : '$assetId (TestNet USDC)'),
        facilitator: facilitatorHost,
      );
    } catch (_) {
      return null;
    }
  }

  /// Result of verifying a user-supplied TestNet transaction id against
  /// `GET /api/receipt/:txid`.
  static Future<ReceiptVerification> verifyReceipt({
    required String serverUrl,
    required String txId,
  }) async {
    final id = txId.trim();
    if (id.isEmpty) {
      return const ReceiptVerification(
          verified: false, reason: 'Enter the transaction id first.');
    }
    try {
      final res = await http
          .get(Uri.parse('$serverUrl/api/receipt/${Uri.encodeComponent(id)}'))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        return ReceiptVerification(
            verified: false,
            reason: 'Server error (HTTP ${res.statusCode}).');
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['verified'] == true) {
        final amount = body['amount'];
        return ReceiptVerification(
          verified: true,
          txId: (body['txId'] ?? id).toString(),
          amountMicro: amount is num ? amount.toInt() : null,
          detail:
              'Confirmed on Algorand TestNet (${body['amount'] ?? '?'} base units, round ${body['confirmedRound'] ?? '?'}).',
        );
      }
      return ReceiptVerification(
        verified: false,
        reason: (body['reason'] ?? 'Not a qualifying payment.').toString(),
      );
    } catch (_) {
      return const ReceiptVerification(
          verified: false,
          reason: 'Server unreachable — start it with server/README.');
    }
  }
}

class ReceiptVerification {
  final bool verified;
  final String? txId;
  final int? amountMicro;
  final String? detail;
  final String? reason;

  const ReceiptVerification({
    required this.verified,
    this.txId,
    this.amountMicro,
    this.detail,
    this.reason,
  });
}
