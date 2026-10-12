import Foundation
import SwiftUI

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
        self.apiBaseURL = store.setting(DayCueStore.SettingKey.apiBaseURL) ?? DayCueStore.defaultAPIBaseURL
        self.bearerToken = keychain.read() ?? ""
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
    /// 写设置失败不应该让界面崩溃：设置项都可重建，失败了下次仍能改。
    func setSettingSafely(_ key: String, value: String?) {
        do { try setSetting(key, value: value) } catch {
            // 这里刻意不抛错，避免一次写入失败把整个设置页打断。
        }
    }
}
