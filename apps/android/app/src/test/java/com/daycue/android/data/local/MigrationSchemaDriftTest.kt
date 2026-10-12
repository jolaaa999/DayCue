package com.daycue.android.data.local

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * 迁移 DDL 与已提交 Room schema 的漂移守卫。
 *
 * 为什么需要它：Room 只在**运行时**（真机升级时）才会发现「迁移建出来的表和实体对不上」，
 * 报错形如 Migration did not properly handle ...，而那时用户已经在升级路径上了。
 * 这个测试把同一件事提前到构建期的纯 JVM 单元测试里：不需要设备，因此在 Windows 上也能真实执行。
 *
 * 它校验三件独立的事：
 * 1. 迁移改写过的每一张表，在已提交的 schema 里都存在，且列集合完全一致；
 *    列集合 = 迁移里的 CREATE TABLE 列 **并上** 所有 ALTER TABLE ADD COLUMN 的列，
 *    否则「v3 用 ADD COLUMN 加了两列」会被误报成「迁移少了两列」；
 * 2. 已提交 schema 里的每一张表，要么由迁移创建，要么在 v1 基础表白名单里，
 *    这条能在「新加了实体却忘了写迁移」时立刻失败；
 * 3. schema 的版本号与 DayCueDatabase.kt 里声明的 version 一致。
 *
 * 它**不能**替代设备上的 MigrationTestHelper：真实 SQLite 的类型亲和性、索引与主键行为
 * 只有仪器测试能证明。
 */
class MigrationSchemaDriftTest {

    /**
     * v1 就已经存在的表。
     *
     * 背景事实：Android 端**从未发布过 version 1**，所以仓库里没有 1.json，
     * 迁移只描述「v1 之后新增了什么」，这 5 张表就是 v1 的基线。
     * 将来真的发布 v1 时 KSP 会导出 1.json，这份白名单应当随之删除。
     */
    private val v1BaseTables = setOf(
        "capture_item",
        "task",
        "memory_item",
        "outbox_operation",
        "app_setting",
    )

    @Test
    fun migrationCreatesExactlyTheColumnsDeclaredInCommittedSchema() {
        val schema = schemaTables()
        val migration = migrationTables()

        assertTrue("迁移里没有解析出任何建表语句，正则可能失效了", migration.isNotEmpty())

        for ((table, migrationColumns) in migration) {
            val schemaColumns = schema[table]
            assertTrue(
                "迁移里出现了表 " + table + "，但已提交的 schema 里没有这张表：" +
                    "说明迁移建了一张实体里不存在的表，Room 会在真机升级时抛异常。",
                schemaColumns != null,
            )
            if (table in v1BaseTables) {
                // v1 就存在的表（memory_item）在迁移里只有一句 ADD COLUMN，
                // 拿它的建表列来比会必然失败——v1 的建表语句根本不在这个仓库里
                // （Android 端从未发布过 v1，没有 1.json 可导出）。
                // 这 5 张表与实体的对应关系由 Room 自己的 schema 校验负责，不在这里重复。
                continue
            }
            assertEquals(
                "表 " + table + " 的列集合与已提交 schema 不一致（迁移 DDL 必须与实体逐字对应）",
                schemaColumns!!.sorted(),
                migrationColumns.sorted(),
            )
        }
    }

    @Test
    fun everySchemaTableIsEitherCreatedByMigrationOrAKnownV1Table() {
        val schema = schemaTables()
        val migration = migrationTables()

        val unexplained = schema.keys
            .filter { it !in migration }
            .filter { it !in v1BaseTables }
            .sorted()

        assertTrue(
            "这些表出现在已提交 schema 里，但既不是迁移创建的、也不在 v1 白名单中：" +
                unexplained.joinToString("、") +
                "。通常是新加了实体却忘了写 MIGRATION，或忘了登记进白名单。",
            unexplained.isEmpty(),
        )
    }

    @Test
    fun committedSchemaVersionMatchesDeclaredDatabaseVersion() {
        val declared = declaredDatabaseVersion()
        val exported = schemaJson().jsonObject["database"]!!.jsonObject["version"]!!.jsonPrimitive.content.toInt()
        assertEquals(
            "已提交 schema 的版本号与 DayCueDatabase.kt 里声明的 version 不一致：" +
                "两者的差异会让 Room 在启动时直接抛异常。",
            declared,
            exported,
        )
    }

    // ---- 读取与解析 ----

    /** 已提交 schema 的「表名 -> 列名集合」。 */
    private fun schemaTables(): Map<String, Set<String>> {
        val entities = schemaJson().jsonObject["database"]!!.jsonObject["entities"]!!.jsonArray
        return entities.associate { entity ->
            val obj = entity.jsonObject
            val table = obj["tableName"]!!.jsonPrimitive.content
            val columns = obj["fields"]!!.jsonArray.map { it.jsonObject["columnName"]!!.jsonPrimitive.content }
            table to columns.toSet()
        }
    }

