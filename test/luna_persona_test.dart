import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hercycle/core/luna_service.dart';
import 'package:hercycle/providers/luna_persona_provider.dart';

void main() {
  group('LunaPersonas constants', () {
    test('8 ids, caregiver default, every id has meta + greeting', () {
      expect(LunaPersonas.ids, hasLength(8));
      expect(LunaPersonas.defaultPersona, 'caregiver');
      for (final id in LunaPersonas.ids) {
        expect(LunaPersonas.normalize(id), id);
        expect(LunaPersonas.meta[id], isNotNull);
        expect(LunaPersonas.greetings[id], isNotNull);
        expect(LunaPersonas.greetings[id]!.length, greaterThan(10));
      }
    });

    test('normalize degrades unknown values to default', () {
      expect(LunaPersonas.normalize('bogus'), 'caregiver');
      expect(LunaPersonas.normalize(null), 'caregiver');
      expect(LunaPersonas.normalize(''), 'caregiver');
    });
  });

  group('persona provider', () {
    test('defaults to caregiver, ignores unknown ids', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(lunaPersonaProvider), 'caregiver');
      await container
          .read(lunaPersonaProvider.notifier)
          .setPersona('bogus');
      expect(container.read(lunaPersonaProvider), 'caregiver');
    });

    test('accepts a known id without login (persistence best-effort)',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(lunaPersonaProvider.notifier)
          .setPersona('flirt');
      expect(container.read(lunaPersonaProvider), 'flirt');
    });
  });

  group('ask() persona plumbing', () {
    late HttpServer server;
    late Map<String, dynamic> lastBody;

    setUp(() async {
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) async {
        final text = await utf8.decodeStream(req);
        lastBody = jsonDecode(text) as Map<String, dynamic>;
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'reply': 'hello there'}));
        await req.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('sends persona when provided', () async {
      final reply = await LunaService.ask(
        serverUrl: 'http://127.0.0.1:${server.port}',
        message: 'hi',
        summary: const {},
        persona: 'flirt',
      );

      expect(reply, 'hello there');
      expect(lastBody['persona'], 'flirt');
      expect(lastBody['message'], 'hi');
    });

    test('omits persona key when null', () async {
      final reply = await LunaService.ask(
        serverUrl: 'http://127.0.0.1:${server.port}',
        message: 'hi',
        summary: const {},
      );

      expect(reply, 'hello there');
      expect(lastBody.containsKey('persona'), isFalse);
    });
  });
}
