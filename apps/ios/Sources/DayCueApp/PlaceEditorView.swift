import SwiftUI
import DayCueCore

/// 地点编辑。
///
/// 规则挂在地点上（geo_rule.place_id 有外键），所以新建时先保存地点，
/// 保存之后规则区才会出现——不给用户一个点了必定失败的表单。
struct PlaceEditorView: View {

    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    let placeId: String?

    @State private var activePlaceId: String?
    @State private var name = ""
    @State private var address = ""
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var radiusMeters = 200.0
    @State private var confirmedByUser = false

    @State private var rules: [GeoRuleRecord] = []
    @State private var message: String?
    @State private var loadError: String?

    // 新规则草稿。全部显式留在界面上，避免「用它就得再点进一层」。
    @State private var newTrigger: GeoRuleTrigger = .enter
    @State private var newTitle = ""
    @State private var newBody = ""
    @State private var newMinDwellMinutes = 5
    @State private var newCooldownMinutes = 60
    @State private var newUsesWindow = false
    @State private var newFromMinutes = 8 * 60
    @State private var newToMinutes = 22 * 60
    @State private var newWeekdays: Set<Int> = [1, 2, 3, 4, 5]

    init(placeId: String?) {
        self.placeId = placeId
        _activePlaceId = State(initialValue: placeId)
    }

