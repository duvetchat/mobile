import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';

/// The phone's Keychain or Keystore in memory, as FlutterSecureStorage.setMockInitialValues keeps it, which also keeps
/// the options each call asked it with: what flutter_secure_storage hands the platform it runs on.
class KeychainCalls extends TestFlutterSecureStoragePlatform {
  KeychainCalls._() : super({});

  /// A store of nothing in the storage's place, until the next one or setMockInitialValues.
  static KeychainCalls install() => FlutterSecureStoragePlatform.instance = KeychainCalls._();

  /// Each call's options, in order.
  final options = <Map<String, String>>[];

  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) {
    this.options.add(options);
    return super.write(key: key, value: value, options: options);
  }

  @override
  Future<String?> read({required String key, required Map<String, String> options}) {
    this.options.add(options);
    return super.read(key: key, options: options);
  }

  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) {
    this.options.add(options);
    return super.containsKey(key: key, options: options);
  }

  @override
  Future<void> delete({required String key, required Map<String, String> options}) {
    this.options.add(options);
    return super.delete(key: key, options: options);
  }

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) {
    this.options.add(options);
    return super.readAll(options: options);
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) {
    this.options.add(options);
    return super.deleteAll(options: options);
  }
}
