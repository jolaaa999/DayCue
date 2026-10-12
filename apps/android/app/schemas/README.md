# Room 导出的 schema

这个目录是 Room 在构建期导出的建表快照，用于在 `MIGRATION` 写错时让构建**直接失败**
（`app/build.gradle.kts` 里通过 KSP 的 `room.schemaLocation` 指向本目录）。

## 当前状态

**已生成。** 本机用 JDK 17 + Gradle 8.9 + Android SDK（platform 35 / build-tools 35.0.0）
真实执行过 `:app:assembleDebug`，KSP 导出了：

    com.daycue.android.data.local.DayCueDatabase/2.json

该文件**应当入库** —— 它是迁移正确性的唯一凭据。它由构建生成，不是手工编写的。

## 仍需在设备上完成的部分

`2.json` 的存在证明「schema 能导出、与实体定义一致」，但它**不能**证明：

- `Migrations.MIGRATION_1_2` 的 DDL 在真实设备上能跑通；
- 迁移后的表结构与 `2.json` 完全一致。

这两件事要靠 `room-testing` 的 `MigrationTestHelper` 在 **androidTest**（需要真机或模拟器）
里验证。本机没有任何 Android 设备，所以迁移本身仍是**未验证**。

在此之前，`Migrations.MIGRATION_1_2` 只能算「按 iOS Schema v2 逐字段抄写、且与导出的
`2.json` 结构一致」的骨架，不能算已在设备上验证。
