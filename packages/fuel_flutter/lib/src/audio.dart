import 'dart:async';

/// Local playback policy over an application's existing audio backend.
/// The application chooses tracks/cues and owns their pools and assets.
final class FuelAudioPolicy {
  FuelAudioPolicy({
    required Future<void> Function(String asset) startMusic,
    required Future<void> Function() stopMusic,
    Future<void> Function()? disposeBackend,
    void Function(bool active)? effectsActive,
    String? music,
  }) : _startMusic = startMusic,
       _stopMusic = stopMusic,
       _disposeBackend = disposeBackend,
       _effectsActive = effectsActive,
       _music = music;

  final Future<void> Function(String) _startMusic;
  final Future<void> Function() _stopMusic;
  final Future<void> Function()? _disposeBackend;
  final void Function(bool)? _effectsActive;
  String? _music, _playing;
  bool _known = true, _unlocked = false, _active = true, _disposed = false;
  bool _musicEnabled = true, _effectsEnabled = true;
  int _request = 0;
  Future<void>? _worker, _disposing;

  bool get musicEnabled => _musicEnabled;
  bool get effectsEnabled => _effectsEnabled;
  bool get effectsAllowed => !_disposed && _active && _effectsEnabled;
  String? get _desired =>
      !_disposed && _active && _unlocked && _musicEnabled ? _music : null;

  Future<void> onUserInteraction() {
    if (_disposed) return Future.value();
    _unlocked = true;
    return _sync();
  }

  Future<void> setMusic(String? asset) {
    if (_disposed) return Future.value();
    _music = asset;
    return _sync();
  }

  Future<void> setMusicEnabled(bool enabled) {
    if (_disposed) return Future.value();
    _musicEnabled = enabled;
    return _sync();
  }

  void setEffectsEnabled(bool enabled) {
    if (_disposed) return;
    _effectsEnabled = enabled;
    _notifyEffects();
  }

  Future<void> setAppActive(bool active) {
    if (_disposed) return Future.value();
    _active = active;
    _notifyEffects();
    return _sync();
  }

  void _notifyEffects() {
    try {
      _effectsActive?.call(effectsAllowed);
    } on Object {
      // Decorative playback cannot prevent gameplay or lifecycle cleanup.
    }
  }

  Future<void> playEffect(Future<void> Function() cue) async {
    if (!effectsAllowed) return;
    try {
      await cue();
    } on Object {
      // The backend owns cancellation of cues that were already started.
    }
  }

  Future<void> _sync() {
    _request++;
    if (_worker case final pending?) return pending;
    final completion = Completer<void>();
    _worker = completion.future;
    // Enter the idle driver before yielding the browser's user gesture.
    unawaited(_drive(completion));
    return completion.future;
  }

  Future<void> _drive(Completer<void> completion) async {
    try {
      while (true) {
        final desired = _desired, request = _request;
        if (_known && _playing == desired) break;
        try {
          if (desired == null) {
            await _stopMusic();
          } else {
            await _startMusic(desired);
          }
          _playing = desired;
          _known = true;
        } on Object {
          _known = false;
          if (desired != null) {
            try {
              await _stopMusic();
            } on Object {
              // A later request can retry an unavailable audio device.
            }
          }
          if (request == _request) break;
        }
      }
    } finally {
      _worker = null;
      completion.complete();
    }
  }

  Future<void> dispose() => _disposing ??= _dispose();
  Future<void> _dispose() async {
    _disposed = true;
    _notifyEffects();
    await _sync();
    try {
      await _disposeBackend?.call();
    } on Object {
      // Optional audio cleanup must not block application disposal.
    }
  }
}
