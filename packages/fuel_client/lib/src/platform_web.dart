import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'platform_contract.dart';
export 'platform_contract.dart';

BrowserRecordPort browserRecords(String namespace) =>
    _BrowserRecords(namespace);
WebSocketChannel connectSocket(Uri uri, Map<String, String> headers) {
  if (headers.isNotEmpty)
    throw StateError('Browser credentials must use HttpOnly cookies');
  return WebSocketChannel.connect(uri);
}

class _BrowserRecords extends BrowserRecordPort {
  final String namespace;
  final _changes = StreamController<void>.broadcast(sync: true);
  late final JSFunction _listener;
  _BrowserRecords(this.namespace) {
    _listener = ((web.StorageEvent event) {
      if (event.key == null || event.key!.startsWith(namespace))
        _changes.add(null);
    }).toJS;
    web.window.addEventListener('storage', _listener);
  }
  @override
  Future<String?> read(String slot) async =>
      web.window.localStorage.getItem('$namespace:$slot');
  @override
  Future<void> write(String slot, String value) async {
    web.window.localStorage.setItem('$namespace:$slot', value);
  }

  @override
  Future<void> lock(Future<void> Function() action) async {
    await web.window.navigator.locks
        .request(namespace, ((web.Lock _) => action().toJS).toJS)
        .toDart;
  }

  @override
  Stream<void> get changes => _changes.stream;
  @override
  void close() {
    web.window.removeEventListener('storage', _listener);
    unawaited(_changes.close());
  }
}
