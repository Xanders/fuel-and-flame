abstract class BrowserRecordPort {
  Future<String?> read(String slot);
  Future<void> write(String slot, String value);
  Future<void> lock(Future<void> Function() action);
  Future<void> lockIdentity(Future<void> Function() action);
  Stream<void> get changes;
  void close();
}
