package com.daycue.android.data.local

import androidx.room.testing.MigrationTestHelper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * 迁移的**仪器测试**：在真实 SQLite 上验证已提交 schema 与迁移 DDL。
 *
 * ！！！这些用例需要真机或模拟器：./gradlew :app:connectedDebugAndroidTest
 * 本机（Windows）没有 Android 设备，因此**从未运行过**，只保证能编译。
 * 不要把它当成已通过的验收证据。
 *
 * 为什么没有写「createDatabase(DB, 1) 再升到 2」这个教科书写法：
 * Android 端**从未发布过 version 1**（见 Migrations.kt 的说明），仓库里因此没有 1.json，
 * Room 的 MigrationTestHelper 造 v1 库时必须读到 1.json，读不到会直接抛异常。
 * 硬造一个 v1 建表脚本等于凭空发明历史 schema，那是伪造，不是验证。
 * 将来真的发布 v1 时 KSP 会导出 1.json，届时应补上标准的 1 → 2 用例。
 *
 * 现在这三条覆盖的是同一件事里**只能靠设备证明**的部分：
 * 1. 已提交的 2.json 能被 Room 真正打开（列类型、主键、索引在真实 SQLite 上都成立）；
 * 2. MIGRATION_1_2 的建表 DDL 在真实 SQLite 上可执行、且可重复执行；
 * 3. MIGRATION_2_3 跑完之后，库结构与当前版本的导出 schema 完全一致（由 Room 自己校验）。
 *    第 3 条尤其重要：纯 JVM 的漂移守卫只能比列名集合，
 *    它看不出 NOT NULL / DEFAULT 的差别、类型亲和性问题或索引没建出来，那些只有真库会拒绝。
 */
@RunWith(AndroidJUnit4::class)
class MigrationTest {

    @get:Rule
    val helper: MigrationTestHelper = MigrationTestHelper(
        InstrumentationRegistry.getInstrumentation(),
        DayCueDatabase::class.java,
    )

    private val databaseName = "migration-test.db"

    /** 用已提交的 2.json 建库。建不起来说明导出的 schema 与 Room 的期望已经对不上了。 */
    @Test
    fun committedSchemaVersion2CanBeOpenedByRoom() {
        helper.createDatabase(databaseName, 2).close()
    }

    /**
     * v2 -> v3：真实 SQLite 上跑一遍 MIGRATION_2_3，并让 Room 用它自己的眼睛校验结果。
     *
     * 为什么这条比 JVM 的漂移守卫重要：漂移守卫只能比「列名集合」，
     * 它看不出 NOT NULL 与 DEFAULT 的差别、看不出索引有没有真的建出来。
     * 而 MIGRATION_2_3 用 ADD COLUMN 加 NOT NULL 列，默认值一旦与实体声明的
     * defaultValue 不一致，Room 在真机升级时会直接抛
     * "Migration didn't properly handle: place"，那时用户已经走在升级路径上了。
     *
     * 验证对象是导出 schema 的**目标版本**：2.json 描述升级前的样子，
     * 迁移产物必须与当前版本的导出 schema 完全一致（runMigrationsAndValidate 会补上新的 identity hash）。
     */
    @Test
    fun migration2To3UpgradesToCurrentSchema() {
        helper.runMigrationsAndValidate(databaseName, 3, true, DayCueMigrations.MIGRATION_2_3)
    }

    /**
     * 迁移 DDL 必须在真实 SQLite 上可执行，并且可重复执行。
     *
     * 可重复执行是硬要求：迁移里的建表与建索引全部写成 IF NOT EXISTS，
     * 就是为了让「用户手动恢复过数据库」或「自动化重跑」这类情形不会炸。
     */
    @Test
    fun migrationIsExecutableAndIdempotentOnRealSqlite() {
        val db = helper.createDatabase(databaseName, 2)
        try {
            // 先拿掉迁移负责创建的其中一张表，制造出「迁移还没跑过」的状态。
            db.execSQL("DROP TABLE IF EXISTS note")

            // 第一次执行：应当把表建回来，并且不抛任何异常。
            DayCueMigrations.MIGRATION_1_2.migrate(db)

            // 第二次执行：所有语句都有 IF NOT EXISTS，重复执行必须同样成功。
            DayCueMigrations.MIGRATION_1_2.migrate(db)

            // 建回来的表必须真的可查询，否则只证明了「语句没报错」。
            db.query("SELECT COUNT(*) FROM note").use { cursor ->
                assertTrue("迁移执行后 note 表应当可查询", cursor.moveToFirst())
            }
        } finally {
            db.close()
        }
    }
}
