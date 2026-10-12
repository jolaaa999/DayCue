package com.daycue.android.data.local

import android.database.sqlite.SQLiteConstraintException
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.daycue.android.data.local.entity.CourseInstanceRecord
import com.daycue.android.data.local.entity.FollowUpRecord
import com.daycue.android.data.local.entity.NoteRecord
import com.daycue.android.data.local.entity.OutboxOperationRecord
import com.daycue.android.data.local.entity.TaskRecord
import com.daycue.android.domain.model.CourseInstanceStatus
import com.daycue.android.domain.model.DueKind
import com.daycue.android.domain.model.OutboxState
import com.daycue.android.domain.model.TaskStatus
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.time.Instant

/**
 * 数据层的**仪器测试**：用内存库验证「约束真的起作用」。
 *
 * 这些用例需要设备或模拟器（./gradlew :app:connectedDebugAndroidTest）。
 * 之所以要单独测，是因为设备端的约束（唯一索引、外键、部分写入）在 JVM 上测不出来，
 * 而它们恰恰是「重放一次就把数据写坏」这类问题的最后一道防线。
 */
@RunWith(AndroidJUnit4::class)
class DayCueDaoTest {

    private lateinit var database: DayCueDatabase

    private val now: Instant = Instant.parse("2026-10-12T02:00:00Z")

    @Before
    fun setUp() {
        database = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext(),
            DayCueDatabase::class.java,
        )
            // 允许主线程查询：测试要直接读原始表来验证「软删除后行还在」，用协程包一层没有额外收益。
            .allowMainThreadQueries()
            .build()
    }

    @After
    fun tearDown() {
        database.close()
    }

    private fun outbox(id: String, key: String, state: OutboxState = OutboxState.PENDING) = OutboxOperationRecord(
        id = id,
        entityType = "task",
        entityId = "task_1",
        op = "create_reminder",
        idempotencyKey = key,
        createdAt = now,
        updatedAt = now,
        state = state,
    )

    @Test
    fun outboxEnqueueIsIdempotentOnIdempotencyKey() = runTest {
        val first = database.outboxDao().enqueue(outbox("op_1", "key_a"))
        // 同一个幂等键再排一次必须被静默忽略：这是「用户连点两次」和「worker 重放」的共同防线。
        val second = database.outboxDao().enqueue(outbox("op_2", "key_a"))

        assertTrue(first > 0)
        assertEquals(-1L, second)
        assertEquals(1, rawCount("SELECT COUNT(*) FROM outbox_operation WHERE idempotency_key = 'key_a'"))
    }

    @Test
    fun outboxClaimIsSingleWinner() = runTest {
        database.outboxDao().enqueue(outbox("op_1", "key_a"))

        // 两个 worker 同时醒来时，只有抢先成功的那一个能执行。
        assertEquals(1, database.outboxDao().markRunning("op_1", now))
        assertEquals(0, database.outboxDao().markRunning("op_1", now))
    }

    @Test
    fun unknownOutcomeIsNotRetriedAsPending() = runTest {
        database.outboxDao().enqueue(outbox("op_1", "key_a"))
        database.outboxDao().markRunning("op_1", now)
        // 结果未知：不能当作「确定失败」再重试，否则可能重复创建外部提醒。
        database.outboxDao().markFailed("op_1", OutboxState.UNKNOWN, "连接中断", null, now)

        assertTrue(database.outboxDao().listExecutable(now, 10).isEmpty())
        assertEquals(OutboxState.UNKNOWN, database.outboxDao().findById("op_1")?.state)
    }

    @Test
    fun followUpIsUniquePerCourseInstance() = runTest {
        database.followUpDao().insert(
            FollowUpRecord(
                id = "follow_up_1",
                courseInstanceId = "instance_1",
                courseId = "course_1",
                scheduledAtUtc = now,
                createdAt = now,
                updatedAt = now,
            ),
        )

        var violated = false
        try {
            database.followUpDao().insert(
                FollowUpRecord(
                    id = "follow_up_2",
                    courseInstanceId = "instance_1",
                    courseId = "course_1",
                    scheduledAtUtc = now,
                    createdAt = now,
                    updatedAt = now,
                ),
            )
        } catch (e: SQLiteConstraintException) {
            violated = true
        }
        // 唯一索引必须真的生效：否则「稍后提醒」会变成两条并行的追问。
        assertTrue(violated)
    }

    @Test
    fun courseInstanceInsertIgnoringExistingIsIdempotent() = runTest {
        val instance = CourseInstanceRecord(
            id = "instance_1",
            courseId = "course_1",
            ruleId = "rule_1",
            startsAtUtc = now,
            endsAtUtc = now.plusSeconds(5400),
            timezone = "Asia/Shanghai",
            status = CourseInstanceStatus.SCHEDULED,
            createdAt = now,
            updatedAt = now,
        )

        assertTrue(database.courseInstanceDao().insertIgnoringExisting(instance) > 0)
        // 反复展开同一周不能产生重复课程。
        assertEquals(-1L, database.courseInstanceDao().insertIgnoringExisting(instance))
        assertEquals(1, rawCount("SELECT COUNT(*) FROM course_instance"))
    }

    @Test
    fun softDeletedNoteDisappearsFromQueriesButSurvivesInStorage() = runTest {
        database.noteDao().insert(
            NoteRecord(
                id = "note_1",
                title = "PV 操作",
                body = "还是没理解",
                createdAt = now,
                updatedAt = now,
            ),
        )
        database.noteDao().softDelete("note_1", now)

        assertNull(database.noteDao().findById("note_1"))
        // 行必须还在：物理删除会让「外部还在、本地没了」无法解释。
        assertEquals(1, rawCount("SELECT COUNT(*) FROM note"))
        assertTrue(database.noteDao().search("%PV%", 10).isEmpty())
    }

    @Test
    fun taskWithDateDueMustNotCarryUtcInstant() = runTest {
        val consistent = TaskRecord(
            id = "task_1",
            title = "交实验报告",
            dueKind = DueKind.DATE,
            dueLocal = "2026-10-16",
            timezone = "Asia/Shanghai",
            createdAt = now,
            updatedAt = now,
        )
        assertTrue(consistent.hasConsistentDue)

        val inconsistent = consistent.copy(id = "task_2", dueUtc = now)
        // 日期型截止日被补上 UTC 时刻就是 bug 的来源，这条断言把它钉死在数据模型层。
        assertFalse(inconsistent.hasConsistentDue)
    }

    @Test
    fun taskSoftDeleteHidesItFromOpenList() = runTest {
        database.taskDao().insert(
            TaskRecord(
                id = "task_1",
                title = "交实验报告",
                status = TaskStatus.OPEN,
                timezone = "Asia/Shanghai",
                createdAt = now,
                updatedAt = now,
            ),
        )
        database.taskDao().softDelete("task_1", now)

        assertTrue(database.taskDao().listByStatus(TaskStatus.OPEN).isEmpty())
        assertEquals(1, rawCount("SELECT COUNT(*) FROM task"))
    }

    private fun rawCount(sql: String): Int =
        database.openHelper.readableDatabase.query(sql).use { cursor ->
            if (cursor.moveToFirst()) cursor.getInt(0) else 0
        }
}
