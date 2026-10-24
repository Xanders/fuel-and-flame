import 'dart:async';
import 'dart:convert';
import 'package:fuel_client/fuel_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'review_regression_test.dart' show TestChannel;

void main() {
  final uri = Uri.parse('https://example.test/legacy');
  test('HTTP preserves status and headers without semantic retries', () async {
    var calls = 0;
    final transport = FuelHttpTransport(
      client: MockClient((request) async {
        calls++;
        expect(request.headers['x-binding'], 'selected');
        expect(request.body, '{"operation":"stable"}');
        return http.Response('committed', 409, headers: {'x-result': 'known'});
      }),
    );
    final response = await transport.post(
      uri,
      headers: {'x-binding': 'selected'},
      body: '{"operation":"stable"}',
    );
    expect(response.statusCode, 409);
    expect(response.headers['x-result'], 'known');
    expect(response.body, 'committed');
    expect(calls, 1);
    transport.close();
  });

  test(
    'HTTP rejects oversized input before sending and bounds streamed output',
    () async {
      var calls = 0;
      final transport = FuelHttpTransport(
        maxRequestBytes: 4,
        maxResponseBytes: 4,
        client: MockClient.streaming((request, body) async {
          calls++;
          return http.StreamedResponse(
            Stream.fromIterable([
              [1, 2, 3],
              [4, 5],
            ]),
            200,
          );
        }),
      );
      await expectLater(
        transport.post(uri, body: '12345'),
        throwsA(
          isA<FuelException>().having((e) => e.code, 'code', 'too_large'),
        ),
      );
      expect(calls, 0);
      await expectLater(
        transport.get(uri),
        throwsA(
          isA<FuelException>().having((e) => e.code, 'code', 'too_large'),
        ),
      );
      expect(calls, 1);
      transport.close();
    },
  );

  test(
    'HTTP cancellation and disposal finish even with hung headers',
    () async {
      final headers = Completer<http.StreamedResponse>();
      final transport = FuelHttpTransport(
        client: MockClient.streaming((_, _) => headers.future),
      );
      final cancel = Completer<void>();
      final first = transport.get(uri, cancel: cancel.future);
      final firstCheck = expectLater(first, throwsA(isA<FuelException>()));
      cancel.complete();
      await firstCheck;
      final second = transport.get(uri);
      final secondCheck = expectLater(second, throwsA(isA<FuelException>()));
      transport.close();
      await secondCheck;
      headers.complete(
        http.StreamedResponse(Stream.value(utf8.encode('late')), 200),
      );
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('HTTP total deadline includes the response body', () async {
    final body = StreamController<List<int>>();
    final transport = FuelHttpTransport(
      timeout: const Duration(milliseconds: 10),
      client: MockClient.streaming(
        (_, _) async => http.StreamedResponse(body.stream, 200),
      ),
    );
    await expectLater(transport.get(uri), throwsA(isA<FuelException>()));
    transport.close();
    await body.close();
  });

  test('reconnect fences hung ready and late stream callbacks', () async {
    final old = DelayedChannel();
    final fresh = TestChannel();
    final connection = FuelConnection();
    final seen = <Json>[];
    final errors = <Object>[];
    final pending = connection.connect(
      old,
      onMessage: seen.add,
      onError: errors.add,
    );
    expect(
      await connection.connect(
        fresh,
        onMessage: seen.add,
        onError: errors.add,
        hello: {'type': 'auth'},
      ),
      isTrue,
    );
    expect(jsonDecode(fresh.sink.messages.single as String), {'type': 'auth'});
    old.handshake.completeError(StateError('old handshake'));
    expect(await pending, isFalse);
    old.inbound.add('{"old":true}');
    fresh.inbound.add('{"fresh":true}');
    expect(seen, [
      {'fresh': true},
    ]);
    expect(errors, isEmpty);
    await connection.close();
    await old.inbound.close();
    await fresh.inbound.close();
  });

  test(
    'callback failures are terminal once and never escape the stream',
    () async {
      final channel = TestChannel();
      final connection = FuelConnection();
      final errors = <Object>[];
      await connection.connect(
        channel,
        onMessage: (_) => throw StateError('consumer'),
        onError: (error) {
          errors.add(error);
          throw StateError('error callback');
        },
      );
      channel.inbound.add('{}');
      channel.inbound.add('{}');
      expect(errors, hasLength(1));
      expect(connection.connected, isFalse);
      expect(() => connection.send({}), throwsA(isA<FuelException>()));
      await connection.close();
      await channel.inbound.close();
    },
  );

  test(
    'reentrant disconnect cannot renew heartbeat or deliver queued input',
    () async {
      final channel = TestChannel();
      final connection = FuelConnection();
      var seen = 0;
      await connection.connect(
        channel,
        onMessage: (_) {
          seen++;
          unawaited(connection.disconnect());
        },
      );
      channel.inbound.add('{}');
      channel.inbound.add('{}');
      expect(seen, 1);
      expect(connection.connected, isFalse);
      await connection.close();
      await channel.inbound.close();
    },
  );
}

class DelayedChannel extends TestChannel {
  final handshake = Completer<void>();
  @override
  Future<void> get ready => handshake.future;
}
