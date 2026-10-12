import SwiftUI
import DayCueCore

/// 地点列表。
///
/// 这里只保存「用户确认过的地点 + 半径」，没有任何轨迹表。
/// 顶部那段文案是承诺，不是装饰：说清楚不记录轨迹、也做不到精确室内定位。
struct PlaceListView: View {

    @EnvironmentObject private var container: AppContainer

    @State private var places: [PlaceRecord] = []
    @State private var ruleCounts: [String: Int] = [:]
    @State private var loadError: String?

    var body: some View {
        List {
            Section {
                Label("DayCue 默认不记录你的移动轨迹。", systemImage: "location.slash")
                    .font(.footnote.weight(.semibold))
                Text("这里只保存你手动确认过的地点和半径，用来判断「到了 / 离开了」。定位本身会有误差，室内尤其不准，规则可能不触发或延迟触发——它不能替代你自己确认。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 定位不可用时把原因摆出来。
            // 不显示这一段的话，用户会以为规则在正常运行，
            // 而实际上它永远不会触发 —— 这比直接报错更糟。
            GeoRuleStatusView(
                capability: container.proactiveGeo.capability,
                readiness: container.proactiveGeo.ruleReadiness,
                ruleTitle: { ruleId in
                    (try? container.store.geoRule(id: ruleId))?.title ?? ruleId
                }
            )

            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if places.isEmpty {
                Section {
                    EmptyStateView(
                        systemImage: "mappin.and.ellipse",
                        title: "还没有保存地点",
                        message: "点右上角加号，把你常去的地方（例如教学楼、图书馆）加进来，再给它配一条「到达 / 离开 / 停留」的提醒规则。"
                    )
                }
            } else {
                Section {
                    ForEach(places) { place in
                        NavigationLink {
                            PlaceEditorView(placeId: place.id)
                        } label: {
                            PlaceRow(place: place, ruleCount: ruleCounts[place.id] ?? 0)
                        }
                    }
                } footer: {
                    Text("共 \(places.count) 个地点。半径越大越容易误判，建议先用默认值试几天再调。")
                        .font(.caption)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("地点")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    PlaceEditorView(placeId: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加地点")
            }
        }
        .onAppear { reload() }
        // 进这一页就顺手把注册对齐一次：用户可能刚在系统设置里改了定位权限，
        // 也可能上次退出时进程被系统杀在注册中途。
        .task { await container.proactiveGeo.refreshRegistrations() }
    }

    private func reload() {
        do {
            places = try container.store.places()
            var counts: [String: Int] = [:]
            for rule in try container.store.geoRules() {
                counts[rule.placeId, default: 0] += 1
            }
            ruleCounts = counts
            loadError = nil
        } catch {
            places = []
            ruleCounts = [:]
            loadError = "读取本机地点失败：\(error)"
        }
    }
}

private struct PlaceRow: View {

    let place: PlaceRecord
    let ruleCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(place.name)
                    .font(.body)
                Spacer()
                if place.confirmedByUser {
                    Text("已确认")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.14), in: Capsule())
                        .foregroundStyle(.green)
                } else {
                    Text("未确认")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }

            if let address = place.address, !address.isEmpty {
                Text(address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("半径约 \(Int(place.radiusMeters.rounded())) 米 · \(ruleCount) 条规则")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
