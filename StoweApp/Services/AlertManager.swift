import Foundation
import UserNotifications
import CoreLocation
import BackgroundTasks

/// Schedules personal alerts: plain reminders and spending check-ins.
///
/// Notification text is fixed once scheduled, so spending reminders are *re-scheduled* with fresh
/// amounts whenever the budget changes, when the app becomes active, and during background refreshes.
/// Place alerts can instead be "live": with Always location access, `CLMonitor` wakes the app on
/// arrival and the amount is computed at that moment.
@MainActor
@Observable
final class AlertManager: NSObject, CLLocationManagerDelegate, UNUserNotificationCenterDelegate {
    var alerts: [PersonalAlert] = []
    var notificationsAuthorized = false
    var locationStatus: CLAuthorizationStatus = .notDetermined

    /// Source of budget numbers for spending reminders. Set once at launch.
    @ObservationIgnored weak var store: BudgetStore?

    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private let location = CLLocationManager()
    @ObservationIgnored private var monitor: CLMonitor?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?

    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let refreshTaskID = "ledgerline.refresh"
    private static let storageKey = "personalAlerts"
    private static let monitorName = "ledgerline-places"
    /// Precomputed weekly occurrences to keep queued (iOS allows 64 pending notifications in total).
    private static let weeklyOccurrences = 8

    override init() {
        super.init()
        location.delegate = self
        locationStatus = location.authorizationStatus
        center.delegate = self
        load()
    }

    var hasAlwaysLocation: Bool { locationStatus == .authorizedAlways }

    // MARK: Permissions

    func requestPermissions() async {
        notificationsAuthorized = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        location.requestWhenInUseAuthorization() // Info.plist: NSLocationWhenInUseUsageDescription
    }

    /// Asks to upgrade to Always so place reminders can be computed on arrival. iOS shows this prompt
    /// at most once; after that the user has to change it in Settings.
    func requestAlwaysLocation() {
        location.requestAlwaysAuthorization()
    }

    // MARK: Editing

    func add(_ alert: PersonalAlert) {
        alerts.append(alert)
        save()
        Task { await reschedule(alert); await syncMonitor() }
    }

    func update(_ alert: PersonalAlert) {
        guard let i = alerts.firstIndex(where: { $0.id == alert.id }) else { return }
        alerts[i] = alert
        save()
        Task { await reschedule(alert); await syncMonitor() }
    }

    func remove(_ alert: PersonalAlert) {
        alerts.removeAll { $0.id == alert.id }
        save()
        Task { await removePending(for: alert.id); await syncMonitor() }
    }

    func toggle(_ alert: PersonalAlert) {
        guard let i = alerts.firstIndex(where: { $0.id == alert.id }) else { return }
        alerts[i].isEnabled.toggle()
        save()
        let updated = alerts[i]
        Task { await reschedule(updated); await syncMonitor() }
    }

    // MARK: Refresh

    /// Re-schedules every alert with current amounts. Cheap; call whenever the budget changes.
    func refreshAll() async {
        for alert in alerts { await reschedule(alert) }
        await syncMonitor()
    }

