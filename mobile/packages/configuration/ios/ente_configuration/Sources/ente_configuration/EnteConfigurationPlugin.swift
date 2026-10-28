import Flutter
import Foundation
import Security

public class EnteConfigurationPlugin: NSObject, FlutterPlugin {
    private let queue = DispatchQueue(label: "io.ente.configuration.secure_storage")

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "io.ente.configuration/secure_storage",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(EnteConfigurationPlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard ["read", "delete", "deleteAll"].contains(call.method) else {
            result(FlutterMethodNotImplemented)
            return
        }
        guard let args = call.arguments as? [String: Any],
              let options = args["options"] as? [String: String],
              call.method == "deleteAll" || args["key"] is String else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing key or options", details: nil))
            return
        }

        queue.async {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrSynchronizable as String: Bool(options["synchronizable"] ?? "false") ?? false,
            ]
            if call.method != "deleteAll" { query[kSecAttrAccount as String] = args["key"] }
            query[kSecAttrService as String] = options["accountName"]
            query[kSecAttrAccessGroup as String] = options["groupId"]
            let response: Any?
            if call.method == "read" {
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var value: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &value)
                if status == errSecItemNotFound {
                    response = nil
                } else if status != errSecSuccess {
                    response = FlutterError(code: "KEYCHAIN_READ_ERROR", message: "Keychain read failed", details: status)
                } else if let data = value as? Data, let text = String(data: data, encoding: .utf8) {
                    response = text
                } else {
                    response = FlutterError(code: "KEYCHAIN_READ_ERROR", message: "Invalid Keychain data", details: nil)
                }
            } else {
                let status = SecItemDelete(query as CFDictionary)
                response = status == errSecSuccess || status == errSecItemNotFound
                    ? nil
                    : FlutterError(code: "KEYCHAIN_DELETE_ERROR", message: "Keychain deletion failed", details: status)
            }
            DispatchQueue.main.async { result(response) }
        }
    }
}
