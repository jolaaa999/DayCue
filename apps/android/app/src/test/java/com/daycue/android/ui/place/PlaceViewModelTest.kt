package com.daycue.android.ui.place

import com.daycue.android.data.local.dao.GeoRuleDao
import com.daycue.android.data.local.dao.PlaceDao
import com.daycue.android.data.local.entity.GeoRuleRecord
import com.daycue.android.data.local.entity.PlaceRecord
import com.daycue.android.data.local.entity.TaskRecord
import com.daycue.android.data.repository.GeoRuleChangeListener
import com.daycue.android.data.repository.PlaceRepository
import com.daycue.android.data.repository.TimeSource
import com.daycue.android.domain.location.LocationCapability
import com.daycue.android.domain.model.CoordinateSystem
import com.daycue.android.domain.model.PlaceTrigger
import com.daycue.android.platform.location.GeoPoint
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.time.Instant
import java.time.ZoneId

/**
 * 地点与规则界面的**真实行为**。
 *
 * 这些用例证明的不是「界面画得对」，而是界面背后的动作真的发生了：
 * 没有位置时保存被拒绝、半径非法被拒绝、保存之后调用了 onRuleChanged、
 * 删除规则之后调用了 onRulesRemoved、编辑规则复用了既有 ruleId。
 *
 * 为什么在 JVM 上能做：PlaceViewModel 只依赖仓储、一个窄接口（GeoRuleChangeListener）、
 * 一个取点接口和一个只读目录；DAO 用内存替身替换，不需要 Room、不需要设备、不需要定位框架。
 * 「围栏真的注册上了」「通知真的弹出来了」属于设备验收，不在本文件范围内。
 */
class PlaceViewModelTest {

    private val dispatcher = StandardTestDispatcher()
    private val zone: ZoneId = ZoneId.of("Asia/Shanghai")
    private val now: Instant = Instant.parse("2026-03-04T04:00:00Z")

    private lateinit var placeDao: FakePlaceDao
    private lateinit var ruleDao: FakeGeoRuleDao
    private lateinit var repository: PlaceRepository
    private lateinit var changes: RecordingGeoChanges
    private lateinit var catalog: FakeCatalog

    /** 固定时刻：所有时间都由用例给出，测试不会因为"跑的时候刚好几点"而飘。 */
    private val fixedClock = TimeSource { now }

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        placeDao = FakePlaceDao()
        ruleDao = FakeGeoRuleDao()
        repository = PlaceRepository(placeDao, ruleDao, fixedClock)
        changes = RecordingGeoChanges()
        catalog = FakeCatalog(placeDao, ruleDao)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun viewModel(point: GeoPoint? = GeoPoint(31.2304, 121.4737)): PlaceViewModel =
        PlaceViewModel(
            repository = repository,
            geoChanges = changes,
            locationPicker = { point },
            catalog = catalog,
            zone = zone,
            timeSource = fixedClock,
        )

    // ---- 位置缺失与非法输入 ----

    @Test
    fun saveWithoutUserProvidedPositionIsRejected() = runTest(dispatcher) {
        val model = viewModel(point = null)
        model.startPlaceDraft(placeId = null)
        advanceUntilIdle()
        model.updateDraftField("图书馆")
        model.savePlace()
        advanceUntilIdle()

        val state = model.state.value
        assertNotNull("没有位置时必须给出明确的拒绝原因", state.error)
        assertTrue("错误信息要说清是缺位置", state.error!!.contains("还没有位置"))
        assertEquals("被拒绝的保存不能落库", 0, placeDao.inserted.size)
        assertEquals("被拒绝的保存不能触发围栏变更", 0, changes.ruleChangedCalls)
        assertNotNull("草稿要保留，用户不必重填", state.draft)
    }

    @Test
    fun readingCurrentLocationFailureKeepsPositionEmptyAndExplainsWhy() = runTest(dispatcher) {
        val model = viewModel(point = null)
        model.startPlaceDraft(placeId = null)
        advanceUntilIdle()
        model.useCurrentLocation()
        advanceUntilIdle()

        val draft = model.state.value.draft!!
        assertNull("读不到位置时绝不能填一个默认坐标", draft.latitude)
        assertNull(draft.longitude)
        assertFalse(draft.hasPosition)
        assertTrue(
            "必须说明为什么读不到，而不是静默失败",
            model.state.value.error!!.contains("读不到当前位置"),
        )
    }

