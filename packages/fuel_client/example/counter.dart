import 'package:fuel_client/fuel_client.dart';

Future<void> main(List<String> args) async {
  // Process-local demo only. Products must supply OS-protected durable ports.
  final records = <String, String>{};
  final vault = RecordCredentialVault(
    read: (slot) async => records[slot],
    write: (slot, value) async {
      records[slot] = value;
    },
  );
  final client = FuelClient(
    Uri.parse(args.isEmpty ? 'http://127.0.0.1:8080' : args.first),
  );
  try {
    await client.bootstrapNative(vault);
    final room = await client.createRoom('solo', capacity: 1);
    var revision = BigInt.zero;
    for (var n = 0; n < 3; n++) {
      final command = FuelCommand(
        randomId(),
        room['epoch'] as String,
        revision,
        {'amount': 3},
      );
      final reply = await client.command(room['session_id'] as String, command);
      final repeated = await client.command(
        room['session_id'] as String,
        command,
      );
      if (reply['revision'] != repeated['revision'])
        throw StateError('duplicate action');
      revision = BigInt.parse(reply['revision'] as String);
    }
    final board = await client.leaderboard('counter');
    if (board.isEmpty || board.first['score'] != '9')
      throw StateError('missing result');
    print(
      'PASS: guest -> solo session -> exact retry -> persisted leaderboard',
    );
  } finally {
    client.close();
  }
}
