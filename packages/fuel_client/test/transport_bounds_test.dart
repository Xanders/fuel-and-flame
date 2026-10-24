import 'dart:async';
import 'package:fuel_client/fuel_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'review_regression_test.dart' show TestChannel;
import 'transport_test.dart' show DelayedChannel;

void main() {
  final uri = Uri.parse('https://example.test/legacy');
  test(
    'HTTP pending limit releases on cancellation without closing other requests',
    () async {
      final replies = <Completer<http.StreamedResponse>>[];
      final transport = FuelHttpTransport(
        maxPending: 1,
        client: MockClient.streaming((_, _) {
          final reply = Completer<http.StreamedResponse>();
          replies.add(reply);
          return reply.future;
        }),
      );
      final cancel = Completer<void>();
      final pending = transport.get(uri, cancel: cancel.future);
      final cancelled = expectLater(pending, throwsA(isA<FuelException>()));
      await expectLater(
        transport.get(uri),
        throwsA(isA<FuelException>().having((e) => e.code, 'code', 'busy')),
      );
      cancel.complete();
      await cancelled;
      final next = transport.get(uri);
      replies.last.complete(http.StreamedResponse(Stream.value([65]), 200));
      expect((await next).body, 'A');
      replies.first.complete(http.StreamedResponse(const Stream.empty(), 200));
      transport.close();
    },
  );

  test('HTTP cancellation discards a partially delivered body', () async {
    final body = StreamController<List<int>>(sync: true);
    final cancel = Completer<void>();
    final transport = FuelHttpTransport(
      client: MockClient.streaming(
        (_, _) async => http.StreamedResponse(body.stream, 200),
      ),
    );
    final response = transport.get(uri, cancel: cancel.future);
    final checked = expectLater(response, throwsA(isA<FuelException>()));
    await Future<void>.delayed(Duration.zero);
    body.add([65]);
    cancel.complete();
    await checked;
    body.add([66]);
    await body.close();
    transport.close();
  });

  test(
    'unqualified messages do not keep a silent snapshot stream alive',
    () async {
      final channel = TestChannel();
      final connection = FuelConnection(
        heartbeatTimeout: const Duration(milliseconds: 30),
      );
      final failed = Completer<Object>();
      await connection.connect(
        channel,
        onMessage: (_) {},
        isHeartbeat: (json) => json['type'] == 'snapshot',
        onError: failed.complete,
      );
      channel.inbound.add('{"type":"feedback"}');
      expect(await failed.future, isA<FuelException>());
      expect(connection.connected, isFalse);
      await connection.close();
      await channel.inbound.close();
    },
  );

  test(
    'oversized and malformed input terminate without invoking the consumer',
    () async {
      for (final message in ['123456789', '[1]']) {
        final channel = TestChannel();
        final connection = FuelConnection(maxMessageBytes: 8);
        var seen = 0, failures = 0;
        await connection.connect(
          channel,
          onMessage: (_) => seen++,
          onError: (_) => failures++,
        );
        channel.inbound.add(message);
        expect(seen, 0);
        expect(failures, 1);
        await connection.close();
        await channel.inbound.close();
      }
    },
  );

  test(
    'ready deadline completes connect without waiting for channel shutdown',
    () async {
      final channel = DelayedChannel();
      final connection = FuelConnection(
        readyTimeout: const Duration(milliseconds: 10),
      );
      var failures = 0;
      expect(
        await connection.connect(
          channel,
          onMessage: (_) {},
          onError: (_) => failures++,
        ),
        isFalse,
      );
      expect(failures, 1);
      channel.handshake.complete();
      await connection.close();
      await channel.inbound.close();
    },
  );
}
