import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fuel_flutter/fuel_flutter.dart';

void main() {
  test(
    'configuration does not invent a gesture and effects obey foreground',
    () async {
      final calls = <String>[];
      final policy = FuelAudioPolicy(
        music: 'menu',
        startMusic: (asset) async {
          calls.add('start:$asset');
        },
        stopMusic: () async {
          calls.add('stop');
        },
        disposeBackend: () async {
          calls.add('dispose');
        },
        effectsActive: (active) {
          calls.add('effects:$active');
        },
      );
      await policy.setMusicEnabled(true);
      await policy.setAppActive(true);
      expect(calls.where((c) => c.startsWith('start')), isEmpty);
      final interaction = policy.onUserInteraction();
      expect(
        calls,
        contains('start:menu'),
        reason: 'enter playback in the gesture stack',
      );
      await interaction;
      await policy.onUserInteraction();
      expect(calls.where((c) => c == 'start:menu'), hasLength(1));
      await policy.setAppActive(false);
      await policy.playEffect(() async {
        calls.add('effect');
      });
      expect(calls, isNot(contains('effect')));
      await policy.dispose();
      await policy.dispose();
      expect(calls.where((c) => c == 'dispose'), hasLength(1));
    },
  );
  test(
    'latest mute and track win during a pending start without overlap or resurrection',
    () async {
      final gate = Completer<void>();
      final calls = <String>[];
      var running = 0, maximum = 0;
      final policy = FuelAudioPolicy(
        music: 'first',
        startMusic: (asset) async {
          running++;
          if (running > maximum) maximum = running;
          calls.add('start:$asset');
          await gate.future;
          running--;
        },
        stopMusic: () async {
          running++;
          if (running > maximum) maximum = running;
          calls.add('stop');
          running--;
        },
        disposeBackend: () async {
          calls.add('dispose');
        },
      );
      final start = policy.onUserInteraction();
      final track = policy.setMusic('second');
      final muted = policy.setMusicEnabled(false);
      final disposed = policy.dispose();
      gate.complete();
      await Future.wait([start, track, muted, disposed]);
      await policy.onUserInteraction();
      await policy.setMusicEnabled(true);
      expect(calls, ['start:first', 'stop', 'dispose']);
      expect(maximum, 1);
    },
  );
  test(
    'autoplay rejection retries only on a later request and decorative failures stay optional',
    () async {
      var starts = 0;
      final policy = FuelAudioPolicy(
        music: 'menu',
        startMusic: (_) async {
          if (++starts == 1) throw StateError('autoplay');
        },
        stopMusic: () async {},
      );
      await policy.onUserInteraction();
      expect(starts, 1);
      await policy.onUserInteraction();
      expect(starts, 2);
      await policy.playEffect(() async {
        throw StateError('missing optional asset');
      });
      policy.setEffectsEnabled(false);
      var effects = 0;
      await policy.playEffect(() async {
        effects++;
      });
      expect(effects, 0);
      await policy.dispose();
    },
  );
}
