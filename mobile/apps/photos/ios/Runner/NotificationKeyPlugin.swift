import Flutter
import Foundation
import Security

final class NotificationKeyPlugin: NSObject, FlutterPlugin {
  private static let queue = DispatchQueue(label: "io.ente.frame.notifications.keys")

  static func register(in registry: FlutterPluginRegistry) {
    if let registrar = registry.registrar(forPlugin: "NotificationKeyPlugin") {
      register(with: registrar)
    }
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: NotificationKeyStore.service, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(NotificationKeyPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    Self.queue.async {
      do {
        let arguments = call.arguments as? [String: Any] ?? [:]
        if call.method == "getPrivateKey" || call.method == "setPrivateKey" {
          guard let token = arguments["sessionToken"] as? String else {
            throw NotificationKeyStore.StoreError.invalidRecord
          }
          try Self.validateSession(token)
        }
        let response: Any?
        switch call.method {
        case "getPrivateKey":
          let recipient = try NotificationKeyStore.readForPreparation()
          response = recipient?.privateKey
        case "setPrivateKey":
          guard let privateKey = arguments["privateKey"] as? String else {
            throw NotificationKeyStore.StoreError.invalidRecord
          }
          try NotificationKeyStore.write(privateKey: privateKey)
          response = nil
        case "clear":
          NotificationKeyStore.clearPreferences()
          try NotificationKeyStore.clear()
          response = nil
        case "sharePreferences":
          NotificationKeyStore.sharePreferences()
          response = nil
        default:
          DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
          return
        }
        DispatchQueue.main.async { result(response) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "notification_key_store", message: "\(error)", details: nil))
        }
      }
    }
  }

  private static func validateSession(_ token: String) throws {
    let stateKey = "flutter.session_token_state"
    guard UserDefaults.standard.string(forKey: stateKey) == "secure" else {
      throw NotificationKeyStore.StoreError.invalidRecord
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "flutter_secure_storage_service",
      kSecAttrAccount as String: "token",
      kSecAttrSynchronizable as String: false,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      throw NotificationKeyStore.StoreError.invalidRecord
    }
    guard status == errSecSuccess else {
      throw NotificationKeyStore.StoreError.keychain(status)
    }
    guard let data = result as? Data,
      String(data: data, encoding: .utf8) == token,
      UserDefaults.standard.string(forKey: stateKey) == "secure" else {
      throw NotificationKeyStore.StoreError.invalidRecord
    }
  }
}