    var body: some View {
        List {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if let message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Label("不记录轨迹", systemImage: "location.slash")
                    .font(.footnote.weight(.semibold))
                Text("DayCue 只保存下面这个坐标点与半径，不会记录你去过哪里、走哪条路。室内定位不精确，规则触发可能有延迟或漏掉，不能当作精确的位置事实。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            placeSection
            if activePlaceId == nil {
                Section {
                    Text("先保存地点，然后才能添加规则。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                existingRulesSection
                newRuleSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(activePlaceId == nil ? "添加地点" : "编辑地点")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    // MARK: - 地点

    private var placeSection: some View {
        Group {
            Section {
                TextField("名称，例如「三教」", text: $name)
                TextField("地址（可选）", text: $address)
            } header: {
                Text("地点")
            } footer: {
                Text("名称只是给你自己看的标签，不会用来推断位置。")
                    .font(.caption)
            }

            Section {
                TextField("纬度，例如 31.2304", text: $latitudeText)
                    .keyboardType(.numbersAndPunctuation)
                TextField("经度，例如 121.4737", text: $longitudeText)
                    .keyboardType(.numbersAndPunctuation)
            } header: {
                Text("坐标")
            } footer: {
                Text("手动填写坐标，或者从地图 App 复制过来。DayCue 不会在后台持续取你的位置来猜这个点。")
                    .font(.caption)
            }

            Section {
                HStack {
                    Text("半径")
                    Spacer()
                    Text("\(Int(radiusMeters.rounded())) 米")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $radiusMeters, in: 50...1000, step: 10)
                Toggle("我确认这个地点和半径", isOn: $confirmedByUser)
            } header: {
                Text("范围")
            } footer: {
                Text("只有确认过的地点才会参与规则判定。半径越大越容易被路过触发，越小越容易漏掉。")
                    .font(.caption)
            }

            Section {
                Button(activePlaceId == nil ? "保存地点" : "保存修改") { savePlace() }
            }
        }
    }

    // MARK: - 已有规则

    private var existingRulesSection: some View {
        Section {
            if rules.isEmpty {
                Text("还没有规则。这个地点目前只会被保存，不会有任何提醒。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rules) { rule in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(rule.title)
                                .font(.body)
                            Spacer()
                            Toggle("", isOn: enabledBinding(rule))
                                .labelsHidden()
                        }
                        Text(triggerSummary(rule))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("删除这条规则", role: .destructive) {
                            deleteRule(rule)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("已有规则")
        } footer: {
            Text("关掉开关只是停用，不会删除；删除是软删除，历史仍然留在本机。")
                .font(.caption)
        }
    }

    private func triggerSummary(_ rule: GeoRuleRecord) -> String {
        var parts: [String] = [rule.trigger.displayName]
        if rule.trigger == .dwell {
            parts.append("停留满 \(max(rule.minDwellSeconds / 60, 0)) 分钟")
        }
        parts.append("冷却 \(max(rule.cooldownSeconds / 60, 0)) 分钟")
        parts.append(GeoRuleWeekdays.displayText(rule.weekdays))
        if let from = rule.activeFromLocal, let to = rule.activeToLocal, !from.isEmpty, !to.isEmpty {
            parts.append("\(from)–\(to)")
        } else {
            parts.append("全天")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 新规则

    private var newRuleSection: some View {
        Section {
            Picker("触发条件", selection: $newTrigger) {
                ForEach(GeoRuleTrigger.allCases, id: \.rawValue) { trigger in
                    Text(trigger.displayName).tag(trigger)
                }
            }

            TextField("标题，例如「到实验室了」", text: $newTitle)
            TextField("补充说明（可选）", text: $newBody, axis: .vertical)

            if newTrigger == .dwell {
                Stepper("停留满 \(newMinDwellMinutes) 分钟", value: $newMinDwellMinutes, in: 1...180)
            }

            Stepper("冷却 \(newCooldownMinutes) 分钟", value: $newCooldownMinutes, in: 0...1440)

            Toggle("只在特定时段生效", isOn: $newUsesWindow)
            if newUsesWindow {
                DatePicker("从", selection: windowFromBinding, displayedComponents: .hourAndMinute)
                DatePicker("到", selection: windowToBinding, displayedComponents: .hourAndMinute)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("生效星期")
                    .font(.subheadline)
                weekdayPicker
            }

            Button("添加规则") { addRule() }
        } header: {
            Text("新增规则")
        } footer: {
            Text("「停留」需要你确实在区域内待够设定时长才会触发。位置未知（例如没有权限或定位失败）时任何规则都不会触发，也不会用别的方式猜。")
                .font(.caption)
        }
    }

    private var weekdayPicker: some View {
        HStack(spacing: 6) {
            ForEach(GeoRuleWeekdays.all, id: \.self) { day in
                Button {
                    if newWeekdays.contains(day) {
                        newWeekdays.remove(day)
                    } else {
                        newWeekdays.insert(day)
                    }
                } label: {
                    Text(GeoRuleWeekdays.displayNames[day] ?? "第\(day)天")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            newWeekdays.contains(day) ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var windowFromBinding: Binding<Date> {
        Binding(
            get: { ClockEditing.date(fromMinutes: newFromMinutes) },
            set: { newFromMinutes = ClockEditing.minutes(from: $0) }
        )
    }

    private var windowToBinding: Binding<Date> {
        Binding(
            get: { ClockEditing.date(fromMinutes: newToMinutes) },
            set: { newToMinutes = ClockEditing.minutes(from: $0) }
        )
    }

    // MARK: - 数据

    private func load() {
        guard let existingId = activePlaceId else { return }
        do {
            guard let existing = try container.store.place(id: existingId) else {
                loadError = "这个地点已经不存在了，可能已被删除。"
                activePlaceId = nil
                return
            }
            name = existing.name
            address = existing.address ?? ""
            latitudeText = String(existing.latitude)
            longitudeText = String(existing.longitude)
            radiusMeters = existing.radiusMeters
            confirmedByUser = existing.confirmedByUser
            rules = try container.store.geoRules(placeId: existingId)
            loadError = nil
        } catch {
            loadError = "读取这个地点失败：\(error)"
        }
    }

    private func reloadRules() {
        guard let placeId = activePlaceId else {
            rules = []
            return
        }
        rules = (try? container.store.geoRules(placeId: placeId)) ?? []
        // 规则或地点变了就必须重新注册：区域监控是按地点标识注册的，
        // 不取消旧注册会留下一条永远不会被清理的野监控（还会耗电）。
        // 放在这里是因为保存地点、启停规则、删除规则、新增规则最终都会调用它。
        Task { await container.proactiveGeo.applyRuleChanges() }
    }

    private func parsedCoordinate(_ text: String, range: ClosedRange<Double>) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), range.contains(value) else {
            return nil
        }
        return value
    }

    private func trimmedAddress() -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func savePlace() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            message = "请先填写地点名称。"
            return
        }
        guard let latitude = parsedCoordinate(latitudeText, range: -90...90) else {
            message = "纬度需要是 -90 到 90 之间的数字。"
            return
        }
        guard let longitude = parsedCoordinate(longitudeText, range: -180...180) else {
            message = "经度需要是 -180 到 180 之间的数字。"
            return
        }
        guard radiusMeters > 0 else {
            message = "半径需要大于 0。"
            return
        }

        do {
            if let existingId = activePlaceId {
                guard let existing = try container.store.place(id: existingId) else {
                    message = "这个地点已经不存在了，可能已被删除。"
                    return
                }
                var updated = existing
                updated.name = trimmedName
                updated.address = trimmedAddress()
                updated.latitude = latitude
                updated.longitude = longitude
                updated.radiusMeters = radiusMeters
                // 坐标系在界面上不可选：当前两个入口（CoreLocation 定位、手工输入经纬度）
                // 给的都是 WGS-84。这里显式写死而不是留着不动，是为了让将来接入
                // 地图选点（会返回 GCJ-02）的人一眼看到「必须在这里按选点来源赋值」。
                updated.coordinateSystem = .wgs84
                updated.confirmedByUser = confirmedByUser
                try container.store.updatePlace(updated, at: Date())
                message = confirmedByUser
                    ? "地点已更新。规则会按新的坐标和半径判断。"
                    : "地点已更新，但还没有确认，规则不会触发。"
            } else {
                let now = RFC3339.utcString(from: Date())
                let record = PlaceRecord(
                    id: DayCueID.new(),
                    name: trimmedName,
                    latitude: latitude,
                    longitude: longitude,
                    radiusMeters: radiusMeters,
                    coordinateSystem: .wgs84,
                    address: trimmedAddress(),
                    confirmedByUser: confirmedByUser,
                    createdAt: now,
                    updatedAt: now
                )
                let inserted = try container.store.insertPlace(record, at: Date())
                activePlaceId = inserted.id
                message = "地点已保存。现在可以在下面添加规则了。"
            }
            reloadRules()
        } catch {
            message = "保存地点失败：\(error)"
        }
    }

    private func enabledBinding(_ rule: GeoRuleRecord) -> Binding<Bool> {
        Binding(
            get: { rule.enabled },
            set: { newValue in
                var updated = rule
                updated.enabled = newValue
                do {
                    try container.store.updateGeoRule(updated, at: Date())
                    reloadRules()
                } catch {
                    message = "更新规则失败：\(error)"
                }
            }
        )
    }

    private func deleteRule(_ rule: GeoRuleRecord) {
        do {
            try container.store.softDeleteGeoRule(id: rule.id, at: Date())
            reloadRules()
            message = "规则已删除。"
        } catch {
            message = "删除规则失败：\(error)"
        }
    }

    private func addRule() {
        guard let placeId = activePlaceId else {
            message = "先保存地点，再添加规则。"
            return
        }
        let trimmedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedTitle.isEmpty ? defaultRuleTitle(placeName: placeName) : trimmedTitle
        let bodyText = newBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = RFC3339.utcString(from: Date())

        let record = GeoRuleRecord(
            id: DayCueID.new(),
            placeId: placeId,
            trigger: newTrigger,
            title: title,
            body: bodyText.isEmpty ? nil : bodyText,
            minDwellSeconds: newTrigger == .dwell ? newMinDwellMinutes * 60 : 0,
            cooldownSeconds: newCooldownMinutes * 60,
            activeFromLocal: newUsesWindow ? ClockEditing.text(minutes: newFromMinutes) : nil,
            activeToLocal: newUsesWindow ? ClockEditing.text(minutes: newToMinutes) : nil,
            weekdays: GeoRuleWeekdays.encode(Array(newWeekdays)),
            enabled: true,
            expiresAtUTC: nil,
            createdAt: now,
            updatedAt: now
        )

        do {
            _ = try container.store.insertGeoRule(record, at: Date())
            reloadRules()
            newTitle = ""
            newBody = ""
            message = "规则已添加。位置不可用或没有权限时它不会被触发，也不会用别的方式推断。"
        } catch {
            message = "添加规则失败：\(error)"
        }
    }

    private func defaultRuleTitle(placeName: String) -> String {
        let target = placeName.isEmpty ? "这个地点" : placeName
        switch newTrigger {
        case .enter: return "到达\(target)"
        case .exit: return "离开\(target)"
        case .dwell: return "在\(target)停留"
        }
    }
}