    @Test
    fun invalidRadiusIsRejected() = runTest(dispatcher) {
        val model = viewModel()
        model.startPlaceDraft(placeId = null)
        advanceUntilIdle()
        model.updateDraftField("图书馆")
        model.useCurrentLocation()
        advanceUntilIdle()
        model.updateDraftRadius("0")
        model.savePlace()
        advanceUntilIdle()

        assertTrue(model.state.value.error!!.contains("半径"))
        assertEquals(0, placeDao.inserted.size)

        model.updateDraftRadius("-30")
        model.savePlace()
        advanceUntilIdle()
        assertTrue(model.state.value.error!!.contains("半径"))
        assertEquals(0, placeDao.inserted.size)
    }

    @Test
    fun outOfRangeCoordinatesAreRejected() = runTest(dispatcher) {
        val model = viewModel()
        model.startPlaceDraft(placeId = null)
        advanceUntilIdle()
        model.updateDraftField("错误地点")
        model.updateDraftLatitude("120")
        model.updateDraftLongitude("200")
        model.savePlace()
        advanceUntilIdle()

        assertTrue(model.state.value.error!!.contains("纬度"))
        assertEquals(0, placeDao.inserted.size)

        model.updateDraftLatitude("-31.2")
        model.savePlace()
        advanceUntilIdle()
        assertTrue(model.state.value.error!!.contains("经度"))
        assertEquals(0, placeDao.inserted.size)
    }

    // ---- 保存成功后的链路 ----

    @Test
    fun savePlaceWritesRecordAndNotifiesFenceChain() = runTest(dispatcher) {
        val model = viewModel()
        model.startPlaceDraft(placeId = null)
        advanceUntilIdle()
        model.updateDraftField("图书馆")
        model.updateDraftAddress("中关村南大街")
        model.useCurrentLocation()
        advanceUntilIdle()
        model.updateDraftRadius("150")
        model.savePlace()
        advanceUntilIdle()

        assertEquals("必须真的落库", 1, placeDao.inserted.size)
        val saved = placeDao.inserted.single()
        assertEquals("图书馆", saved.name)
        assertEquals(31.2304, saved.latitude, 1e-9)
        assertEquals(121.4737, saved.longitude, 1e-9)
        assertEquals(150.0, saved.radiusMeters, 1e-9)
        assertTrue("只有用户确认过的地点才参与触发", saved.confirmedByUser)
        assertEquals("坐标系必须显式落库", "wgs84", saved.coordinateSystem.raw)
        assertEquals("保存后必须重新注册围栏", 1, changes.ruleChangedCalls)
        assertNull("保存成功后草稿关闭", model.state.value.draft)
    }

    @Test
    fun saveRuleNotifiesFenceChain() = runTest(dispatcher) {
        val placeId = repository.createConfirmedPlace(
            name = "图书馆",
            latitude = 31.2,
            longitude = 121.4,
            radiusMeters = 200.0,
            coordinateSystem = CoordinateSystem.WGS84,
        )
        val model = viewModel()
        model.startRuleDraft(placeId = placeId, ruleId = null)
        advanceUntilIdle()
        model.updateRuleDraft { it.copy(title = "到图书馆了", trigger = PlaceTrigger.DWELL, minDwellSeconds = "600") }
        model.saveRule()
        advanceUntilIdle()

        assertEquals(1, ruleDao.inserted.size)
        val rule = ruleDao.inserted.single()
        assertEquals("到图书馆了", rule.title)
        assertEquals(PlaceTrigger.DWELL, rule.trigger)
        assertEquals(600, rule.minDwellSeconds)
        assertEquals("保存规则后必须重新注册围栏", 1, changes.ruleChangedCalls)
    }