    /// Asks iOS for a background refresh in a few hours (sync + re-schedule). iOS decides the exact time.
    static func scheduleBackgroundRefresh() async {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600)
        try? await BGTaskScheduler.shared.submitTaskRequest(request)
    }

    /// The text a spending reminder would show right now, for previews in the editor.
    func previewMessage(for alert: PersonalAlert) -> SpendingReminderText.Message? {
        guard alert.spending != nil else { return nil }
        let date: Date
        switch alert.trigger {
        case let .weekly(weekdays, hour, minute):
            date = Self.nextWeeklyDates(weekdays: weekdays, hour: hour, minute: minute, count: 1).first ?? .now
        case let .calendar(d, _): date = max(d, .now)
        case .location: date = .now
        }
        return spendingMessage(for: alert, at: date)
    }

    // MARK: Scheduling

    private func reschedule(_ alert: PersonalAlert) async {
        await removePending(for: alert.id)
        guard alert.isEnabled else { return }
        let id = alert.id.uuidString

        switch alert.trigger {
        case let .calendar(date, repeatsMonthly):
            if alert.spending != nil {
                // Precompute each upcoming occurrence so its amount and "weeks left" are right for that day.
                let dates = repeatsMonthly ? Self.nextMonthlyDates(matching: date, count: 3) : (date > .now ? [date] : [])
                for (i, d) in dates.enumerated() {
                    add("\(id)#\(i)", content: spendingContent(for: alert, at: d), trigger: Self.oneShot(at: d))
                }
            } else {
                let comps = Calendar.current.dateComponents(repeatsMonthly ? [.day, .hour, .minute] : [.year, .month, .day, .hour, .minute], from: date)
                add(id, content: staticContent(for: alert), trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: repeatsMonthly))
            }

        case let .weekly(weekdays, hour, minute):
            if alert.spending != nil {
                let dates = Self.nextWeeklyDates(weekdays: weekdays, hour: hour, minute: minute, count: Self.weeklyOccurrences)
                for (i, d) in dates.enumerated() {
                    add("\(id)#\(i)", content: spendingContent(for: alert, at: d), trigger: Self.oneShot(at: d))
                }
            } else {
                for weekday in weekdays {
                    var comps = DateComponents()
                    comps.weekday = weekday; comps.hour = hour; comps.minute = minute
                    add("\(id)#wd\(weekday)", content: staticContent(for: alert), trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true))
                }
            }

        case let .location(_, lat, lon, radius, onEntry):
            // Live place alerts are delivered by `CLMonitor` instead (see `syncMonitor`).
            if isLive(alert) { return }
            let region = CLCircularRegion(center: .init(latitude: lat, longitude: lon), radius: radius, identifier: id)
            region.notifyOnEntry = onEntry
            region.notifyOnExit = !onEntry
            let content = alert.spending != nil ? spendingContent(for: alert, at: .now) : staticContent(for: alert)
            add(id, content: content, trigger: UNLocationNotificationTrigger(region: region, repeats: true))
        }
    }

    private func add(_ identifier: String, content: UNNotificationContent, trigger: UNNotificationTrigger?) {
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    /// Removes every pending request for an alert (they share the alert's ID as a prefix).
    private func removePending(for id: UUID) async {
        let prefix = id.uuidString
        let ids = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0 == prefix || $0.hasPrefix(prefix + "#") }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: Content

    private func staticContent(for alert: PersonalAlert) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.message
        content.sound = .default
        return content
    }

    private func spendingContent(for alert: PersonalAlert, at date: Date) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        if let message = spendingMessage(for: alert, at: date) {
            content.title = message.title
            content.body = message.body
        } else {
            content.title = alert.title
            content.body = alert.message
        }
        content.sound = .default
        content.threadIdentifier = "spending"
        return content
    }

    private func spendingMessage(for alert: PersonalAlert, at date: Date) -> SpendingReminderText.Message? {
        guard let spending = alert.spending, let store else { return nil }
        let left = store.remaining(in: spending.categoryIDs, monthOf: date).double
        let names = store.categoryNames(for: spending.categoryIDs)

        switch alert.trigger {
        case let .weekly(weekdays, _, _):
            return SpendingReminderText.weekly(left: left, names: names,
                                               weeksLeft: SpendingReminderText.weeksLeft(from: date, weekdays: weekdays),
                                               weekendOnly: SpendingReminderText.isWeekendOnly(weekdays),
                                               title: alert.title)
        case .calendar:
            return SpendingReminderText.monthly(left: left, names: names,
                                                weeksLeft: SpendingReminderText.weeksLeft(from: date, weekdays: []),
                                                title: alert.title)
        case let .location(name, _, _, _, _):
            let visits = spending.visitsPerWeek.map { SpendingReminderText.visitsLeft(visitsPerWeek: $0, from: date) }
            return SpendingReminderText.place(left: left, names: names, visitsLeft: visits, placeName: name, title: alert.title)
        }
    }

    // MARK: Live place alerts (CLMonitor)

    private func isLive(_ alert: PersonalAlert) -> Bool {
        guard case .location = alert.trigger else { return false }
        return alert.isEnabled && alert.spending?.liveOnArrival == true && hasAlwaysLocation
    }

    /// Opens the place monitor and starts listening. Call at launch, including background launches:
    /// iOS relaunches the app for monitor events, and they're only delivered to an open monitor.
    func startMonitoring() async {
        guard monitor == nil else { return }
        let m = await CLMonitor(Self.monitorName)
        monitor = m
        monitorTask = Task { [weak self] in
            do {
                for try await event in await m.events {
                    self?.handle(event)
                }
            } catch {
                // Monitoring stopped (e.g. permission revoked). It restarts on next launch.
            }
        }
        await syncMonitor()
    }

    /// Makes the monitored conditions match the live place alerts. The identifier includes the
    /// geometry, so editing a place re-creates its condition while unchanged ones keep their state
    /// (re-adding would re-fire if you're already inside).
    private func syncMonitor() async {
        guard let monitor else { return }
        var wanted: [String: CLMonitor.CircularGeographicCondition] = [:]
        for alert in alerts where isLive(alert) {
            guard case let .location(_, lat, lon, radius, onEntry) = alert.trigger else { continue }
            let key = "\(alert.id.uuidString)|\(lat),\(lon),\(radius),\(onEntry)"
            wanted[key] = .init(center: .init(latitude: lat, longitude: lon), radius: radius)
        }
        let existing = Set(await monitor.identifiers)
        for id in existing where wanted[id] == nil { await monitor.remove(id) }
        for (id, condition) in wanted where !existing.contains(id) {
            await monitor.add(condition, identifier: id, assuming: .unsatisfied)
        }
    }

    private func handle(_ event: CLMonitor.Event) {
        let alertID = event.identifier.split(separator: "|").first.map(String.init)
        guard let alert = alerts.first(where: { $0.id.uuidString == alertID }), isLive(alert),
              case let .location(_, _, _, _, onEntry) = alert.trigger else { return }
        let arrived = event.state == .satisfied
        guard arrived == onEntry else { return }
        // Deliver now, with the amount as of this moment.
        add("\(alert.id.uuidString)#live-\(UUID().uuidString)", content: spendingContent(for: alert, at: .now), trigger: nil)
        // Pick up any new transactions for next time.
        Task { [weak store] in await store?.syncTransactions() }
    }

    // MARK: Dates

    private static func oneShot(at date: Date) -> UNCalendarNotificationTrigger {
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
    }

    /// The next `count` times matching any of `weekdays` at `hour:minute`, after now.
    static func nextWeeklyDates(weekdays: [Int], hour: Int, minute: Int, count: Int, after now: Date = .now,
                                calendar: Calendar = .current) -> [Date] {
        var dates: [Date] = []
        for weekday in Set(weekdays) {
            var comps = DateComponents()
            comps.weekday = weekday; comps.hour = hour; comps.minute = minute
            var next = now
            for _ in 0..<count {
                guard let d = calendar.nextDate(after: next, matching: comps, matchingPolicy: .nextTime) else { break }
                dates.append(d)
                next = d
            }
        }
        return Array(dates.sorted().prefix(count))
    }

    /// The next `count` monthly occurrences on `date`'s day and time (e.g. "the 1st at 9:00").
    static func nextMonthlyDates(matching date: Date, count: Int, after now: Date = .now,
                                 calendar: Calendar = .current) -> [Date] {
        let comps = calendar.dateComponents([.day, .hour, .minute], from: date)
        var dates: [Date] = []
        var next = now
        for _ in 0..<count {
            guard let d = calendar.nextDate(after: next, matching: comps, matchingPolicy: .previousTimePreservingSmallerComponents) else { break }
            dates.append(d)
            next = d
        }
        return dates
    }

    // MARK: Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(alerts) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let saved = try? JSONDecoder().decode([PersonalAlert].self, from: data) else { return }
        alerts = saved
    }

    // MARK: Delegates

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.locationStatus = status
            // Live alerts switch between CLMonitor and regular triggers as permission changes.
            await self.refreshAll()
        }
    }

    /// Show banners even while the app is open (iOS hides them by default in the foreground).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
