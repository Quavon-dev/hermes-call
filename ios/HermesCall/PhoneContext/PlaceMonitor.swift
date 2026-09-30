import CoreLocation
import Foundation
import HermesCallCore
import MapKit
import os
@preconcurrency import UserNotifications

/// Place reminders (`geofence` capability): this phone watches the places itself with `CLMonitor` and
/// shows a local notification. The phone's location never leaves it; the agent learns that a reminder
/// fired only when the owner's rule for place reminders is Yes (Ask: a button in the notification).
@MainActor @Observable
final class PlaceMonitor {
    static let shared = PlaceMonitor()
    nonisolated static let notificationCategory = "place"
    nonisolated static let tellAction = "tell"
    /// CLMonitor reports the state it finds right after a region is added; that is not an arrival.
    static let settleSeconds: TimeInterval = 60

    private(set) var reminders: [PlaceReminder] = []
    /// Sends "you arrived" to the agent that set the reminder (ChatModel.send), wired at launch.
    var tellAgent: ((String, UUID?) async -> Void)?

    private let store = PlaceReminderStore.shared
    private let settings = PhoneAccessSettings()
    private let log = Logger(subsystem: "de.quavon.hermescall", category: "places")
    private let locationManager = CLLocationManager()
    /// Created once; concurrent callers await the same task (two monitors would double every event).
    private var monitorTask: Task<CLMonitor, Never>?
    private var monitor: CLMonitor?
    private var started = false
    /// Last state per reminder id, so only real transitions fire.
    private var lastState: [String: CLMonitor.Event.State] = [:]

    /// Called at launch (also when iOS relaunches the app in the background for a region event).
    func start() {
        guard !started else { return }
        started = true
        Task {
            reminders = await store.all()
            if !reminders.isEmpty { _ = await ensureMonitor() }
        }
    }

    /// Creates the monitor once, brings its regions in line with the stored reminders and listens for events.
    private func ensureMonitor() async -> CLMonitor {
        if let monitorTask { return await monitorTask.value }
        let task = Task { await self.makeMonitor() }
        monitorTask = task
        return await task.value
    }

    private func makeMonitor() async -> CLMonitor {
        let monitor = await CLMonitor("hermes-call-places")
        self.monitor = monitor
        let watched = await Set(monitor.identifiers)
        // The event stream starts by reporting each region's current state: that is not an arrival.
        // Seed from the monitor's own (persisted) records so only real changes fire.
        for id in watched {
            if let state = await monitor.record(for: id)?.lastEvent.state { lastState[id] = state }
        }
        for reminder in reminders where !watched.contains(reminder.id) { await watch(reminder, on: monitor) }
        for id in watched where !reminders.contains(where: { $0.id == id }) { await monitor.remove(id) }
        Task { [weak self] in
            do {
                for try await event in await monitor.events {
                    await self?.handle(event)
                }
            } catch {
                self?.log.error("place events stopped: \(error.localizedDescription, privacy: .public)")
            }
        }
        return monitor
    }

    private func watch(_ reminder: PlaceReminder, on monitor: CLMonitor) async {
        let condition = CLMonitor.CircularGeographicCondition(
            center: CLLocationCoordinate2D(latitude: reminder.latitude, longitude: reminder.longitude), radius: reminder.radius)
        await monitor.add(condition, identifier: reminder.id)
    }

    // MARK: agent queries

    func handle(_ query: PhoneQuery, profileID: UUID) async throws -> [String: JSON] {
        guard let request = GeofenceRequest.parse(query.params) else { throw PhoneSourceUnavailable() }
        switch request {
        case .list:
            return ["reminders": .array(await store.all().map { .object($0.summary) })]
        case .remove(let id):
            return ["removed": .bool(await remove(id))]
        case .add(let title, let note, let place, let trigger, let repeats):
            guard await store.all().count < PlaceReminderStore.maxReminders else { throw PhoneSourceUnavailable() }
            let resolved = try await resolve(place)
            let reminder = PlaceReminder(title: title, note: note, placeName: resolved.name, latitude: resolved.coordinate.latitude,
                                         longitude: resolved.coordinate.longitude, radius: resolved.radius, trigger: trigger,
                                         repeats: repeats, profileID: profileID)
            try await store.add(reminder)
            reminders = await store.all()
            requestAlwaysAuthorization()
            await watch(reminder, on: await ensureMonitor())
            return ["id": .string(reminder.id), "resolved_name": .string(resolved.name)]
        }
    }

