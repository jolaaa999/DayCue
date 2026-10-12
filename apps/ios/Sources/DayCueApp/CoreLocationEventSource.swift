import Foundation
import CoreLocation
import DayCueCore

/// CoreLocation 适配器：把系统的区域回调变成与平台无关的语义事件。
///
/// 它只做三件事，别的都不做——这样以后接 Android/别的定位源时，
/// 判定与编排逻辑（都在 DayCueCore）可以原样复用：
/// 1. 把 CLLocation 的坐标、时间戳、水平精度拆成 RawLocationObservation；
/// 2. 交给 LocationEventNormalizer 做新鲜度判定；
/// 3. 只把通过判定的事件回调出去，被丢弃的走 onDiscardedEvent 并带上中文原因。
///
/// 为什么不在适配器里自己写「多旧算旧」：那会让同一条产品底线出现两份实现，
/// 测试也只能测到其中一份。
///
/// 定位策略：只做区域监控 + 临时的 requestLocation() 单次取点，
/// **不**调用 startUpdatingLocation，因此不会为了主动提醒持续取位置。
final class CoreLocationEventSource: NSObject, LocationEventSource, CLLocationManagerDelegate {

    /// 区域标识统一前缀，便于从 CLRegion.identifier 反推 place id。
    static let regionIdentifierPrefix = "daycue.geo.place."

    static func regionIdentifier(placeId: String) -> String {
        regionIdentifierPrefix + placeId
    }

    static func placeId(fromRegionIdentifier identifier: String) -> String? {
        guard identifier.hasPrefix(regionIdentifierPrefix) else { return nil }
        let placeId = String(identifier.dropFirst(regionIdentifierPrefix.count))
        return placeId.isEmpty ? nil : placeId
    }

    /// 把系统的授权状态与定位开关映射成 DayCue 的能力语义。
    /// 单独抽成 static，是为了让映射规则只有一处，方便在报告里逐条核对。
    static func capability(for status: CLAuthorizationStatus, servicesEnabled: Bool) -> LocationCapability {
        guard servicesEnabled else { return .servicesDisabled }
        switch status {
        case .authorizedAlways:
            return .available
        case .authorizedWhenInUse:
            // 只有前台权限：能触发，但 App 没打开时收不到区域事件，必须如实标注。
            return .foregroundOnly
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .failed(reason: "系统返回了未知的定位授权状态")
        }
    }

    private let manager = CLLocationManager()
    private let freshnessPolicy: LocationFreshnessPolicy

    private var placesById: [String: PlaceRecord] = [:]
    private var monitoredPlaceIdsStorage: Set<String> = []
    private var insideSinceByPlaceId: [String: Date] = [:]
    private var lastStateByPlaceId: [String: GeoRegionState] = [:]
    private var pendingTransitions: [String: LocationEventKind] = [:]
    private var pendingDwellCheck = false
    private var dwellTimer: Timer?

    var onSemanticEvent: ((LocationSemanticEvent) -> Void)?
    var onDiscardedEvent: ((LocationEventDiscard) -> Void)?
    var onCapabilityChange: ((LocationCapability) -> Void)?

