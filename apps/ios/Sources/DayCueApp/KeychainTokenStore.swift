import Foundation
import Security

/// Bearer Token 只进 Keychain。
///
/// 不进 UserDefaults 的原因很直接：UserDefaults 是明文 plist，
/// 备份、日志、越狱环境都能直接读到，属于"方便但错误"的存储位置。
struct KeychainTokenStore {

    private let service: String
    private let account: String

    init(service: String = "com.daycue.apikey", account: String = "bearer-token") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    @discardableResult
    func save(_ token: String) -> Bool {
        // 先删再写：SecItemUpdate 在条目不存在时返回 errSecItemNotFound，
        // 与其分两路判断，不如统一成"删除后新增"，逻辑只有一条。
        SecItemDelete(baseQuery as CFDictionary)

        guard !token.isEmpty else { return true }

        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        // AfterFirstUnlock：设备重启后首次解锁即可读取，同时不会在锁屏状态下暴露。
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