    /// Owner or agent removes a reminder.
    @discardableResult
    func remove(_ id: String) async -> Bool {
        let removed = await store.remove(id)
        reminders = await store.all()
        lastState[id] = nil
        await monitor?.remove(id)
        return removed
    }

    func deleteAll() async {
        for reminder in reminders { await monitor?.remove(reminder.id) }
        await store.deleteAll()
        reminders = []
        lastState = [:]
    }

    /// Region events wake the app in the background only with "Always"; asked when the first reminder is set.
    private func requestAlwaysAuthorization() {
        switch locationManager.authorizationStatus {
        case .notDetermined: locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: locationManager.requestAlwaysAuthorization()
        default: break
        }
    }

    // MARK: place search (on the phone, near the owner)

    private struct Resolved {
        let name: String
        let coordinate: CLLocationCoordinate2D
        let radius: Double
    }

    private func resolve(_ place: GeofenceRequest.Place) async throws -> Resolved {
        switch place {
        case .coordinate(let latitude, let longitude, let radius):
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            return Resolved(name: await placeName(coordinate) ?? String(format: "%.4f, %.4f", latitude, longitude),
                            coordinate: coordinate, radius: radius)
        case .query(let text):
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            request.resultTypes = [.pointOfInterest, .address]
            if let here = try? await currentLocation() {
                // Apple Maps gets only an area around you: the centre rounded to ≈ 5 km, never the exact position.
                let area = CLLocationCoordinate2D(latitude: (here.coordinate.latitude * 20).rounded() / 20,
                                                  longitude: (here.coordinate.longitude * 20).rounded() / 20)
                request.region = MKCoordinateRegion(center: area, latitudinalMeters: 30_000, longitudinalMeters: 30_000)
            }
            guard let item = try await MKLocalSearch(request: request).start().mapItems.first else { throw PhoneSourceUnavailable() }
            let locality = item.addressRepresentations?.cityName
            let name = [item.name, locality].compactMap { $0 }.joined(separator: ", ")
            return Resolved(name: name.isEmpty ? text : String(name.prefix(120)), coordinate: item.location.coordinate,
                            radius: GeofenceRequest.defaultRadius)
        }
    }

    private func placeName(_ coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first else { return nil }
        let name = [item.name, item.addressRepresentations?.cityName].compactMap { $0 }.joined(separator: ", ")
        return name.isEmpty ? nil : String(name.prefix(120))
    }

    private func currentLocation() async throws -> CLLocation {
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        return try await withTimeout(seconds: 8) {
            for try await update in CLLocationUpdate.liveUpdates() {
                if let location = update.location { return location }
                if update.authorizationDenied { throw PhoneSourceUnavailable() }
            }
            throw PhoneSourceUnavailable()
        }
    }

    // MARK: events

    private func handle(_ event: CLMonitor.Event) async {
        let id = event.identifier
        let previous = lastState[id]
        lastState[id] = event.state
        guard let reminder = await store.reminder(id) else { return }
        let fired = switch reminder.trigger {
        case .enter: event.state == .satisfied
        case .exit: event.state == .unsatisfied
        }
        let isTransition = previous.map { $0 != event.state }
            ?? (Date().timeIntervalSince(reminder.created) > Self.settleSeconds)
        guard fired, isTransition else { return }
        log.info("place reminder fired")
        await notify(reminder)
        if !reminder.repeats { await remove(id) }
        if settings.permission(for: .geofence) == .yes { await tellAgent?(Self.message(for: reminder), reminder.profileID) }
    }

    static func message(for reminder: PlaceReminder) -> String {
        let verb = reminder.trigger == .enter ? "arrived at" : "left"
        let note = reminder.note.map { " (\($0))" } ?? ""
        return "📍 I \(verb) \(reminder.placeName). Reminder: \(reminder.title)\(note)"
    }

    private func notify(_ reminder: PlaceReminder) async {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        let verb = reminder.trigger == .enter ? "You're at" : "You left"
        content.body = [reminder.note, "\(verb) \(reminder.placeName)."].compactMap { $0 }.joined(separator: "\n")
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        // Ask: the owner decides per reminder whether the agent hears about it.
        if settings.permission(for: .geofence) == .ask {
            content.categoryIdentifier = Self.notificationCategory
            content.userInfo = ["place_message": Self.message(for: reminder), "profile": reminder.profileID?.uuidString ?? ""]
        }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "place-\(reminder.id)-\(Date().timeIntervalSince1970)",
                                                                                content: content, trigger: nil))
    }
}
