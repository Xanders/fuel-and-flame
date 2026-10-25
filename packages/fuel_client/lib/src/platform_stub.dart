import 'package:web_socket_channel/web_socket_channel.dart';
import 'platform_contract.dart';
export 'platform_contract.dart';

BrowserRecordPort? browserRecords(String namespace) => null;
WebSocketChannel connectSocket(Uri uri, Map<String, String> headers) =>
    WebSocketChannel.connect(uri);