    @Test
    fun ruleKeepsLinkedTaskSoTheNotificationCanPointAtIt() = runTest(dispatcher) {
        val placeId = repository.createConfirmedPlace(
            name = "图书馆",
            latitude = 31.2,
            longitude = 121.4,
            radiusMeters = 200.0,
            coordinateSystem = CoordinateSystem.WGS84,
        )
        val task = TaskRecord(
            id = "task-1",
            title = "还书",
            timezone = zone.id,
            createdAt = now,
            updatedAt = now,
        )
        catalog.tasks.value = listOf(task)

        val model = viewModel()
        model.startRuleDraft(placeId = placeId, ruleId = null)
        advanceUntilIdle()
        model.updateRuleDraft { it.copy(title = "到图书馆了", linkedTaskId = task.id) }
        model.saveRule()
        advanceUntilIdle()

        assertEquals("关联任务必须落库，否则通知点开之后无处可去", task.id, ruleDao.inserted.single().linkedTaskId)
    }

    @Test
    fun dwellSecondsAreZeroedForNonDwellTriggers() = runTest(dispatcher) {
        val placeId = repository.createConfirmedPlace(
            name = "家",
            latitude = 31.2,
            longitude = 121.4,
            radiusMeters = 200.0,
            coordinateSystem = CoordinateSystem.WGS84,
        )
        val model = viewModel()
        model.startRuleDraft(placeId = placeId, ruleId = null)
        advanceUntilIdle()
        model.updateRuleDraft { it.copy(title = "到家了", trigger = PlaceTrigger.ENTER, minDwellSeconds = "900") }
        model.saveRule()
        advanceUntilIdle()

        assertEquals("非停留条件不该留下一个不参与判定的秒数", 0, ruleDao.inserted.single().minDwellSeconds)
    }

    // ---- 编辑复用 ruleId ----

    @Test
    fun editingRuleReusesExistingRuleIdInsteadOfCreatingNewOne() = runTest(dispatcher) {
        val placeId = repository.createConfirmedPlace(
            name = "图书馆",
            latitude = 31.2,
            longitude = 121.4,
            radiusMeters = 200.0,
            coordinateSystem = CoordinateSystem.WGS84,
        )
        val existing = repository.upsertRule(
            placeId = placeId,
            trigger = PlaceTrigger.ENTER,
            title = "旧标题",
            availability = LocationCapability.AVAILABLE,
        )

        val model = viewModel()
        model.startRuleDraft(placeId = placeId, ruleId = existing.id)
        advanceUntilIdle()
        assertEquals("编辑草稿必须带上既有 id", existing.id, model.state.value.ruleDraft!!.ruleId)
        assertEquals("旧标题", model.state.value.ruleDraft!!.title)

        model.updateRuleDraft { it.copy(title = "新标题") }
        model.saveRule()
        advanceUntilIdle()

        assertEquals("编辑不能新增一条规则", 1, ruleDao.stored.size)
        assertEquals("必须复用既有 id", existing.id, ruleDao.stored.single().id)
        assertEquals("新标题", ruleDao.stored.single().title)
        assertEquals("创建时间不能被一次编辑改写", existing.createdAt, ruleDao.stored.single().createdAt)
        assertEquals(1, changes.ruleChangedCalls)
    }

    @Test
    fun newRuleGetsItsOwnId() = runTest(dispatcher) {
        val placeId = repository.createConfirmedPlace(
            name = "图书馆",
            latitude = 31.2,
            longitude = 121.4,
            radiusMeters = 200.0,
            coordinateSystem = CoordinateSystem.WGS84,
        )
        val first = repository.upsertRule(
            placeId = placeId,
            trigger = PlaceTrigger.ENTER,
            title = "第一条",
            availability = LocationCapability.AVAILABLE,
        )

        val model = viewModel()
        model.startRuleDraft(placeId = placeId, ruleId = null)
        advanceUntilIdle()
        assertNull("新建草稿不能带 id", model.state.value.ruleDraft!!.ruleId)
        model.updateRuleDraft { it.copy(title = "第二条") }
        model.saveRule()
        advanceUntilIdle()

        assertEquals(2, ruleDao.stored.size)
        assertNotEquals("新建必须是另一个 id", first.id, ruleDao.stored.last().id)
    }

    // ---- 删除与开关 ----