    /**
     * 从 Migrations.kt 源码里解析出「迁移改写过的 表名 -> 列名集合」。
     *
     * 两类语句都要读：CREATE TABLE 给出建表时的列，ALTER TABLE ADD COLUMN 给出后续版本补上的列。
     * 只看 CREATE TABLE 会让「用 ADD COLUMN 加列」的迁移被误判成漏列（MIGRATION_2_3 就是这种写法）。
     */
    private fun migrationTables(): Map<String, MutableSet<String>> {
        val source = locate("src/main/java/com/daycue/android/data/local/Migrations.kt").readText()
        val result = linkedMapOf<String, MutableSet<String>>()
        for (match in CREATE_TABLE.findAll(source)) {
            val table = match.groupValues[1]
            val columns = match.groupValues[2]
                .split(",")
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                // 约束行不是列定义，排除掉（它们是表级 PRIMARY KEY / FOREIGN KEY 等）。
                .filterNot { it.startsWith("PRIMARY KEY", ignoreCase = true) }
                .filterNot { it.startsWith("FOREIGN KEY", ignoreCase = true) }
                .filterNot { it.startsWith("UNIQUE", ignoreCase = true) }
                .filterNot { it.startsWith("CHECK", ignoreCase = true) }
                // 复合约束内部含逗号，按逗号切分会把它切成碎片。例如
                // PRIMARY KEY(entity_type, entity_id) 会切出 "PRIMARY KEY(entity_type" 与 "entity_id)"；
                // 前者被上面的前缀判断挡掉，后者会漏网变成一个叫 "entity_id)" 的伪列。
                // 真正的列定义一定形如「标识符 空白 标识符」，用这个形状把碎片一并挡掉。
                .filter { COLUMN_DEFINITION.containsMatchIn(it) }
                .map { it.split(WHITESPACE).first() }
                .toSet()
            result.getOrPut(table) { linkedSetOf() }.addAll(columns)
        }
        // ADD COLUMN 必须最后叠加：v1 就存在的表（memory_item）会先由 1_2 里的补列语句登记进来，
        // 先处理 ALTER 再处理 CREATE 会让它只拿到「补的那一列」。
        for (match in ALTER_ADD_COLUMN.findAll(source)) {
            result.getOrPut(match.groupValues[1]) { linkedSetOf() }.add(match.groupValues[2])
        }
        return result
    }

    /** 从 DayCueDatabase.kt 的注解里读出声明的 version，避免在测试里再抄一遍魔数。 */
    private fun declaredDatabaseVersion(): Int {
        val source = locate("src/main/java/com/daycue/android/data/local/DayCueDatabase.kt").readText()
        val match = DECLARED_VERSION.find(source)
        assertTrue("在 DayCueDatabase.kt 里没有找到 version = N 声明", match != null)
        return match!!.groupValues[1].toInt()
    }

    private fun schemaJson() = Json.parseToJsonElement(
        locate("schemas/com.daycue.android.data.local.DayCueDatabase/3.json").readText(),
    )

    /**
     * 单元测试的工作目录通常是模块目录（app/），但不同 Gradle 版本可能不同，
     * 所以从工作目录逐级向上找，而不是硬编码相对深度。
     */
    private fun locate(relative: String): File {
        var dir: File? = File(System.getProperty("user.dir")!!).absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        throw AssertionError(
            "找不到文件：" + relative + "（从 " + System.getProperty("user.dir") + " 逐级向上都没有）",
        )
    }

    private companion object {
        /** 逗号后可能紧跟空白或换行，统一用一个空白正则切分。 */
        val WHITESPACE = Regex("\\s+")

        /**
         * 匹配迁移源码里的建表语句。
         * 刻意用普通字符串而不是原始字符串：Kotlin 的原始字符串以三个引号闭合，
         * 而这种正则末尾就带引号，用原始字符串会意外截断字面量。
         */
        val CREATE_TABLE = Regex("CREATE TABLE IF NOT EXISTS (\\w+)\\s*\\(([\\s\\S]*?)\\)\\s*\"")

        /**
         * 真正的列定义形如「列名 类型」。
         *
         * 用来挡掉复合约束按逗号切分后产生的碎片（如 "entity_id)"、"provider)"）：
         * 这些碎片不符合「标识符 + 空白 + 标识符」的形状。
         */
        val COLUMN_DEFINITION = Regex("^\\w+\\s+\\w")

        /**
         * 匹配 ALTER TABLE ... ADD COLUMN。
         * 末尾允许带 NOT NULL DEFAULT '...'，只取表名与列名，默认值由导出 schema 那边比对。
         */
        val ALTER_ADD_COLUMN = Regex("ALTER TABLE (\\w+) ADD COLUMN (\\w+)")

        /** 匹配 @Database 注解里的 version = N。 */
        val DECLARED_VERSION = Regex("version\\s*=\\s*(\\d+)")
    }
}
