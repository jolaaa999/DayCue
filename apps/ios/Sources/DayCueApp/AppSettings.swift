import Foundation
import SwiftUI
import DayCueCore

/// 应用偏好。
///
/// 非敏感项落在 SQLite 的 app_setting 表（跟着数据一起备份、一起清理），
/// 只有 Bearer Token 走 Keychain。
@MainActor
final class AppSettings: ObservableObject {

    private let store: DayCueStore
    private let keychain: KeychainTokenStore

    @Published var apiBaseURL: String {
        didSet { store.setSettingSafely(DayCueStore.SettingKey.apiBaseURL, value: apiBaseURL) }
    }

    @Published var bearerToken: String {
        didSet { keychain.save(bearerToken) }
    }

    /// 默认关闭：先预览再确认。打开后解析完成即直接建任务。
    @Published var autoCreateEnabled: Bool {
        didSet {
            store.setSettingSafely(DayCueStore.SettingKey.autoCreateEnabled, value: autoCreateEnabled ? "1" : "0")
        }
    }

    /// 用户选中的默认提醒清单。未选择时保持 nil，不得替用户随便挑一个。
    @Published private(set) var defaultListId: String?
    @Published private(set) var defaultListTitle: String?

    init(store: DayCueStore, keychain: KeychainTokenStore = KeychainTokenStore()) {
        self.store = store
        self.keychain = keychain
        // 地址：没配过、或配的是回环地址（真机上等于"连手机自己"）时，落到构建期默认值。
        // 回环判定和 Android 端一致，避免同一份数据在两端表现不一样。
        let storedURL = store.setting(DayCueStore.SettingKey.apiBaseURL)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLoopback = storedURL.map { AppSettings.isLoopback($0) } ?? false
        if storedURL == nil || storedURL == "" || isLoopback {
            self.apiBaseURL = DayCueStore.defaultAPIBaseURL
            store.setSettingSafelyForInit(DayCueStore.SettingKey.apiBaseURL, value: DayCueStore.defaultAPIBaseURL)
        } else {
            self.apiBaseURL = storedURL!
        }

        // 令牌：Keychain 里没有时用构建期注入的值（Info.plist 的 DayCueDefaultToken）。
        // 自用构建固定指向一台服务器，令牌必须和服务器一致；不预置的话第一次启动必然一片 401。
        let storedToken = keychain.read() ?? ""
        if storedToken.isEmpty, let seeded = Bundle.main.object(forInfoDictionaryKey: "DayCueDefaultToken") as? String {
            let trimmed = seeded.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                _ = keychain.save(trimmed)
                self.bearerToken = trimmed
            } else {
                self.bearerToken = ""
            }
        } else {
            self.bearerToken = storedToken
        }
        self.autoCreateEnabled = store.boolSetting(DayCueStore.SettingKey.autoCreateEnabled, defaultValue: false)
        self.defaultListId = store.setting(DayCueStore.SettingKey.defaultReminderListId)
        self.defaultListTitle = store.setting(DayCueStore.SettingKey.defaultReminderListTitle)
    }

    func setDefaultList(id: String?, title: String?) {
        defaultListId = id
        defaultListTitle = title
        store.setSettingSafely(DayCueStore.SettingKey.defaultReminderListId, value: id)
        store.setSettingSafely(DayCueStore.SettingKey.defaultReminderListTitle, value: title)
    }

    /// 回环地址判定：127.0.0.1 / localhost / 0.0.0.0 / [::1]，可带端口与路径。
    /// 这些地址在真机上指向设备自身，属于开发残留，启动时会被覆盖成默认地址。
    static func isLoopback(_ url: String) -> Bool {
        let lowered = url.lowercased()
        guard let schemeRange = lowered.range(of: "://") else { return false }
        var rest = String(lowered[schemeRange.upperBound...])
        if let slash = rest.firstIndex(of: "/") { rest = String(rest[..<slash]) }
        let host = rest.split(separator: ":").first.map(String.init) ?? rest
        return ["127.0.0.1", "localhost", "0.0.0.0", "[::1]", "::1"].contains(host)
    }

    var hasUsableBaseURL: Bool {
        !apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 清空本地数据之后重新落盘当前偏好。
    /// 内存里的值仍然有效，但 app_setting 表已经被清掉，不重新写会与库不一致。
    func repersistAfterWipe() {
        store.setSettingSafely(DayCueStore.SettingKey.apiBaseURL, value: apiBaseURL)
        store.setSettingSafely(DayCueStore.SettingKey.autoCreateEnabled, value: autoCreateEnabled ? "1" : "0")
        store.setSettingSafely(DayCueStore.SettingKey.defaultReminderListId, value: defaultListId)
        store.setSettingSafely(DayCueStore.SettingKey.defaultReminderListTitle, value: defaultListTitle)
    }
}

private extension DayCueStore {
    /// 初始化期间写设置用：此时 AppSettings 还没构造完，不能回调到实例方法上。
    func setSettingSafelyForInit(_ key: String, value: String?) {
        do { try setSetting(key, value: value) } catch { }
    }

    /// 写设置失败不应该让界面崩溃：设置项都可重建，失败了下次仍能改。
    func setSettingSafely(_ key: String, value: String?) {
        do { try setSetting(key, value: value) } catch {
            // 这里刻意不抛错，避免一次写入失败把整个设置页打断。
        }
    }
}
