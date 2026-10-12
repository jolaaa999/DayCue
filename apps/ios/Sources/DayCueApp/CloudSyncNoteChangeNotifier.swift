import Foundation
import DayCueCore

/// 把 Core 的「本地笔记有变更」翻译成云同步入队。
///
/// 为什么要单独一个适配器：
///   - NoteWriteCoordinator 在 DayCueCore 里，是非隔离的；CloudSyncService 是 @MainActor，
///     直接让 Core 持有它会让 Core 依赖 SwiftUI/MainActor 的运行时假设；
///   - noteLocalChange() 本身只是 2 秒防抖后的入队，不阻塞写入路径，所以这里
///     显式跳一次 @MainActor 再调用即可，Core 侧保持同步、可测试。
final class CloudSyncNoteChangeNotifier: NoteLocalChangeReporting {

    /// 弱引用：同步服务由 AppContainer 持有，通知口不应该反过来决定它的生命周期。
    private weak var cloudSync: CloudSyncService?

    init(cloudSync: CloudSyncService) {
        self.cloudSync = cloudSync
    }

    func noteLocalChange() {
        Task { @MainActor [weak self] in
            self?.cloudSync?.noteLocalChange()
        }
    }
}
