@preconcurrency import Contacts
import CoreLocation
import CoreMotion
import EventKit
import Foundation
import HermesCallCore
import Intents
import MapKit
import MediaPlayer
import Network
import UIKit

/// iOS refused or cannot provide the data: the answer is `unavailable`.
struct PhoneSourceUnavailable: Error {}

/// Reads one capability's data from iOS (only after the owner's No/Ask/Yes rule allowed it).
/// Each answer carries exactly the fields listed in docs/protocol.md, nothing else.
@MainActor
enum PhoneSources {
    static func fetch(_ query: PhoneQuery) async throws -> [String: JSON] {
        switch query.capability {
        case .location: try await location(precise: query.precise)
        case .battery: try battery()
        case .device: await device()
        case .calendar: try await calendar(days: query.days, limit: query.limit)
        case .reminders: try await reminders(limit: query.limit)
        case .contacts: try await contacts(named: query.name)
        case .motion: try await motion()
        case .focus: try await focus()
        case .nowPlaying: try await nowPlaying()
        case .health: try await HealthSource.summary()
        case .home: try await HomeSource.snapshot()
        case .clipboard: clipboard()
        case .photos, .files: throw PhoneSourceUnavailable()  // picked in the prompt, see PhoneContextModel
        case .geofence: throw PhoneSourceUnavailable()  // PlaceMonitor, see PhoneContextModel
        case .reminderCreate: try await addReminder(query.newItem)
        case .calendarCreate: try await addEvent(query.newItem)
        }
    }

    nonisolated static func iso(_ date: Date) -> JSON { .string(Date.ISO8601FormatStyle(timeZone: .current).format(date)) }

    // MARK: location

