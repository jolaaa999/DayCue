package com.daycue.android.domain.sync

/**
 * 参与三方比较的字段。
 *
 * 只列「用户可能在任何一端改」的字段。App 私有的扩展语义（来源、证据、记忆关联）
 * 不参与比较，否则会把外部不认识的东西当成冲突。
 */
enum class SyncField(val key: String, val displayName: String) {
    TITLE("title", "标题"),
    DETAIL("detail", "备注"),
    STATUS("status", "完成状态"),
    DUE("due_utc", "截止时间"),
    REMIND("remind_utc", "提醒时间"),
    LIST("list_id", "所属清单"),
    LOCATION("location", "地点"),
}

/** 外部投影。available=false 表示这次查询本身没成功，绝不能当成「外部删除了」。 */
data class ExternalProjection(
    val available: Boolean,
    val exists: Boolean,
    val fields: Map<SyncField, String?> = emptyMap(),
)

sealed interface FieldOutcome {
    /** 三方一致，什么都不用做。 */
    object Unchanged : FieldOutcome

    /** 只有本地变了：把本地值推给外部。 */
    data class LocalKept(val value: String?) : FieldOutcome

    /** 只有外部变了：写回本地（外部完成、外部改时间都属于这一类）。 */
    data class ExternalAdopted(val value: String?) : FieldOutcome

    /** 两边都改了，但改成了同一个值：无需动作。 */
    data class Agreed(val value: String?) : FieldOutcome

    /** 同一字段双方改成不同值：保留冲突，交给用户选。 */
    data class Conflict(val local: String?, val external: String?) : FieldOutcome
}

data class ReconciliationResult(
    val outcomes: Map<SyncField, FieldOutcome>,
    val externalDeleted: Boolean,
    /** 需要用户出面（冲突、外部删除、查询失败）。界面据此决定是否弹确认。 */
    val requiresUserDecision: Boolean,
    val summary: String,
) {
    val conflicts: List<SyncField>
        get() = outcomes.filterValues { it is FieldOutcome.Conflict }.keys.toList()
}

/**
 * 三方对账：上次同步快照 / 本地当前值 / 外部当前值。
 *
 * 为什么不是「最后写入者获胜」：用户可能在苹果端或 Android 端手工改过字段，
 * 单一时间戳合并会静默覆盖其中一次人工修改。设计文档 9.2 要求同字段双方变更时保留冲突并让用户选。
 *
 * 幂等性：把 ExternalAdopted 的结果写回本地、并刷新快照后再跑一次，所有字段都会变成 Unchanged。
 * 这是「对账可以反复跑」的前提，否则后台每次唤醒都会产生一批假冲突。
 */
object SyncReconciler {

    fun reconcile(
        snapshot: Map<SyncField, String?>,
        local: Map<SyncField, String?>,
        external: ExternalProjection,
    ): ReconciliationResult {
        // 查询本身失败：既不能当成删除，也不能当成没变，只能交给用户/下次重试。
        if (!external.available) {
            return ReconciliationResult(
                outcomes = SyncField.entries.associateWith { FieldOutcome.Unchanged },
                externalDeleted = false,
                requiresUserDecision = true,
                summary = "外部查询未成功，本次不做任何合并",
            )
        }

        if (!external.exists) {
            val wasBound = snapshot.values.any { it != null }
            return ReconciliationResult(
                outcomes = SyncField.entries.associateWith { FieldOutcome.Unchanged },
                externalDeleted = true,
                requiresUserDecision = wasBound,
                // 外部消失不等于用户想删掉这条任务：只报告，不自动删除本地记录。
                summary = if (wasBound) "外部项目已删除，本地记录保留，等待用户决定归档或重建" else "外部没有对应项目",
            )
        }

        val outcomes = LinkedHashMap<SyncField, FieldOutcome>()
        for (field in SyncField.entries) {
            if (!external.fields.containsKey(field)) {
                // 外部这次没有提供这个字段（例如清单信息没查）：不参与比较。
                outcomes[field] = FieldOutcome.Unchanged
                continue
            }
            val snap = snapshot[field]
            val loc = local[field]
            val ext = external.fields[field]
            val localChanged = loc != snap
            val externalChanged = ext != snap

            outcomes[field] = when {
                !localChanged && !externalChanged -> FieldOutcome.Unchanged
                localChanged && !externalChanged -> FieldOutcome.LocalKept(loc)
                !localChanged && externalChanged -> FieldOutcome.ExternalAdopted(ext)
                loc == ext -> FieldOutcome.Agreed(loc)
                else -> FieldOutcome.Conflict(local = loc, external = ext)
            }
        }

        val conflicts = outcomes.filterValues { it is FieldOutcome.Conflict }.keys
        val summary = when {
            conflicts.isNotEmpty() -> "有 " + conflicts.size + " 个字段双方都改过且不一致，需要你选择保留哪一个"
            outcomes.values.any { it is FieldOutcome.ExternalAdopted } -> "已采用外部的新值"
            outcomes.values.any { it is FieldOutcome.LocalKept } -> "本地有新改动，等待推送到外部"
            else -> "本地与外部一致"
        }

        return ReconciliationResult(
            outcomes = outcomes,
            externalDeleted = false,
            requiresUserDecision = conflicts.isNotEmpty(),
            summary = summary,
        )
    }

    /**
     * 把对账结论应用到本地字段。
     *
     * 只做 ExternalAdopted 与 Agreed——冲突字段原样保留，LocalKept 也不动本地
     * （本地已经是新值）。这个函数不产生任何外部副作用，方便在后台作业里先算后写。
     */
    fun applyToLocal(local: Map<SyncField, String?>, result: ReconciliationResult): Map<SyncField, String?> {
        val merged = LinkedHashMap(local)
        for ((field, outcome) in result.outcomes) {
            when (outcome) {
                is FieldOutcome.ExternalAdopted -> merged[field] = outcome.value
                is FieldOutcome.Agreed -> merged[field] = outcome.value
                else -> Unit
            }
        }
        return merged
    }
}
