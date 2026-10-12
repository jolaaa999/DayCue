# Room 导出的 schema（当前为空）

这个目录本来是 Room 构建期导出的建表快照（`2.json` 之类），用于在 `MIGRATION` 写错时让构建直接失败。

**当前目录里没有 schema 文件**，因为本机没有 Android SDK / Gradle，从未构建过。
第一次在装有 JDK 17 + Android SDK 的机器上执行 `./gradlew :app:assembleDebug` 后，
KSP 会在这里生成 `2.json`；**该文件应当入库**，它是迁移正确性的唯一凭据。

在 `2.json` 生成并用 `room-testing` 的 `MigrationTestHelper` 验证之前，
`Migrations.MIGRATION_1_2` 只能算「按 iOS Schema v2 逐字段抄写」的骨架，不能算已验证。
