import Foundation
import Security

struct EngineMatch: Decodable {
    let start: Int
    let end: Int
    let rule: String
    let score: Double
    let hash: String
}

final class CoreEngine {
    private let handle: OpaquePointer
    init(config: String = "{}") throws {
        var key = try Self.installationKey()
        defer { _ = key.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        guard let engine = config.withCString({ config in key.withUnsafeBytes { veil_engine_new(config, $0.bindMemory(to: UInt8.self).baseAddress) } }) else {
            throw NSError(domain: "Veil", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not load detection rules."])
        }
        handle = engine
    }
    deinit { veil_engine_free(handle) }
    func scan(_ text: String, title: String = "", path: String = "", ocr: Bool = false) throws -> [EngineMatch] {
        let context = String(data: try! JSONSerialization.data(withJSONObject: ["title": title, "path": path, "ocr": ocr]), encoding: .utf8)!
        var input = Array(text.replacingOccurrences(of: "\0", with: " ").utf8CString)
        defer { _ = input.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        guard let output = input.withUnsafeBufferPointer({ bytes in context.withCString { veil_engine_scan(handle, bytes.baseAddress, $0) } }) else { throw Self.scanError() }
        defer { veil_string_free(output) }
        struct Response: Decodable { let matches: [EngineMatch]; let error: String? }
        let bytes = Data(bytes: output, count: strlen(output))
        let response = try JSONDecoder().decode(Response.self, from: bytes)
        guard response.error == nil else { throw Self.scanError() }
        return response.matches
    }
    private static func scanError() -> NSError {
        NSError(domain: "Veil", code: 2, userInfo: [NSLocalizedDescriptionKey: "Secret detection failed. The feed is paused."])
    }
    static func validate(_ json: String) -> String? {
        guard let result = json.withCString({ veil_config_validate($0) }) else { return "Invalid rules." }
        defer { veil_string_free(result) }
        let data = Data(bytes: result, count: strlen(result))
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return object?["valid"] as? Bool == true ? nil : (object?["error"] as? String ?? "Invalid rules.")
    }
    private static func installationKey() throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.henrylinlin.veil", kSecAttrAccount as String: "allowlist-key"]
        var search = query
        search[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &value)
        if status == errSecSuccess, let data = value as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound else { throw keyError(status) }
        var data = Data(count: 32)
        let random = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard random == errSecSuccess else { throw keyError(random) }
        var entry = query
        entry[kSecValueData as String] = data
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(entry as CFDictionary, nil)
        guard added == errSecSuccess else { throw keyError(added) }
        return data
    }
    private static func keyError(_ code: OSStatus) -> NSError {
        NSError(domain: "Veil", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Veil could not access its private allowlist key in Keychain (\(code))."])
    }
}
