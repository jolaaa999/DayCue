package com.daycue.android.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 幂等键必须是确定性的：同一个 (操作, 参数) 每次都要得到同一个键。
 *
 * 期望值是用 SHA-256 独立算出来的十六进制前 32 位（与 iOS 的 IdempotencyKey 同算法），
 * 所以这组断言同时钉住了「算法没被改动」和「双端算出来的是同一个键」。
 */
class IdempotencyKeyTest {

    @Test
    fun createReminderMatchesSpecifiedAlgorithm() {
        assertEquals(
            "da52e02cb7739f9cfa5f274b7beaaac6",
            IdempotencyKey.createReminder("task_1", "list_1"),
        )
    }

    @Test
    fun deleteReminderMatchesSpecifiedAlgorithm() {
        assertEquals(
            "e222875a5a65af2d1fdf9cd4e181a9d9",
            IdempotencyKey.deleteReminder("task_1", "ext_9"),
        )
    }

    @Test
    fun extractCaptureMatchesSpecifiedAlgorithm() {
        assertEquals(
            "dc567738fb8f173e2c04b513886873a1",
            IdempotencyKey.extractCapture("capture_1", "fp_abc"),
        )
    }

    @Test
    fun courseInstanceKeyIsStableAcrossCalls() {
        val first = IdempotencyKey.courseInstance("rule_1", "2026-09-07T00:00:00Z")
        val second = IdempotencyKey.courseInstance("rule_1", "2026-09-07T00:00:00Z")
        assertEquals(first, second)
        assertEquals("43990fcd1bb821c8995bac1c2c9a1b07", first)
    }

    @Test
    fun differentInputsProduceDifferentKeys() {
        assertNotEquals(
            IdempotencyKey.createReminder("task_1", "list_1"),
            IdempotencyKey.createReminder("task_1", "list_2"),
        )
        // 同一个任务换清单后重新绑定，删除针对的是「那一条外部对象」，所以键也必须不同。
        assertNotEquals(
            IdempotencyKey.deleteReminder("task_1", "ext_9"),
            IdempotencyKey.deleteReminder("task_1", "list_1"),
        )
    }

    @Test
    fun keysAreTruncatedTo128BitHex() {
        val key = IdempotencyKey.createReminder("t", "l")
        assertEquals(32, key.length)
        assertTrue("必须是十六进制小写", Regex("^[0-9a-f]{32}$").matches(key))
    }

    @Test
    fun sha256HexIsLowerCaseAndFullLength() {
        assertEquals(64, Sha256.hex("abc").length)
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            Sha256.hex("abc"),
        )
    }

    @Test
    fun idsAreUppercaseUuidShaped() {
        val id = DayCueId.new()
        assertEquals(id, id.uppercase())
        assertTrue(Regex("^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$").matches(id))
    }
}
