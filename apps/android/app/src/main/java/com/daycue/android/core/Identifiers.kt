package com.daycue.android.core

import java.security.MessageDigest
import java.util.UUID

/**
 * 业务标识统一走 UUID 字符串。
 *
 * 做成对象方法而不是到处 new，是为了让「大写」这条约定只有一个落点：
 * iOS 的 UUID().uuidString 是大写，双端 id 只会被比对、不会被解析，格式必须一致。
 */
object DayCueId {
    fun new(): String = UUID.randomUUID().toString().uppercase()
}

/**
 * 确定性幂等键。与 iOS `IdempotencyKey` 逐位对齐。
 *
 * 关键约束：同一个 (操作, 参数) 每次必须得到同一个键。
 * 用随机 UUID 会让「重试」变成「新建」——用户在外部待办里看到两条一样的作业。
 */
object IdempotencyKey {

    /** 契约指定算法：create_reminder:<taskId>:<listId> 的 SHA-256 十六进制前 32 位。 */
    fun createReminder(taskId: String, listId: String): String =
        truncatedDigest("create_reminder:" + taskId + ":" + listId)

    /** 删除针对「那一条外部对象」，所以用 externalId 而不是 listId。 */
    fun deleteReminder(taskId: String, externalId: String): String =
        truncatedDigest("delete_reminder:" + taskId + ":" + externalId)

    /** 解析用内容指纹：同一份文本重试不重复排队，用户改了文本则算一次新解析。 */
    fun extractCapture(captureId: String, contentFingerprint: String): String =
        truncatedDigest("extract_capture:" + captureId + ":" + contentFingerprint)

    /**
     * 课表展开的实例 id：同一个规则 + 同一个开始时刻永远得到同一个 id。
     * 有了它，「重新展开课表」才不会产生重复的课程实例，课后追问也不会被重复安排。
     */
    fun courseInstance(ruleId: String, startsAtUtc: String): String =
        truncatedDigest("course_instance:" + ruleId + ":" + startsAtUtc)

    /** 前 32 位十六进制 = 128 bit，单机去重足够，同时比全量短一半。 */
    fun truncatedDigest(material: String): String = Sha256.hex(material).take(32)
}

/** SHA-256。Android 平台自带 MessageDigest，不需要引入 keccak/bouncycastle 这类库。 */
object Sha256 {
    fun hex(text: String): String = hex(text.toByteArray(Charsets.UTF_8))

    fun hex(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        val builder = StringBuilder(digest.size * 2)
        for (byte in digest) {
            val value = byte.toInt() and 0xFF
            builder.append(HEX[value ushr 4])
            builder.append(HEX[value and 0x0F])
        }
        return builder.toString()
    }

    private const val HEX = "0123456789abcdef"
}
