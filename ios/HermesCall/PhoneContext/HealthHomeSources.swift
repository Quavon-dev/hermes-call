import Foundation
import HealthKit
import HermesCallCore
import HomeKit

/// Health summary: a few daily numbers, read-only. iOS never tells an app whether reading was
/// denied, so missing numbers are simply left out; nothing at all → `unavailable`.
@MainActor
enum HealthSource {
    private static let store = HKHealthStore()

    static func summary() async throws -> [String: JSON] {
        guard HKHealthStore.isHealthDataAvailable() else { throw PhoneSourceUnavailable() }
        let steps = HKQuantityType(.stepCount), energy = HKQuantityType(.activeEnergyBurned)
        let resting = HKQuantityType(.restingHeartRate), sleep = HKCategoryType(.sleepAnalysis)
        try await store.requestAuthorization(toShare: [], read: [steps, energy, resting, sleep])

        let now = Date()
        let today = HKQuery.predicateForSamples(withStart: Calendar.current.startOfDay(for: now), end: now)
        var data: [String: JSON] = [:]
        if let count = await sum(steps, today, unit: .count()) { data["steps_today"] = .int(Int64(count.rounded())) }
        if let kcal = await sum(energy, today, unit: .kilocalorie()) { data["active_energy_kcal_today"] = .int(Int64(kcal.rounded())) }
        if let rate = await latest(resting, unit: .count().unitDivided(by: .minute())) {
            data["resting_heart_rate"] = .int(Int64(rate.rounded()))
        }
        if let hours = await sleepHours(sleep, until: now) { data["sleep_hours_last_night"] = .double((hours * 10).rounded() / 10) }
        guard !data.isEmpty else { throw PhoneSourceUnavailable() }
        return data
    }

    private static func sum(_ type: HKQuantityType, _ predicate: NSPredicate, unit: HKUnit) async -> Double? {
        let query = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: type, predicate: predicate), options: .cumulativeSum)
        return try? await query.result(for: store)?.sumQuantity()?.doubleValue(for: unit)
    }

    private static func latest(_ type: HKQuantityType, unit: HKUnit) async -> Double? {
        let query = HKSampleQueryDescriptor(predicates: [.quantitySample(type: type)], sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
                                            limit: 1)
        return try? await query.result(for: store).first?.quantity.doubleValue(for: unit)
    }

    /// Time asleep since 18:00 yesterday (all asleep stages).
    private static func sleepHours(_ type: HKCategoryType, until now: Date) async -> Double? {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .hour, value: -6, to: calendar.startOfDay(for: now)) ?? now
        let asleep = HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue)
        let query = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: type, predicate: HKQuery.predicateForSamples(withStart: start, end: now))],
            sortDescriptors: [])
        guard let samples = try? await query.result(for: store) else { return nil }
        let seconds = samples.filter { asleep.contains($0.value) }.reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
        return seconds > 0 ? seconds / 3600 : nil
    }
}

/// Home accessories: names, rooms, reachability and on/off state. Read-only; the app never controls them.
@MainActor
final class HomeSource: NSObject, HMHomeManagerDelegate {
    private let manager = HMHomeManager()
    private var ready: CheckedContinuation<Void, Never>?

    static func snapshot() async throws -> [String: JSON] {
        let source = HomeSource()
        return try await source.read()
    }

    private func read() async throws -> [String: JSON] {
        manager.delegate = self
        await withCheckedContinuation { continuation in
            ready = continuation
            Task {
                // Long enough for the owner to answer iOS' Home permission dialog the first time.
                try? await Task.sleep(for: .seconds(30))
                self.finish()
            }
        }
        guard manager.authorizationStatus.contains(.authorized) else { throw PhoneSourceUnavailable() }
        var total = 0
        var homes: [JSON] = []
        let readUntil = Date().addingTimeInterval(10)
        for home in manager.homes {
            var accessories: [JSON] = []
            for accessory in home.accessories where total < 100 {
                total += 1
                var item: [String: JSON] = ["name": .string(accessory.name), "category": .string(accessory.category.localizedDescription),
                                            "reachable": .bool(accessory.isReachable)]
                if let room = accessory.room?.name { item["room"] = .string(room) }
                if Date() < readUntil, let on = await powerState(accessory) { item["on"] = .bool(on) }
                accessories.append(.object(item))
            }
            homes.append(.object(["name": .string(home.name), "accessories": .array(accessories)]))
        }
        return ["homes": .array(homes)]
    }

    private func powerState(_ accessory: HMAccessory) async -> Bool? {
        guard accessory.isReachable, let characteristic = accessory.services.lazy.flatMap(\.characteristics)
            .first(where: { $0.characteristicType == HMCharacteristicTypePowerState }) else { return nil }
        // A sleeping accessory can take long to answer: fall back to the cached value after 2 s.
        let once = ResumeOnce()
        await withCheckedContinuation { continuation in
            once.continuation = continuation
            Self.read(characteristic) { Task { @MainActor in once.resume() } }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                once.resume()
            }
        }
        return characteristic.value as? Bool
    }

    /// HomeKit answers on its own queue: made outside the main actor.
    private nonisolated static func read(_ characteristic: HMCharacteristic, done: @escaping @Sendable () -> Void) {
        characteristic.readValue { _ in done() }
    }

    private func finish() {
        ready?.resume()
        ready = nil
    }

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        guard status.contains(.determined) else { return }
        Task { @MainActor in self.finish() }
    }
}

/// Resumes a continuation exactly once, whichever of several callers comes first.
@MainActor
private final class ResumeOnce {
    var continuation: CheckedContinuation<Void, Never>?

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
