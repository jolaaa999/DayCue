import Foundation

// 地点与主动规则的持久化：place / geo_rule / proactive_message 三张表。
//
// DomainModels.swift 是冻结文件，而 Schema v2 里的这三张表在冻结时没有配套的内存模型，
// 所以这里把与列一一对应的类型放在本文件，和仓储方法待在一起，
// 避免「表在这、类型在那」以后又各自长出一份。
//
// 产品前提：默认**不记录轨迹**。place 只保存用户确认过的地点与半径，
// 没有任何「历史位置点」表，也不会有——想记录也没地方放。

public enum GeoStoreError: Error, Equatable {
    case placeNotFound(String)
    case geoRuleNotFound(String)
}

/// 坐标参考系。
///
/// 为什么必须把坐标系存下来而不是「反正都是经纬度」：同一个数字在不同参考系下
/// 指的是不同的物理位置，中国大陆常见的 GCJ-02 与 WGS-84 之间能差几百米——
/// 足以让 200 米的围栏判反。设备定位给的是 WGS-84，若将来接入地图选点，
/// 拿到的可能是 GCJ-02，到那时没有这一列就无从判断该不该纠偏。
/// 现在只落一个值并如实标注，不做任何隐式转换。
public enum PlaceCoordinateSystem: String, Codable, CaseIterable, Sendable {

    case wgs84 = "wgs84"
    case gcj02 = "gcj02"

    public var displayName: String {
        switch self {
        case .wgs84: return "WGS-84"
        case .gcj02: return "GCJ-02"
        }
    }
}

/// 用户确认过的地点。radiusMeters 是「大致范围」，不是精确边界。
public struct PlaceRecord: Codable, Equatable, Sendable, Identifiable {

    public var id: String
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var radiusMeters: Double
    /// 经纬度所属的坐标参考系，见 PlaceCoordinateSystem。读取时缺列按 WGS-84 兜底。
    public var coordinateSystem: PlaceCoordinateSystem
    public var address: String?
    /// 用户是否明确确认过这个地点。未确认的地点不参与规则判定。
    public var confirmedByUser: Bool
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?

