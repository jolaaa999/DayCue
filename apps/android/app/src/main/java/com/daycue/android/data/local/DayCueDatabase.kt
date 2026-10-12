package com.daycue.android.data.local

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.TypeConverters
import com.daycue.android.data.local.dao.AppSettingDao
import com.daycue.android.data.local.dao.CaptureDao
import com.daycue.android.data.local.dao.CourseDao
import com.daycue.android.data.local.dao.CourseInstanceDao
import com.daycue.android.data.local.dao.CourseScheduleRuleDao
import com.daycue.android.data.local.dao.FollowUpDao
import com.daycue.android.data.local.dao.FollowUpReplyDao
import com.daycue.android.data.local.dao.GeoRuleDao
import com.daycue.android.data.local.dao.MemoryDao
import com.daycue.android.data.local.dao.NoteDao
import com.daycue.android.data.local.dao.OutboxDao
import com.daycue.android.data.local.dao.PlaceDao
import com.daycue.android.data.local.dao.ProactiveMessageDao
import com.daycue.android.data.local.dao.SyncCursorDao
import com.daycue.android.data.local.dao.SyncTombstoneDao
import com.daycue.android.data.local.dao.TaskDao
import com.daycue.android.data.local.entity.AppSettingRecord
import com.daycue.android.data.local.entity.CaptureItemRecord
import com.daycue.android.data.local.entity.CourseInstanceRecord
import com.daycue.android.data.local.entity.CourseRecord
import com.daycue.android.data.local.entity.CourseScheduleRuleRecord
import com.daycue.android.data.local.entity.FollowUpRecord
import com.daycue.android.data.local.entity.FollowUpReplyRecord
import com.daycue.android.data.local.entity.GeoRuleRecord
import com.daycue.android.data.local.entity.MemoryItemRecord
import com.daycue.android.data.local.entity.NoteRecord
import com.daycue.android.data.local.entity.OutboxOperationRecord
import com.daycue.android.data.local.entity.PlaceRecord
import com.daycue.android.data.local.entity.ProactiveMessageRecord
import com.daycue.android.data.local.entity.SyncCursorRecord
import com.daycue.android.data.local.entity.SyncSnapshotRecord
import com.daycue.android.data.local.entity.SyncTombstoneRecord
import com.daycue.android.data.local.entity.TaskRecord

/**
 * 本地库。
 *
 * 表名与字段名与 iOS 的 Schema.swift 对齐，版本号也刻意跟随 iOS 的 currentVersion（2），
 * 这样「Android 落后一版」这种事一眼可见。
 *
 * 刻意**没有**调用 fallbackToDestructiveMigration()：本地库里有用户还没同步出去的笔记和课表，
 * 迁移写错时宁可启动崩溃并暴露问题，也不能把数据默默清空。
 */
@Database(
    entities = [
        CaptureItemRecord::class,
        TaskRecord::class,
        NoteRecord::class,
        MemoryItemRecord::class,
        CourseRecord::class,
        CourseScheduleRuleRecord::class,
        CourseInstanceRecord::class,
        FollowUpRecord::class,
        FollowUpReplyRecord::class,
        PlaceRecord::class,
        GeoRuleRecord::class,
        ProactiveMessageRecord::class,
        OutboxOperationRecord::class,
        SyncCursorRecord::class,
        SyncTombstoneRecord::class,
        SyncSnapshotRecord::class,
        AppSettingRecord::class,
    ],
    version = 2,
    exportSchema = true,
)
@TypeConverters(DayCueConverters::class)
abstract class DayCueDatabase : RoomDatabase() {

    abstract fun captureDao(): CaptureDao
    abstract fun taskDao(): TaskDao
    abstract fun noteDao(): NoteDao
    abstract fun memoryDao(): MemoryDao
    abstract fun placeDao(): PlaceDao
    abstract fun geoRuleDao(): GeoRuleDao
    abstract fun proactiveMessageDao(): ProactiveMessageDao
    abstract fun courseDao(): CourseDao
    abstract fun courseScheduleRuleDao(): CourseScheduleRuleDao
    abstract fun courseInstanceDao(): CourseInstanceDao
    abstract fun followUpDao(): FollowUpDao
    abstract fun followUpReplyDao(): FollowUpReplyDao
    abstract fun outboxDao(): OutboxDao
    abstract fun syncCursorDao(): SyncCursorDao
    abstract fun syncTombstoneDao(): SyncTombstoneDao
    abstract fun syncSnapshotDao(): com.daycue.android.data.local.dao.SyncSnapshotDao
    abstract fun appSettingDao(): AppSettingDao

    companion object {
        const val DATABASE_NAME = "daycue.db"

        fun build(context: Context): DayCueDatabase =
            Room.databaseBuilder(context.applicationContext, DayCueDatabase::class.java, DATABASE_NAME)
                // WAL：录完音立刻落库不会卡住今天页的读取；本地库只有单进程访问，收益明显。
                .setJournalMode(JournalMode.WRITE_AHEAD_LOGGING)
                .addMigrations(*DayCueMigrations.ALL)
                .build()
    }
}