    @Test
    fun deletingRuleNotifiesRemovalSoPendingNotificationsAreCancelled() = runTest(dispatcher) {
        val placeId = repository.createConfirmedPlace(
            name = "图书馆",
            latitude = 31.2,
            longitude = 121.4,
            radiusMeters = 200.0,
            coordinateSystem = CoordinateSystem.WGS84,
        )
        val rule = repository.upsertRule(
            placeId = placeId,
            trigger = PlaceTrigger.ENTER,
            title = "到图书馆了",
            availability = LocationCapability.AVAILABLE,
        )

        val model = viewModel()
        model.deleteRule(rule.id)
        advanceUntilIdle()

        assertEquals("删除规则必须走 onRulesRemoved（它负责取消已排通知）", listOf(rule.id), changes.removedRuleIds.single())
        // 刻意不再额外调一次 onRuleChanged：onRulesRemoved 内部已经做了注册对账，
        // 多调一次就是两轮「注销再注册」，而这段代码路径本来就是「用户删了规则，越快撤销越好」。
        assertEquals("删除只走一次注册对账（在 onRulesRemoved 内）", 0, changes.ruleChangedCalls)
        assertTrue(ruleDao.stored.single().deletedAt != null)
    }

    @Test
    fun deletingPlaceRemovesItsRulesAndCancelsTheirNotifications() = runTest(dispatcher) {
        val placeId = repository.createConfirmedPlace(
            name = "图书馆",
            latitude = 31.2,
            longitude = 121.4,
            radiusMeters = 200.0,
            coordinateSystem = CoordinateSystem.WGS84,
        )
        val rule = repository.upsertRule(
            placeId = placeId,
            trigger = PlaceTrigger.ENTER,
            title = "到图书馆了",
            availability = LocationCapability.AVAILABLE,
        )

        val model = viewModel()
        model.deletePlace(placeId)
        advanceUntilIdle()

        assertEquals("地点下的规则要一起取消", listOf(rule.id), changes.removedRuleIds.single())
        assertTrue("地点被软删除", placeDao.stored.single().deletedAt != null)
        assertTrue("它下面的规则也必须软删除，否则会留下一条指向已删地点的僵尸规则", ruleDao.stored.single().deletedAt != null)
    }

    @Test
    fun togglingRuleReregistersFence() = runTest(dispatcher) {
        val placeId = repository.createConfirmedPlace(
            name = "图书馆",
            latitude = 31.2,
            longitude = 121.4,
            radiusMeters = 200.0,
            coordinateSystem = CoordinateSystem.WGS84,
        )
        val rule = repository.upsertRule(
            placeId = placeId,
            trigger = PlaceTrigger.ENTER,
            title = "到图书馆了",
            availability = LocationCapability.AVAILABLE,
        )

        val model = viewModel()
        model.setRuleEnabled(rule.id, false)
        advanceUntilIdle()
        assertFalse(ruleDao.stored.single().enabled)
        assertEquals("关掉规则必须重新注册（真的注销围栏）", 1, changes.ruleChangedCalls)

        model.setRuleEnabled(rule.id, true)
        advanceUntilIdle()
        assertTrue(ruleDao.stored.single().enabled)
        assertEquals(2, changes.ruleChangedCalls)
    }

    @Test
    fun ruleSavedWhileLocationUnusableIsPersistedAsPaused() = runTest(dispatcher) {
        catalog.capability = LocationCapability.PERMISSION_DENIED
        val placeId = repository.createConfirmedPlace(
            name = "图书馆",
            latitude = 31.2,
            longitude = 121.4,
            radiusMeters = 200.0,
            coordinateSystem = CoordinateSystem.WGS84,
        )
        val model = viewModel()
        model.startRuleDraft(placeId = placeId, ruleId = null)
        advanceUntilIdle()
        model.updateRuleDraft { it.copy(title = "到图书馆了", enabled = true) }
        model.saveRule()
        advanceUntilIdle()

        val saved = ruleDao.stored.single()
        assertFalse("定位不可用时规则必须是暂停状态，而不是显示成正常运行", saved.enabled)
        assertNotNull("暂停原因要写进正文，用户才看得到", saved.body)
        assertTrue(saved.body!!.contains("定位不可用"))
    }

    // ---- 替身 ----

    /** 记录「围栏链路到底有没有被通知」——正是本轮要证明的事情。 */
    private class RecordingGeoChanges : GeoRuleChangeListener {
        var ruleChangedCalls = 0
        val removedRuleIds = ArrayList<List<String>>()

        // 这个替身只记录「有没有被调用」：围栏注册的真实效果由协调器自己的用例保证。
        override suspend fun onRuleChanged() {
            ruleChangedCalls += 1
        }

