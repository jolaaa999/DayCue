package com.daycue.android.domain.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 三方对账。
 *
 * 用 Map<SyncField, String?> 直接构造三方状态，不碰数据库：
 * 这里要验证的是「哪一边改了、该由谁赢」，不是 SQL。
 */
class SyncReconcilerTest {

    private val snapshot = mapOf(
        SyncField.TITLE to "写作业",
        SyncField.STATUS to "open",
        SyncField.DUE to "2026-10-16",
        SyncField.DETAIL to null,
    )

    private fun external(fields: Map<SyncField, String?>, exists: Boolean = true) =
        ExternalProjection(available = true, exists = exists, fields = fields)

    @Test
    fun externalOnlyChangeIsAdopted() {
        // 用户在系统待办里勾掉了这条任务：必须被采纳，不能让 App 一直显示未完成。
        val local = snapshot
        val result = SyncReconciler.reconcile(
            snapshot = snapshot,
            local = local,
            external = external(mapOf(SyncField.STATUS to "done", SyncField.TITLE to "写作业")),
        )
        assertEquals(FieldOutcome.ExternalAdopted("done"), result.outcomes[SyncField.STATUS])
        assertFalse(result.requiresUserDecision)
    }

    @Test
    fun localOnlyChangeIsKeptForPush() {
        val local = snapshot + (SyncField.TITLE to "写实验报告")
        val result = SyncReconciler.reconcile(
            snapshot = snapshot,
            local = local,
            external = external(mapOf(SyncField.TITLE to "写作业")),
        )
        assertEquals(FieldOutcome.LocalKept("写实验报告"), result.outcomes[SyncField.TITLE])
    }

    @Test
    fun bothChangedToDifferentValuesBecomesConflict() {
        val local = snapshot + (SyncField.TITLE to "写实验报告")
        val result = SyncReconciler.reconcile(
            snapshot = snapshot,
            local = local,
            external = external(mapOf(SyncField.TITLE to "写实验三")),
        )
        assertEquals(FieldOutcome.Conflict("写实验报告", "写实验三"), result.outcomes[SyncField.TITLE])
        assertTrue(result.requiresUserDecision)
        assertEquals(listOf(SyncField.TITLE), result.conflicts)
    }

    @Test
    fun bothChangedToSameValueNeedsNoAction() {
        val local = snapshot + (SyncField.TITLE to "写实验报告")
        val result = SyncReconciler.reconcile(
            snapshot = snapshot,
            local = local,
            external = external(mapOf(SyncField.TITLE to "写实验报告")),
        )
        assertEquals(FieldOutcome.Agreed("写实验报告"), result.outcomes[SyncField.TITLE])
        assertFalse(result.requiresUserDecision)
    }

    @Test
    fun identicalThreeWayStateIsUnchanged() {
        val result = SyncReconciler.reconcile(
            snapshot = snapshot,
            local = snapshot,
            external = external(snapshot),
        )
        assertTrue(result.outcomes.values.all { it == FieldOutcome.Unchanged })
        assertEquals("本地与外部一致", result.summary)
    }

    @Test
    fun fieldsNotProvidedByExternalAreNotCompared() {
        // 外部这次没查到清单信息：不能当成「清单被清空了」。
        val result = SyncReconciler.reconcile(
            snapshot = snapshot,
            local = snapshot + (SyncField.LIST to "list_1"),
            external = external(mapOf(SyncField.TITLE to "写作业")),
        )
        assertEquals(FieldOutcome.Unchanged, result.outcomes[SyncField.LIST])
    }

    @Test
    fun externalDeletionIsReportedButLocalRecordSurvives() {
        val result = SyncReconciler.reconcile(
            snapshot = snapshot,
            local = snapshot,
            external = external(emptyMap(), exists = false),
        )
        assertTrue(result.externalDeleted)
        assertTrue(result.requiresUserDecision)
        // 外部删了不等于用户想删本地：只报告，交用户决定归档或重建。
        assertEquals(FieldOutcome.Unchanged, result.outcomes[SyncField.TITLE])
        assertTrue(result.summary.contains("保留"))
    }

    @Test
    fun deletionOfNeverBoundEntityDoesNotAskTheUser() {
        val result = SyncReconciler.reconcile(
            snapshot = mapOf(
                SyncField.TITLE to null,
                SyncField.STATUS to null,
                SyncField.DUE to null,
                SyncField.DETAIL to null,
            ),
            local = mapOf(SyncField.TITLE to "新任务"),
            external = external(emptyMap(), exists = false),
        )
        assertTrue(result.externalDeleted)
        assertFalse(result.requiresUserDecision)
    }

    @Test
    fun unavailableExternalQueryNeverMergesAnything() {
        val result = SyncReconciler.reconcile(
            snapshot = snapshot,
            local = snapshot + (SyncField.STATUS to "done"),
            external = ExternalProjection(available = false, exists = false),
        )
        assertTrue(result.requiresUserDecision)
        assertFalse(result.externalDeleted)
        assertTrue(result.outcomes.values.all { it == FieldOutcome.Unchanged })
    }

    @Test
    fun reconciliationIsIdempotentAfterApplyingAdoptedValues() {
        val local = snapshot
        val first = SyncReconciler.reconcile(
            snapshot = snapshot,
            local = local,
            external = external(mapOf(SyncField.STATUS to "done", SyncField.TITLE to "写作业")),
        )
        val merged = SyncReconciler.applyToLocal(local, first)

        val second = SyncReconciler.reconcile(
            snapshot = merged,
            local = merged,
            external = external(mapOf(SyncField.STATUS to "done", SyncField.TITLE to "写作业")),
        )
        // 后台每次唤醒都会跑对账；不幂等的话会不断产生假冲突。
        assertTrue(second.outcomes.values.all { it == FieldOutcome.Unchanged })
        assertFalse(second.requiresUserDecision)
    }

    @Test
    fun applyToLocalOnlyWritesAdoptedAndAgreedValues() {
        val local = snapshot + (SyncField.TITLE to "本地标题")
        val result = SyncReconciler.reconcile(
            snapshot = snapshot,
            local = local,
            external = external(mapOf(SyncField.TITLE to "外部标题", SyncField.STATUS to "done")),
        )
        val merged = SyncReconciler.applyToLocal(local, result)
        // 标题是冲突，保持本地不动；状态是外部单方面改动，采纳。
        assertEquals("本地标题", merged[SyncField.TITLE])
        assertEquals("done", merged[SyncField.STATUS])
    }

    @Test
    fun conflictSummaryCountsFields() {
        val local = snapshot + mapOf(SyncField.TITLE to "A", SyncField.DUE to "2026-10-20")
        val result = SyncReconciler.reconcile(
            snapshot = snapshot,
            local = local,
            external = external(mapOf(SyncField.TITLE to "B", SyncField.DUE to "2026-10-21")),
        )
        assertEquals(2, result.conflicts.size)
        assertTrue(result.summary.contains("2"))
    }
}