    static func location(precise: Bool) async throws -> [String: JSON] {
        // Keeps the "when in use" authorization (and asks for it the first time) while we read.
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        // With Precise Location off iOS only gives coarse fixes: take the first one.
        let reduced = CLLocationManager().accuracyAuthorization == .reducedAccuracy
        let found = try await withTimeout(seconds: 20) {
            for try await update in CLLocationUpdate.liveUpdates() {
                if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
                    throw PhoneSourceUnavailable()
                }
                if let location = update.location, location.horizontalAccuracy >= 0,
                   reduced || location.horizontalAccuracy < (precise ? 100 : 3000) {
                    return location
                }
            }
            throw PhoneSourceUnavailable()
        }
        var data: [String: JSON] = ["time": iso(found.timestamp)]
        if precise {
            data["lat"] = .double(found.coordinate.latitude)
            data["lon"] = .double(found.coordinate.longitude)
            data["accuracy_m"] = .int(Int64(found.horizontalAccuracy.rounded()))
        } else {
            data["lat"] = .double(PhoneAnswer.coarse(found.coordinate.latitude))
            data["lon"] = .double(PhoneAnswer.coarse(found.coordinate.longitude))
            data["accuracy_m"] = .int(Int64(max(1000, found.horizontalAccuracy.rounded())))
        }
        if let item = try? await MKReverseGeocodingRequest(location: found)?.mapItems.first {
            var place: [String: JSON] = [:]
            if precise, let name = item.name { place["name"] = .string(name) }
            if let city = item.addressRepresentations?.cityName { place["locality"] = .string(city) }
            if let region = item.addressRepresentations?.regionName { place["country"] = .string(region) }
            if !place.isEmpty { data["place"] = .object(place) }
        }
        return data
    }

    // MARK: device

    static func battery() throws -> [String: JSON] {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = false }
        guard device.batteryLevel >= 0 else { throw PhoneSourceUnavailable() }  // e.g. the Simulator
        let state = switch device.batteryState {
        case .charging: "charging"
        case .full: "full"
        case .unplugged: "unplugged"
        default: "unknown"
        }
        return ["level": .double((Double(device.batteryLevel) * 100).rounded() / 100), "state": .string(state),
                "low_power": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled)]
    }

    static func device() async -> [String: JSON] {
        let path = await currentPath()
        let network = if path.status != .satisfied { "none" }
            else if path.usesInterfaceType(.wifi) { "wifi" }
            else if path.usesInterfaceType(.cellular) { "cellular" }
            else if path.usesInterfaceType(.wiredEthernet) { "wired" }
            else { "none" }
        let free = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        let thermal = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        return ["model": .string(UIDevice.current.model), "system": .string("iOS \(UIDevice.current.systemVersion)"),
                "network": .string(network), "expensive": .bool(path.isExpensive),
                "storage_free_gb": .double((Double(free) / 1e9 * 10).rounded() / 10), "thermal": .string(thermal),
                "timezone": .string(TimeZone.current.identifier), "locale": .string(Locale.current.identifier)]
    }

    private static func currentPath() async -> NWPath {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        for await path in monitor { return path }
        return monitor.currentPath
    }

    // MARK: calendar and reminders

    static func calendar(days: Int, limit: Int) async throws -> [String: JSON] {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else { throw PhoneSourceUnavailable() }
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: start)) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }.prefix(limit)
        return ["events": .array(events.map { event in
            var item: [String: JSON] = ["title": .string(String((event.title ?? "Event").prefix(200))), "start": iso(event.startDate),
                                        "end": iso(event.endDate), "all_day": .bool(event.isAllDay),
                                        "calendar": .string(event.calendar?.title ?? "")]
            if let place = event.location, !place.isEmpty { item["location"] = .string(String(place.prefix(200))) }
            return .object(item)
        })]
    }

    static func reminders(limit: Int) async throws -> [String: JSON] {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else { throw PhoneSourceUnavailable() }
        return ["reminders": .array(await openReminders(store, limit: limit))]
    }

    /// EventKit calls back on its own queue: made outside the main actor (see AudioThreadTests).
    nonisolated static func openReminders(_ store: EKEventStore, limit: Int) async -> [JSON] {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let sorted = (reminders ?? []).sorted {
                    ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture)
                }
                continuation.resume(returning: sorted.prefix(limit).map { reminder in
                    var item: [String: JSON] = ["title": .string(String((reminder.title ?? "Reminder").prefix(200))),
                                                "list": .string(reminder.calendar?.title ?? ""), "priority": .int(Int64(reminder.priority))]
                    if let due = reminder.dueDateComponents?.date { item["due"] = iso(due) }
                    return .object(item)
                })
            }
        }
    }

    // MARK: adding reminders and events (write capabilities)

    /// Adds the reminder to the default list; the answer is `{ok: true, id}`.
    static func addReminder(_ item: PhoneNewItem?) async throws -> [String: JSON] {
        guard let item else { throw PhoneSourceUnavailable() }
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders(), let list = store.defaultCalendarForNewReminders() else {
            throw PhoneSourceUnavailable()
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = item.title
        reminder.notes = item.notes
        if let due = item.due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
        return ["ok": true, "id": .string(reminder.calendarItemIdentifier)]
    }

    /// Adds the event to the default calendar; the answer is `{ok: true, id}`.
    static func addEvent(_ item: PhoneNewItem?) async throws -> [String: JSON] {
        guard let item, let start = item.start, let end = item.end else { throw PhoneSourceUnavailable() }
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents(), let calendar = store.defaultCalendarForNewEvents else {
            throw PhoneSourceUnavailable()
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = item.title
        event.notes = item.notes
        event.location = item.location
        event.startDate = start
        event.endDate = end
        try store.save(event, span: .thisEvent, commit: true)
        return ["ok": true, "id": .string(event.calendarItemIdentifier)]
    }

    // MARK: contacts

    static func contacts(named name: String?) async throws -> [String: JSON] {
        guard let name else { throw PhoneSourceUnavailable() }
        let store = CNContactStore()
        guard try await store.requestAccess(for: .contacts) else { throw PhoneSourceUnavailable() }
        let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                                       CNContactOrganizationNameKey as CNKeyDescriptor,
                                       CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor]
        let matches: [JSON] = try await Task.detached {
            let found = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)
            return found.prefix(5).map(contactJSON)
        }.value
        return ["contacts": .array(matches)]
    }

    private nonisolated static func contactJSON(_ contact: CNContact) -> JSON {
        var item: [String: JSON] = [
            "name": .string(CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName),
            "phones": .array(contact.phoneNumbers.prefix(5).map { phone in
                .object(["label": .string(label(phone.label)), "number": .string(phone.value.stringValue)])
            }),
            "emails": .array(contact.emailAddresses.prefix(5).map { mail in
                .object(["label": .string(label(mail.label)), "address": .string(mail.value as String)])
            }),
        ]
        if !contact.organizationName.isEmpty { item["organization"] = .string(contact.organizationName) }
        return .object(item)
    }

    private nonisolated static func label(_ raw: String?) -> String {
        raw.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? ""
    }

    // MARK: motion, focus, music, clipboard

    static func motion() async throws -> [String: JSON] {
        guard CMMotionActivityManager.isActivityAvailable() else { throw PhoneSourceUnavailable() }
        let manager = CMMotionActivityManager()
        let now = Date()
        // Converted inside the callbacks: CoreMotion's objects are not Sendable.
        let latest: (activity: String, confidence: String)? = try await withCheckedThrowingContinuation { continuation in
            manager.queryActivityStarting(from: now.addingTimeInterval(-600), to: now, to: .main) { activities, error in
                if let error { return continuation.resume(throwing: error) }
                continuation.resume(returning: activities?.last.map(describe))
            }
        }
        guard let latest else { throw PhoneSourceUnavailable() }
        var data: [String: JSON] = ["activity": .string(latest.activity), "confidence": .string(latest.confidence)]
        if CMPedometer.isStepCountingAvailable() {
            if let today = await stepsToday(CMPedometer(), now: now) {
                data["steps_today"] = .int(today.steps)
                if let meters = today.meters { data["distance_today_m"] = .int(Int64(meters.rounded())) }
            }
        }
        return data
    }

    /// CoreMotion calls back on its own queue: made outside the main actor.
    nonisolated static func stepsToday(_ pedometer: CMPedometer, now: Date) async -> (steps: Int64, meters: Double?)? {
        await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: Calendar.current.startOfDay(for: now), to: now) { data, _ in
                continuation.resume(returning: data.map { ($0.numberOfSteps.int64Value, $0.distance?.doubleValue) })
            }
        }
    }

    private nonisolated static func describe(_ last: CMMotionActivity) -> (activity: String, confidence: String) {
        let activity = if last.automotive { "automotive" } else if last.cycling { "cycling" } else if last.running { "running" }
            else if last.walking { "walking" } else if last.stationary { "stationary" } else { "unknown" }
        let confidence = switch last.confidence {
        case .high: "high"
        case .medium: "medium"
        default: "low"
        }
        return (activity, confidence)
    }

    static func focus() async throws -> [String: JSON] {
        let center = INFocusStatusCenter.default
        if center.authorizationStatus == .notDetermined { await requestFocusAuthorization() }
        guard center.authorizationStatus == .authorized, let focused = center.focusStatus.isFocused else {
            throw PhoneSourceUnavailable()
        }
        return ["focused": .bool(focused)]
    }

    static func nowPlaying() async throws -> [String: JSON] {
        if MPMediaLibrary.authorizationStatus() == .notDetermined { await requestMusicAuthorization() }
        guard MPMediaLibrary.authorizationStatus() == .authorized else { throw PhoneSourceUnavailable() }
        let player = MPMusicPlayerController.systemMusicPlayer
        var data: [String: JSON] = ["playing": .bool(player.playbackState == .playing)]
        if let item = player.nowPlayingItem {
            if let title = item.title { data["title"] = .string(title) }
            if let artist = item.artist { data["artist"] = .string(artist) }
            if let album = item.albumTitle { data["album"] = .string(album) }
        }
        return data
    }

    // iOS answers these permission requests on its own queues: made outside the main actor.

    private nonisolated static func requestFocusAuthorization() async {
        await withCheckedContinuation { continuation in
            INFocusStatusCenter.default.requestAuthorization { _ in continuation.resume() }
        }
    }

    private nonisolated static func requestMusicAuthorization() async {
        await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { _ in continuation.resume() }
        }
    }

    /// Read only after the owner tapped Allow; iOS shows its own paste notice as well.
    static func clipboard() -> [String: JSON] {
        guard UIPasteboard.general.hasStrings, let text = UIPasteboard.general.string, !text.isEmpty else {
            return ["has_text": false]
        }
        return ["has_text": true, "text": .string(String(text.prefix(8000)))]
    }
}

/// Runs `work`, giving up with `PhoneSourceUnavailable` after `seconds`.
func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw PhoneSourceUnavailable()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw PhoneSourceUnavailable() }
        return first
    }
}