    init(freshnessPolicy: LocationFreshnessPolicy = .standard) {
        self.freshnessPolicy = freshnessPolicy
        super.init()
        manager.delegate = self
        // 区域监控本身由系统负责，不需要高精度持续定位；
        // 单次取点用 requestLocation，精度按百米级足够判断「在不在这个区域」。
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    deinit {
        dwellTimer?.invalidate()
    }

    // MARK: - 能力

    var capability: LocationCapability {
        Self.capability(
            for: manager.authorizationStatus,
            servicesEnabled: CLLocationManager.locationServicesEnabled()
        )
    }

    var monitoredPlaceIds: Set<String> { monitoredPlaceIdsStorage }

    @discardableResult
    func refreshCapability() -> LocationCapability {
        let current = capability
        onCapabilityChange?(current)
        return current
    }

    func requestAuthorizationIfNeeded() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    /// 申请后台定位。用户拒绝也不会报错，能力只是停在 .foregroundOnly，
    /// 由界面如实告诉用户「App 没打开时不会触发」。
    func requestBackgroundAuthorizationIfNeeded() {
        guard manager.authorizationStatus == .authorizedWhenInUse else { return }
        manager.requestAlwaysAuthorization()
    }

    // MARK: - 注册

    func startMonitoring(places: [PlaceRecord]) {
        for place in places {
            placesById[place.id] = place
            guard place.confirmedByUser else { continue }
            guard place.radiusMeters > 0 else { continue }
            guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
                onCapabilityChange?(.failed(reason: "这台设备不支持区域监控"))
                continue
            }

            let radius = min(place.radiusMeters, manager.maximumRegionMonitoringDistance)
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                radius: radius,
                identifier: Self.regionIdentifier(placeId: place.id)
            )
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
            monitoredPlaceIdsStorage.insert(place.id)
        }
        startDwellTimerIfNeeded()
    }

    func stopMonitoring(placeIds: [String]) {
        for placeId in placeIds {
            let identifier = Self.regionIdentifier(placeId: placeId)
            for region in manager.monitoredRegions where region.identifier == identifier {
                manager.stopMonitoring(for: region)
            }
            monitoredPlaceIdsStorage.remove(placeId)
            placesById.removeValue(forKey: placeId)
            insideSinceByPlaceId.removeValue(forKey: placeId)
            lastStateByPlaceId.removeValue(forKey: placeId)
            pendingTransitions.removeValue(forKey: placeId)
        }
        if monitoredPlaceIdsStorage.isEmpty {
            dwellTimer?.invalidate()
            dwellTimer = nil
        }
    }

    func stopAllMonitoring() {
        stopMonitoring(placeIds: Array(monitoredPlaceIdsStorage))
    }

    // MARK: - 停留自检

    /// 区域回调只在进出时触发，停留时长没人替我们数，所以用一个前台定时器补出来。
    /// 只在「还有地点在监控中」时运行，且只发起单次取点，不做持续定位。
    private func startDwellTimerIfNeeded() {
        guard dwellTimer == nil else { return }
        dwellTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkDwell()
        }
    }

    private func checkDwell() {
        guard capability.isUsable else { return }
        guard !placesById.isEmpty else { return }
        guard lastStateByPlaceId.values.contains(.inside) else { return }
        pendingDwellCheck = true
        manager.requestLocation()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let placeId = Self.placeId(fromRegionIdentifier: region.identifier) else { return }
        let now = Date()
        if insideSinceByPlaceId[placeId] == nil {
            insideSinceByPlaceId[placeId] = now
        }
        lastStateByPlaceId[placeId] = .inside
        pendingTransitions[placeId] = .entered
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let placeId = Self.placeId(fromRegionIdentifier: region.identifier) else { return }
        insideSinceByPlaceId.removeValue(forKey: placeId)
        lastStateByPlaceId[placeId] = .outside
        pendingTransitions[placeId] = .exited
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let now = Date()

        let transitions = pendingTransitions
        pendingTransitions.removeAll()
        for (placeId, kind) in transitions {
            emit(placeId: placeId, kind: kind, location: location, now: now)
        }

        guard pendingDwellCheck, transitions.isEmpty else { return }
        pendingDwellCheck = false
        for (placeId, state) in lastStateByPlaceId where state == .inside {
            guard let insideSince = insideSinceByPlaceId[placeId] else {
                // 不知道从什么时候开始待着：如实说不知道，不用「现在」冒充起始时刻。
                emit(
                    placeId: placeId,
                    kind: .indeterminate(reason: "连不上这次停留的起始时刻"),
                    location: location,
                    now: now
                )
                continue
            }
            emit(placeId: placeId, kind: .dwell(insideSince: insideSince), location: location, now: now)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        onCapabilityChange?(.failed(reason: error.localizedDescription))
        // 这次取点失败：把待处理的迁移如实转成「无法确定」，而不是悄悄吞掉。
        let transitions = pendingTransitions
        pendingTransitions.removeAll()
        pendingDwellCheck = false
        let now = Date()
        for (placeId, _) in transitions {
            emit(
                placeId: placeId,
                kind: .indeterminate(reason: error.localizedDescription),
                location: nil,
                now: now
            )
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onCapabilityChange?(capability)
    }

    // MARK: - 事件出口

    /// 发射前统一过一遍新鲜度判定。被丢弃的事件带中文原因，不用陈旧坐标触发提醒。
    private func emit(placeId: String, kind: LocationEventKind, location: CLLocation?, now: Date) {
        // 拿不到 CLLocation 时不能沿用 entered/exited 的语义——那会变成「凭回调猜坐标」。
        let resolvedKind: LocationEventKind
        if location == nil, kind.trigger != nil {
            resolvedKind = .indeterminate(reason: "系统没有给出可用的坐标")
        } else {
            resolvedKind = kind
        }

        let observation = RawLocationObservation(
            placeId: placeId,
            kind: resolvedKind,
            observedAt: location?.timestamp ?? now,
            horizontalAccuracyMeters: location?.horizontalAccuracy ?? 0,
            capability: capability,
            now: now
        )

        switch LocationEventNormalizer.normalize(observation, policy: freshnessPolicy) {
        case let .accepted(event):
            onSemanticEvent?(event)
        case let .discarded(reason, isSilent):
            onDiscardedEvent?(LocationEventDiscard(
                placeId: placeId,
                reason: reason,
                isSilent: isSilent,
                at: now
            ))
        }
    }
}