        override suspend fun onRulesRemoved(ruleIds: List<String>) {
            removedRuleIds += ruleIds
        }
    }

    /** 只读目录：能力 / 总开关 / 未完成任务 / 两个 Flow。 */
    private class FakeCatalog(
        private val placeDao: FakePlaceDao,
        private val ruleDao: FakeGeoRuleDao,
    ) : PlaceCatalog {
        var capability: LocationCapability = LocationCapability.AVAILABLE
        var locationRulesEnabled: Boolean = true
        val tasks = MutableStateFlow<List<TaskRecord>>(emptyList())

        override fun places(): Flow<List<PlaceRecord>> = placeDao.observeActive()
        override fun rules(): Flow<List<GeoRuleRecord>> = ruleDao.observeAll()
        override fun tasks(): Flow<List<TaskRecord>> = tasks
        override suspend fun capability(): LocationCapability = capability
        override suspend fun locationRulesEnabled(): Boolean = locationRulesEnabled
    }

    private class FakePlaceDao : PlaceDao {
        val stored = ArrayList<PlaceRecord>()
        val inserted = ArrayList<PlaceRecord>()
        private val version = MutableStateFlow(0)

        override suspend fun insert(record: PlaceRecord) {
            inserted += record
            stored += record
            version.value += 1
        }

        override suspend fun update(record: PlaceRecord) {
            val index = stored.indexOfFirst { it.id == record.id }
            if (index >= 0) stored[index] = record
            version.value += 1
        }

        override suspend fun findById(id: String): PlaceRecord? =
            stored.firstOrNull { it.id == id && it.deletedAt == null }

        override fun observeActive(): Flow<List<PlaceRecord>> =
            version.map { stored.filter { it.deletedAt == null }.sortedBy { it.name } }

        override suspend fun listConfirmed(): List<PlaceRecord> =
            stored.filter { it.deletedAt == null && it.confirmedByUser }

        override suspend fun listAll(): List<PlaceRecord> = stored.toList()

        override suspend fun softDelete(id: String, deletedAt: Instant) {
            val index = stored.indexOfFirst { it.id == id }
            if (index >= 0) stored[index] = stored[index].copy(deletedAt = deletedAt, updatedAt = deletedAt)
            version.value += 1
        }
    }

    private class FakeGeoRuleDao : GeoRuleDao {
        val stored = ArrayList<GeoRuleRecord>()
        val inserted = ArrayList<GeoRuleRecord>()

        override suspend fun insert(record: GeoRuleRecord) {
            inserted += record
            val index = stored.indexOfFirst { it.id == record.id }
            if (index >= 0) stored[index] = record else stored += record
        }

        override suspend fun update(record: GeoRuleRecord) {
            val index = stored.indexOfFirst { it.id == record.id }
            if (index >= 0) stored[index] = record
        }

        override suspend fun findById(id: String): GeoRuleRecord? =
            stored.firstOrNull { it.id == id && it.deletedAt == null }

        override fun observeAll(): Flow<List<GeoRuleRecord>> =
            MutableStateFlow(stored.filter { it.deletedAt == null }).map { it }

        override suspend fun listEnabledForPlace(placeId: String): List<GeoRuleRecord> =
            stored.filter { it.deletedAt == null && it.enabled && it.placeId == placeId }

        override suspend fun listEnabled(): List<GeoRuleRecord> =
            stored.filter { it.deletedAt == null && it.enabled }

        override suspend fun listAll(): List<GeoRuleRecord> = stored.filter { it.deletedAt == null }

        override suspend fun listForPlace(placeId: String): List<GeoRuleRecord> =
            stored.filter { it.deletedAt == null && it.placeId == placeId }

        override suspend fun setEnabled(id: String, enabled: Boolean, updatedAt: Instant) {
            val index = stored.indexOfFirst { it.id == id }
            if (index >= 0) stored[index] = stored[index].copy(enabled = enabled, updatedAt = updatedAt)
        }

        override suspend fun softDelete(id: String, deletedAt: Instant) {
            val index = stored.indexOfFirst { it.id == id }
            if (index >= 0) stored[index] = stored[index].copy(deletedAt = deletedAt, updatedAt = deletedAt)
        }
    }
}
