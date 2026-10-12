import Foundation
import CryptoKit

/// SHA-256 十六进制。CryptoKit 在 iOS 与 macOS 上都有，所以它属于「可跨平台的核心逻辑」，
/// 不需要在 DayCueApp 里另写一份。
public enum SHA256Hex {
    public static func digest(_ string: String) -> String {
        digest(Data(string.utf8))
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func fileDigest(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return digest(data)
    }
}

/// 幂等键。
///
/// 关键约束：必须是确定性的，同一个 (操作, 参数) 每次都得到同一个键。
/// 绝不能用 UUID 随机数——那样每次点按都会生成新键，唯一索引就形同虚设，
/// 外部提醒事项会出现重复条目。
public enum IdempotencyKey {

    /// 契约指定的算法："create_reminder:" + taskId + ":" + listId 的 SHA-256 十六进制前 32 位。
    public static func createReminder(taskId: String, listId: String) -> String {
        truncatedDigest("create_reminder:" + taskId + ":" + listId)
    }

    /// 删除操作用 externalId 而不是 listId 参与计算：同一个任务可能因为换清单而重新绑定，
    /// 删除针对的是「那一条外部对象」，不是「那个清单」。
    public static func deleteReminder(taskId: String, externalId: String) -> String {
        truncatedDigest("delete_reminder:" + taskId + ":" + externalId)
    }

    /// 解析操作用内容指纹参与计算，这样「同一份文本重试」不会重复排队，
    /// 而「用户改了文本再解析」会得到新的键，属于一次新的解析。
    public static func extractCapture(captureId: String, contentFingerprint: String) -> String {
        truncatedDigest("extract_capture:" + captureId + ":" + contentFingerprint)
    }

    /// 前 32 位十六进制 = 128 bit，对单机幂等去重来说碰撞概率可以忽略，同时比全量 64 位短一半。
    public static func truncatedDigest(_ material: String) -> String {
        String(SHA256Hex.digest(material).prefix(32))
    }
}