    public init(
        id: String = DayCueID.new(),
        name: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double = 200,
        coordinateSystem: PlaceCoordinateSystem = .wgs84,
        address: String? = nil,
        confirmedByUser: Bool = false,
        createdAt: String,
        updatedAt: String,
        deletedAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.coordinateSystem = coordinateSystem
        self.address = address
        self.confirmedByUser = confirmedByUser
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public enum GeoRuleTrigger: String, Codable, CaseIterable, Sendable {

    case enter
    case exit
    case dwell

    public var displayName: String {
        switch self {
        case .enter: return "进入时"
        case .exit: return "离开时"
        case .dwell: return "停留时"
        }
    }
}

/// 一条地点规则。所有时间字段都是「本地墙面时间」或 UTC 字符串，语义在字段名里写明。
public struct GeoRuleRecord: Codable, Equatable, Sendable, Identifiable {

    public var id: String
    public var placeId: String
    public var trigger: GeoRuleTrigger
    public var title: String
    public var body: String?
    /// dwell 需要的最小停留秒数；enter / exit 忽略它。
    public var minDwellSeconds: Int
    public var cooldownSeconds: Int
    public var activeFromLocal: String?
    public var activeToLocal: String?
    /// 逗号分隔的 1...7（1 = 周一）；NULL 或空串表示每天。
    public var weekdays: String?
    public var enabled: Bool
    /// 触发时指向的具体任务（可空）。
    ///
    /// 刻意不加外键：任务在本端是软删除（deleted_at），物理行会一直留着，
    /// 外键带不来任何保护，却会让 v4 的 ADD COLUMN 必须写出建表时那套外键子句，
    /// 写错就是真机升级时抛错。引用完整性由仓储层保证：删任务不删规则，
    /// 规则只是不再指向任何任务。
    public var linkedTaskID: String?
    public var expiresAtUTC: String?
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?

    public init(
        id: String = DayCueID.new(),
        placeId: String,
        trigger: GeoRuleTrigger,
        title: String,
        body: String? = nil,
        minDwellSeconds: Int = 0,
        cooldownSeconds: Int = 3600,
        activeFromLocal: String? = nil,
        activeToLocal: String? = nil,
        weekdays: String? = nil,
        enabled: Bool = true,
        linkedTaskID: String? = nil,
        expiresAtUTC: String? = nil,
        createdAt: String,
        updatedAt: String,
        deletedAt: String? = nil
    ) {
        self.id = id
        self.placeId = placeId
        self.trigger = trigger
        self.title = title
        self.body = body
        self.minDwellSeconds = minDwellSeconds
        self.cooldownSeconds = cooldownSeconds
        self.activeFromLocal = activeFromLocal
        self.activeToLocal = activeToLocal
        self.weekdays = weekdays
        self.enabled = enabled
        self.linkedTaskID = linkedTaskID
        self.expiresAtUTC = expiresAtUTC
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// 主动消息类别。与 proactive_message.kind 的 CHECK 约束逐一对应。
public enum ProactiveMessageKind: String, Codable, CaseIterable, Sendable {

    case followUp = "follow_up"
    case geo
    case schedule
    case review
    case reminder

    public var displayName: String {
        switch self {
        case .followUp: return "课后追问"
        case .geo: return "地点提醒"
        case .schedule: return "日程提醒"
        case .review: return "复习提醒"
        case .reminder: return "任务提醒"
        }
    }
}

/// 主动消息状态。pending / delivered 占用预算；suppressed / expired / cancelled 不占用。
public enum ProactiveMessageState: String, Codable, CaseIterable, Sendable {

    case pending
    case delivered
    case suppressed
    case expired
    case cancelled

    public var displayName: String {
        switch self {
        case .pending: return "等待发出"
        case .delivered: return "已发出"
        case .suppressed: return "已抑制"
        case .expired: return "已过期"
        case .cancelled: return "已取消"
        }
    }

    /// 是否占用当日预算。只有真的会发出去的两态才算，
    /// 否则「被抑制」也会吃掉预算，用户会觉得越抑制越收不到。
    public var consumesBudget: Bool {
        switch self {
        case .pending, .delivered: return true
        case .suppressed, .expired, .cancelled: return false
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .pending: return false
        case .delivered, .suppressed, .expired, .cancelled: return true
        }
    }
}

/// 主动消息账本里的一行。预算、冷却、去重都按这张表判，不依赖内存状态。
public struct ProactiveMessageRecord: Codable, Equatable, Sendable, Identifiable {

    public var id: String
    public var kind: ProactiveMessageKind
    /// 去重键。表上有 UNIQUE 约束，重复入账会被合并到同一行。
    public var dedupeKey: String
    public var targetRef: String?
    public var state: ProactiveMessageState
    public var suppressReason: String?
    public var scheduledAtUTC: String
    public var deliveredAtUTC: String?
    public var expiresAtUTC: String?
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String = DayCueID.new(),
        kind: ProactiveMessageKind,
        dedupeKey: String,
        targetRef: String? = nil,
        state: ProactiveMessageState,
        suppressReason: String? = nil,
        scheduledAtUTC: String,
        deliveredAtUTC: String? = nil,
        expiresAtUTC: String? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.kind = kind
        self.dedupeKey = dedupeKey
        self.targetRef = targetRef
        self.state = state
        self.suppressReason = suppressReason
        self.scheduledAtUTC = scheduledAtUTC
        self.deliveredAtUTC = deliveredAtUTC
        self.expiresAtUTC = expiresAtUTC
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 这条消息实际占用的时刻：已发出看发出时间，否则看计划时间。
    public var effectiveAt: Date? {
        if let deliveredAtUTC, let date = RFC3339.date(fromUTC: deliveredAtUTC) { return date }
        return RFC3339.date(fromUTC: scheduledAtUTC)
    }
}

public extension DayCueStore {

    // MARK: - 地点

    @discardableResult
    func insertPlace(_ place: PlaceRecord, at: Date? = nil) throws -> PlaceRecord {
        var record = place
        let nowString = RFC3339.utcString(from: at ?? Date())
        if record.createdAt.isEmpty { record.createdAt = nowString }
        if record.updatedAt.isEmpty { record.updatedAt = record.createdAt }

        let statement = try database.prepare(
            """
            INSERT INTO place
              (id, name, latitude, longitude, radius_meters, coordinate_system, address,
               confirmed_by_user, created_at, updated_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        try statement.bind([
            .text(record.id),
            .text(record.name),
            .real(record.latitude),
            .real(record.longitude),
            .real(record.radiusMeters),
            .text(record.coordinateSystem),
            .optionalText(record.address),
            .bool(record.confirmedByUser),
            .text(record.createdAt),
            .text(record.updatedAt),
            .optionalText(record.deletedAt)
        ])
        try statement.run()
        return record
    }

    /// 整行 upsert。created_at 保持第一次写入的值，重试保存不会刷新「这个地点是什么时候建的」。
    @discardableResult
    func upsertPlace(_ place: PlaceRecord, at: Date? = nil) throws -> PlaceRecord {
        let nowString = RFC3339.utcString(from: at ?? Date())
        var record = place
        if record.createdAt.isEmpty { record.createdAt = nowString }
        record.updatedAt = nowString

        let statement = try database.prepare(
            """
            INSERT INTO place
              (id, name, latitude, longitude, radius_meters, coordinate_system, address,
               confirmed_by_user, created_at, updated_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              latitude = excluded.latitude,
              longitude = excluded.longitude,
              radius_meters = excluded.radius_meters,
              coordinate_system = excluded.coordinate_system,
              address = excluded.address,
              confirmed_by_user = excluded.confirmed_by_user,
              updated_at = excluded.updated_at,
              deleted_at = excluded.deleted_at;
            """
        )
        try statement.bind([
            .text(record.id),
            .text(record.name),
            .real(record.latitude),
            .real(record.longitude),
            .real(record.radiusMeters),
            .text(record.coordinateSystem),
            .optionalText(record.address),
            .bool(record.confirmedByUser),
            .text(record.createdAt),
            .text(record.updatedAt),
            .optionalText(record.deletedAt)
        ])
        try statement.run()
        return record
    }

    func place(id: String) throws -> PlaceRecord? {
        let statement = try database.prepare(
            "SELECT \(placeColumns) FROM place WHERE id = ? AND deleted_at IS NULL LIMIT 1;"
        )
        try statement.bind([.text(id)])
        guard try statement.step() else { return nil }
        return Self.makePlace(statement)
    }

    func places(includeDeleted: Bool = false, limit: Int = 200) throws -> [PlaceRecord] {
        var sql = "SELECT \(placeColumns) FROM place WHERE 1 = 1"
        if !includeDeleted { sql += " AND deleted_at IS NULL" }
        sql += " ORDER BY created_at ASC, id ASC LIMIT ?;"
        let statement = try database.prepare(sql)
        try statement.bind([.integer(Int64(limit))])
        var result: [PlaceRecord] = []
        while try statement.step() {
            result.append(Self.makePlace(statement))
        }
        return result
    }

    /// 整行写回。已删除或不存在的地点会明确抛错，而不是静默写坏数据。
    func updatePlace(_ place: PlaceRecord, at: Date? = nil) throws {
        guard try self.place(id: place.id) != nil else { throw GeoStoreError.placeNotFound(place.id) }
        var record = place
        record.updatedAt = RFC3339.utcString(from: at ?? Date())
        let statement = try database.prepare(
            """
            UPDATE place SET
              name = ?, latitude = ?, longitude = ?, radius_meters = ?, coordinate_system = ?, address = ?,
              confirmed_by_user = ?, updated_at = ?
            WHERE id = ? AND deleted_at IS NULL;
            """
        )
        try statement.bind([
            .text(record.name),
            .real(record.latitude),
            .real(record.longitude),
            .real(record.radiusMeters),
            .text(record.coordinateSystem),
            .optionalText(record.address),
            .bool(record.confirmedByUser),
            .text(record.updatedAt),
            .text(record.id)
        ])
        try statement.run()
    }

    /// 软删除。deleted_at 只在第一次删除时写入，重复删除不推后时间。
    func softDeletePlace(id: String, at: Date? = nil) throws {
        guard try place(id: id) != nil else { throw GeoStoreError.placeNotFound(id) }
        let nowString = RFC3339.utcString(from: at ?? Date())
        let statement = try database.prepare(
            "UPDATE place SET deleted_at = COALESCE(deleted_at, ?), updated_at = ? WHERE id = ?;"
        )
        try statement.bind([.text(nowString), .text(nowString), .text(id)])
        try statement.run()
    }

    // MARK: - 地点规则

    @discardableResult
    func insertGeoRule(_ rule: GeoRuleRecord, at: Date? = nil) throws -> GeoRuleRecord {
        var record = rule
        let nowString = RFC3339.utcString(from: at ?? Date())
        if record.createdAt.isEmpty { record.createdAt = nowString }
        if record.updatedAt.isEmpty { record.updatedAt = record.createdAt }

        let statement = try database.prepare(
            """
            INSERT INTO geo_rule
              (id, place_id, [trigger], title, body, min_dwell_seconds, cooldown_seconds,
               active_from_local, active_to_local, weekdays, enabled, expires_at_utc,
               created_at, updated_at, deleted_at, linked_task_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        try statement.bind(Self.geoRuleValues(record))
        try statement.run()
        return record
    }

    func geoRule(id: String) throws -> GeoRuleRecord? {
        let statement = try database.prepare(
            "SELECT \(geoRuleColumns) FROM geo_rule WHERE id = ? AND deleted_at IS NULL LIMIT 1;"
        )
        try statement.bind([.text(id)])
        guard try statement.step() else { return nil }
        return Self.makeGeoRule(statement)
    }

    /// 规则列表。placeId 为 nil 表示全部地点；enabledOnly 为 true 时只取启用中的。
    func geoRules(
        placeId: String? = nil,
        enabledOnly: Bool = false,
        includeDeleted: Bool = false,
        limit: Int = 500
    ) throws -> [GeoRuleRecord] {
        var sql = "SELECT \(geoRuleColumns) FROM geo_rule WHERE 1 = 1"
        var values: [SQLiteValue] = []
        if let placeId {
            sql += " AND place_id = ?"
            values.append(.text(placeId))
        }
        if enabledOnly {
            sql += " AND enabled = 1"
        }
        if !includeDeleted {
            sql += " AND deleted_at IS NULL"
        }
        sql += " ORDER BY created_at ASC, id ASC LIMIT ?;"
        values.append(.integer(Int64(limit)))

        let statement = try database.prepare(sql)
        try statement.bind(values)
        var result: [GeoRuleRecord] = []
        while try statement.step() {
            result.append(Self.makeGeoRule(statement))
        }
        return result
    }

    func updateGeoRule(_ rule: GeoRuleRecord, at: Date? = nil) throws {
        guard try geoRule(id: rule.id) != nil else { throw GeoStoreError.geoRuleNotFound(rule.id) }
        var record = rule
        record.updatedAt = RFC3339.utcString(from: at ?? Date())
        let statement = try database.prepare(
            """
            UPDATE geo_rule SET
              place_id = ?, [trigger] = ?, title = ?, body = ?, min_dwell_seconds = ?, cooldown_seconds = ?,
              active_from_local = ?, active_to_local = ?, weekdays = ?, enabled = ?, expires_at_utc = ?,
              linked_task_id = ?, updated_at = ?
            WHERE id = ? AND deleted_at IS NULL;
            """
        )
        try statement.bind([
            .text(record.placeId),
            .text(record.trigger.rawValue),
            .text(record.title),
            .optionalText(record.body),
            .integer(Int64(record.minDwellSeconds)),
            .integer(Int64(record.cooldownSeconds)),
            .optionalText(record.activeFromLocal),
            .optionalText(record.activeToLocal),
            .optionalText(record.weekdays),
            .bool(record.enabled),
            .optionalText(record.expiresAtUTC),
            .optionalText(record.linkedTaskID),
            .text(record.updatedAt),
            .text(record.id)
        ])
        try statement.run()
    }

    func softDeleteGeoRule(id: String, at: Date? = nil) throws {
        guard try geoRule(id: id) != nil else { throw GeoStoreError.geoRuleNotFound(id) }
        let nowString = RFC3339.utcString(from: at ?? Date())
        let statement = try database.prepare(
            "UPDATE geo_rule SET deleted_at = COALESCE(deleted_at, ?), updated_at = ? WHERE id = ?;"
        )
        try statement.bind([.text(nowString), .text(nowString), .text(id)])
        try statement.run()
    }

    // MARK: - 主动消息账本

    /// 入账。按 dedupe_key 合并：同一件事重复入账只会保留一行，
    /// 这样「去重」由表约束保证，而不是靠调用方每次记得先查。
    @discardableResult
    func recordProactiveMessage(_ message: ProactiveMessageRecord, at: Date? = nil) throws -> ProactiveMessageRecord {
        let nowString = RFC3339.utcString(from: at ?? Date())
        var record = message
        if record.createdAt.isEmpty { record.createdAt = nowString }
        record.updatedAt = nowString

        let statement = try database.prepare(
            """
            INSERT INTO proactive_message
              (id, kind, dedupe_key, target_ref, state, suppress_reason,
               scheduled_at_utc, delivered_at_utc, expires_at_utc, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(dedupe_key) DO UPDATE SET
              kind = excluded.kind,
              target_ref = excluded.target_ref,
              state = excluded.state,
              suppress_reason = excluded.suppress_reason,
              scheduled_at_utc = excluded.scheduled_at_utc,
              delivered_at_utc = excluded.delivered_at_utc,
              expires_at_utc = excluded.expires_at_utc,
              updated_at = excluded.updated_at;
            """
        )
        try statement.bind([
            .text(record.id),
            .text(record.kind.rawValue),
            .text(record.dedupeKey),
            .optionalText(record.targetRef),
            .text(record.state.rawValue),
            .optionalText(record.suppressReason),
            .text(record.scheduledAtUTC),
            .optionalText(record.deliveredAtUTC),
            .optionalText(record.expiresAtUTC),
            .text(record.createdAt),
            .text(record.updatedAt)
        ])
        try statement.run()

        return try proactiveMessage(dedupeKey: record.dedupeKey) ?? record
    }

    func proactiveMessage(id: String) throws -> ProactiveMessageRecord? {
        let statement = try database.prepare(
            "SELECT \(proactiveMessageColumns) FROM proactive_message WHERE id = ? LIMIT 1;"
        )
        try statement.bind([.text(id)])
        guard try statement.step() else { return nil }
        return Self.makeProactiveMessage(statement)
    }

    func proactiveMessage(dedupeKey: String) throws -> ProactiveMessageRecord? {
        let statement = try database.prepare(
            "SELECT \(proactiveMessageColumns) FROM proactive_message WHERE dedupe_key = ? LIMIT 1;"
        )
        try statement.bind([.text(dedupeKey)])
        guard try statement.step() else { return nil }
        return Self.makeProactiveMessage(statement)
    }

    func proactiveMessages(
        kind: ProactiveMessageKind? = nil,
        state: ProactiveMessageState? = nil,
        limit: Int = 200
    ) throws -> [ProactiveMessageRecord] {
        var sql = "SELECT \(proactiveMessageColumns) FROM proactive_message WHERE 1 = 1"
        var values: [SQLiteValue] = []
        if let kind {
            sql += " AND kind = ?"
            values.append(.text(kind.rawValue))
        }
        if let state {
            sql += " AND state = ?"
            values.append(.text(state.rawValue))
        }
        sql += " ORDER BY COALESCE(delivered_at_utc, scheduled_at_utc) DESC, id ASC LIMIT ?;"
        values.append(.integer(Int64(limit)))

        let statement = try database.prepare(sql)
        try statement.bind(values)
        var result: [ProactiveMessageRecord] = []
        while try statement.step() {
            result.append(Self.makeProactiveMessage(statement))
        }
        return result
    }

    /// 预算与冷却要看的那一段账本。
    ///
    /// 取「实际发生时刻 >= since」的行：预算按自然日判，调用方传入当天的起点即可。
    /// 这里多取一段是刻意的——跨零点的冷却需要看到前一天的记录。
    func proactiveLedger(since: Date, limit: Int = 1000) throws -> [ProactiveMessageRecord] {
        let statement = try database.prepare(
            """
            SELECT \(proactiveMessageColumns) FROM proactive_message
            WHERE COALESCE(delivered_at_utc, scheduled_at_utc) >= ?
            ORDER BY COALESCE(delivered_at_utc, scheduled_at_utc) ASC, id ASC
            LIMIT ?;
            """
        )
        try statement.bind([.text(RFC3339.utcString(from: since)), .integer(Int64(limit))])
        var result: [ProactiveMessageRecord] = []
        while try statement.step() {
            result.append(Self.makeProactiveMessage(statement))
        }
        return result
    }

    /// 改状态。deliveredAt 只在真正发出时才写，且不覆盖已有的发出时间。
    func updateProactiveMessageState(
        id: String,
        state: ProactiveMessageState,
        suppressReason: String? = nil,
        deliveredAt: Date? = nil,
        at: Date? = nil
    ) throws {
        let statement = try database.prepare(
            """
            UPDATE proactive_message SET
              state = ?, suppress_reason = ?, delivered_at_utc = COALESCE(?, delivered_at_utc), updated_at = ?
            WHERE id = ?;
            """
        )
        try statement.bind([
            .text(state.rawValue),
            .optionalText(suppressReason),
            .optionalText(deliveredAt.map { RFC3339.utcString(from: $0) }),
            .text(RFC3339.utcString(from: at ?? Date())),
            .text(id)
        ])
        try statement.run()
    }

    // MARK: - 行映射

    static func makePlace(_ statement: SQLiteStatement) -> PlaceRecord {
        PlaceRecord(
            id: statement.string(0) ?? "",
            name: statement.string(1) ?? "",
            latitude: statement.double(2),
            longitude: statement.double(3),
            radiusMeters: statement.double(4),
            coordinateSystem: statement.string(5) ?? PlaceCoordinateSystem.wgs84.rawValue,
            address: statement.string(6),
            confirmedByUser: statement.bool(7),
            createdAt: statement.string(8) ?? "",
            updatedAt: statement.string(9) ?? "",
            deletedAt: statement.string(10)
        )
    }

    static func makeGeoRule(_ statement: SQLiteStatement) -> GeoRuleRecord {
        GeoRuleRecord(
            id: statement.string(0) ?? "",
            placeId: statement.string(1) ?? "",
            trigger: GeoRuleTrigger(rawValue: statement.string(2) ?? "enter") ?? .enter,
            title: statement.string(3) ?? "",
            body: statement.string(4),
            minDwellSeconds: statement.int(5),
            cooldownSeconds: statement.int(6),
            activeFromLocal: statement.string(7),
            activeToLocal: statement.string(8),
            weekdays: statement.string(9),
            enabled: statement.bool(10),
            expiresAtUTC: statement.string(11),
            createdAt: statement.string(12) ?? "",
            updatedAt: statement.string(13) ?? "",
            deletedAt: statement.string(14),
            linkedTaskID: statement.string(15)
        )
    }

    static func makeProactiveMessage(_ statement: SQLiteStatement) -> ProactiveMessageRecord {
        ProactiveMessageRecord(
            id: statement.string(0) ?? "",
            kind: ProactiveMessageKind(rawValue: statement.string(1) ?? "reminder") ?? .reminder,
            dedupeKey: statement.string(2) ?? "",
            targetRef: statement.string(3),
            state: ProactiveMessageState(rawValue: statement.string(4) ?? "pending") ?? .pending,
            suppressReason: statement.string(5),
            scheduledAtUTC: statement.string(6) ?? "",
            deliveredAtUTC: statement.string(7),
            expiresAtUTC: statement.string(8),
            createdAt: statement.string(9) ?? "",
            updatedAt: statement.string(10) ?? ""
        )
    }

    /// INSERT 专用参数顺序（与 geoRuleColumns 一致）。UPDATE 的列顺序不同，所以不复用。
    internal static func geoRuleValues(_ record: GeoRuleRecord) -> [SQLiteValue] {
        [
            .text(record.id),
            .text(record.placeId),
            .text(record.trigger.rawValue),
            .text(record.title),
            .optionalText(record.body),
            .integer(Int64(record.minDwellSeconds)),
            .integer(Int64(record.cooldownSeconds)),
            .optionalText(record.activeFromLocal),
            .optionalText(record.activeToLocal),
            .optionalText(record.weekdays),
            .bool(record.enabled),
            .optionalText(record.expiresAtUTC),
            .text(record.createdAt),
            .text(record.updatedAt),
            .optionalText(record.deletedAt),
            .optionalText(record.linkedTaskID)
        ]
    }
}

/// 列顺序集中一处，取值下标才不会随查询改动而错位。
/// [trigger] 用方括号包住：TRIGGER 是 SQLite 的关键字，直接当列名在某些语句里会被当成语法。
let placeColumns = "id, name, latitude, longitude, radius_meters, coordinate_system, address, confirmed_by_user, created_at, updated_at, deleted_at"

// linked_task_id 追加在末尾而不是插在中间：取值下标一错位就是静默错列，追加能让已有下标全部不变。
let geoRuleColumns = "id, place_id, [trigger], title, body, min_dwell_seconds, cooldown_seconds, active_from_local, active_to_local, weekdays, enabled, expires_at_utc, created_at, updated_at, deleted_at, linked_task_id"

let proactiveMessageColumns = "id, kind, dedupe_key, target_ref, state, suppress_reason, scheduled_at_utc, delivered_at_utc, expires_at_utc, created_at, updated_at"
