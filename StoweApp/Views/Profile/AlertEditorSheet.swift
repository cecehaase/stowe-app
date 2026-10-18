import SwiftUI
import MapKit
import CoreLocation

/// Creates or edits a personal alert: a plain reminder, or a spending check-in that tells you how
/// much is left (per week on a schedule, or per trip at a place).
struct AlertEditorSheet: View {
    enum Kind: String, CaseIterable { case schedule = "Schedule", place = "Place" }
    enum Repeat: String, CaseIterable { case weekly = "Weekly", monthly = "Monthly", once = "Once" }

    @Environment(AlertManager.self) var alerts
    @Environment(BudgetStore.self) var store
    @Environment(\.dismiss) var dismiss
    @Environment(\.openURL) var openURL

    private let existing: PersonalAlert?

    // Common
    @State private var kind: Kind = .schedule
    @State private var isSpending = true
    @State private var title = ""
    @State private var message = ""
    @State private var categoryIDs: Set<UUID> = []
    // Schedule
    @State private var repeatMode: Repeat = .weekly
    @State private var weekdays: Set<Int> = [1, 7]
    @State private var time = Calendar.current.date(from: DateComponents(hour: 10, minute: 0)) ?? .now
    @State private var date = Date.now
    // Place
    @State private var placeName = ""
    @State private var radius = 150.0
    @State private var onEntry = true
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var pin: CLLocationCoordinate2D?
    @State private var splitByVisits = false
    @State private var visitsPerWeek = 1.0
    @State private var liveOnArrival = false

    init(alert: PersonalAlert? = nil) {
        existing = alert
        guard let alert else { return }
        _title = State(initialValue: alert.title)
        _message = State(initialValue: alert.message)
        _isSpending = State(initialValue: alert.spending != nil)
        _categoryIDs = State(initialValue: Set(alert.spending?.categoryIDs ?? []))
        _splitByVisits = State(initialValue: alert.spending?.visitsPerWeek != nil)
        _visitsPerWeek = State(initialValue: alert.spending?.visitsPerWeek ?? 1)
        _liveOnArrival = State(initialValue: alert.spending?.liveOnArrival ?? false)
        switch alert.trigger {
        case let .calendar(d, monthly):
            _repeatMode = State(initialValue: monthly ? .monthly : .once)
            _date = State(initialValue: d)
        case let .weekly(days, hour, minute):
            _weekdays = State(initialValue: Set(days))
            _time = State(initialValue: Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? .now)
        case let .location(name, lat, lon, r, entry):
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            _kind = State(initialValue: .place)
            _placeName = State(initialValue: name)
            _radius = State(initialValue: r)
            _onEntry = State(initialValue: entry)
            _pin = State(initialValue: coordinate)
            _camera = State(initialValue: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500)))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Trigger", selection: $kind) { ForEach(Kind.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented)

                Section {
                    Toggle("Spending check-in", isOn: $isSpending)
                    TextField(isSpending ? "Title (optional)" : "Title (e.g. Rent due)", text: $title)
                    if !isSpending { TextField("Message", text: $message) }
                } footer: {
                    if isSpending {
                        Text(kind == .schedule
                             ? "Tells you what to aim for this week based on what's left this month."
                             : "Tells you what's left when you arrive, optionally split per trip.")
                    }
                }

                if kind == .schedule { scheduleSection } else { placeSections }

                if isSpending {
                    categoriesSection
                    if kind == .place { splitSection; liveSection }
                    previewSection
                }
            }
            .navigationTitle(existing == nil ? "New alert" : "Edit alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
            .onAppear { if existing == nil { applyRecommendedVisits() } }
        }
    }

    // MARK: Schedule

    @ViewBuilder private var scheduleSection: some View {
        Section("When") {
            Picker("Repeats", selection: $repeatMode) { ForEach(Repeat.allCases, id: \.self) { Text($0.rawValue) } }
            if repeatMode == .weekly {
                HStack(spacing: 6) {
                    ForEach(Weekday.ordered, id: \.number) { day in
                        let selected = weekdays.contains(day.number)
                        Button {
                            if selected { weekdays.remove(day.number) } else { weekdays.insert(day.number) }
                        } label: {
                            Text(day.symbol)
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .background(selected ? Theme.marine : Theme.evergreen, in: Circle())
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Calendar.current.weekdaySymbols[day.number - 1])
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                HStack {
                    Button("Every weekend") { weekdays = [1, 7] }
                    Spacer()
                    Button("Weekdays") { weekdays = [2, 3, 4, 5, 6] }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
            } else {
                DatePicker(repeatMode == .monthly ? "First reminder" : "When", selection: $date)
            }
        }
    }

    // MARK: Place

    @ViewBuilder private var placeSections: some View {
        Section {
            TextField("Place name (e.g. Trader Joe's)", text: $placeName)
            MapReader { proxy in
                Map(position: $camera) {
                    if let pin {
                        Marker(placeName, coordinate: pin).tint(Theme.marine)
                        MapCircle(center: pin, radius: radius).foregroundStyle(Theme.sage.opacity(0.3))
                    }
                }
                .onTapGesture { pin = proxy.convert($0, from: .local) }
            }
            .frame(height: 220)
            Slider(value: $radius, in: 50...1000, step: 50) { Text("Radius") }
            Toggle("Notify on arrival (off = on leaving)", isOn: $onEntry)
        } header: {
            Text("Where")
        } footer: {
            Text(pin == nil ? "Tap the map to drop a pin." : "Radius \(Int(radius)) m")
        }
    }

    @ViewBuilder private var splitSection: some View {
        let measured = store.measuredVisitsPerWeek(in: Array(categoryIDs))
        Section {
            Toggle("Split into a per-trip target", isOn: $splitByVisits)
            if splitByVisits {
                Stepper(value: $visitsPerWeek, in: 0.5...14, step: 0.5) {
                    Text("About \(visitsPerWeek.formatted(.number.precision(.fractionLength(0...1))))× a week")
                }
                if let measured {
                    let recommended = SpendingReminderText.recommendedVisits(measured)
                    HStack {
                        Text("Recommended: \(recommended.formatted(.number.precision(.fractionLength(0...1))))× a week")
                            .foregroundStyle(Theme.sage)
                        Spacer()
                        if recommended != visitsPerWeek {
                            Button("Use") { visitsPerWeek = recommended }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        } header: {
            Text("How often do you go?")
        } footer: {
            if splitByVisits {
                if let measured {
                    Text("Based on your history: you've spent in \(categoryPhrase) on about \(measured.formatted(.number.precision(.fractionLength(1)))) days a week over the last 12 weeks. What's left is divided by the trips left this month.")
                } else {
                    Text("Not enough history yet to recommend a number. What's left is divided by the trips left this month.")
                }
            }
        }
    }

    @ViewBuilder private var liveSection: some View {
        Section {
            Toggle("Update the amount when I arrive", isOn: $liveOnArrival)
                .onChange(of: liveOnArrival) { _, on in
                    if on && !alerts.hasAlwaysLocation { alerts.requestAlwaysLocation() }
                }
            if liveOnArrival && !alerts.hasAlwaysLocation {
                Button("Open Settings to allow Always") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        } footer: {
            if liveOnArrival && alerts.hasAlwaysLocation {
                Text("Stowe checks your budget the moment you arrive, so the amount is up to date.")
            } else if liveOnArrival {
                Text("This needs location access set to Always. With While Using, arrival alerts still appear, but the amount is from Stowe's last refresh, not the moment you arrive.")
            } else {
                Text("Arrival alerts still appear, but show the amount from Stowe's last refresh (when you open the app or in the background), not the moment you arrive.")
            }
        }
    }

    // MARK: Categories & preview

    @ViewBuilder private var categoriesSection: some View {
        Section {
            Button { categoryIDs = [] } label: {
                HStack {
                    Label("Whole budget", systemImage: "sum")
                    Spacer()
                    if categoryIDs.isEmpty { Image(systemName: "checkmark") }
                }
            }
            ForEach(store.categories) { c in
                Button {
                    if categoryIDs.contains(c.id) { categoryIDs.remove(c.id) } else { categoryIDs.insert(c.id) }
                } label: {
                    HStack {
                        Label(c.name, systemImage: c.icon)
                        Spacer()
                        if categoryIDs.contains(c.id) { Image(systemName: "checkmark") }
                    }
                }
            }
        } header: {
            Text("Applies to")
        } footer: {
            Text("Pick one or more categories, or leave it on Whole budget.")
        }
        .onChange(of: categoryIDs) { if existing == nil || !splitByVisits { applyRecommendedVisits() } }
    }

    @ViewBuilder private var previewSection: some View {
        if let alert = makeAlert(), let preview = alerts.previewMessage(for: alert) {
            Section("Preview") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.title).font(.headline)
                    Text(preview.body).font(.subheadline)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var categoryPhrase: String {
        SpendingReminderText.phrase(for: store.categoryNames(for: Array(categoryIDs)))
    }

    /// Defaults the visits stepper to what history suggests for the chosen categories.
    private func applyRecommendedVisits() {
        if let measured = store.measuredVisitsPerWeek(in: Array(categoryIDs)) {
            visitsPerWeek = SpendingReminderText.recommendedVisits(measured)
        }
    }

    // MARK: Save

    private var canSave: Bool {
        switch kind {
        case .schedule:
            if !isSpending && title.trimmingCharacters(in: .whitespaces).isEmpty { return false }
            return repeatMode != .weekly || !weekdays.isEmpty
        case .place:
            return pin != nil && (isSpending || !title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func makeAlert() -> PersonalAlert? {
        let trigger: AlertTrigger
        switch kind {
        case .schedule:
            switch repeatMode {
            case .weekly:
                let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                trigger = .weekly(weekdays: weekdays.sorted(), hour: c.hour ?? 10, minute: c.minute ?? 0)
            case .monthly: trigger = .calendar(date: date, repeatsMonthly: true)
            case .once: trigger = .calendar(date: date, repeatsMonthly: false)
            }
        case .place:
            guard let pin else { return nil }
            trigger = .location(name: placeName, latitude: pin.latitude, longitude: pin.longitude,
                                radiusMeters: radius, onEntry: onEntry)
        }
        let spending = isSpending
            ? SpendingReminder(categoryIDs: store.categories.map(\.id).filter(categoryIDs.contains),
                               visitsPerWeek: kind == .place && splitByVisits ? visitsPerWeek : nil,
                               liveOnArrival: kind == .place && liveOnArrival)
            : nil
        return PersonalAlert(id: existing?.id ?? UUID(),
                             title: title.trimmingCharacters(in: .whitespaces),
                             message: message,
                             trigger: trigger,
                             isEnabled: existing?.isEnabled ?? true,
                             spending: spending)
    }

    private func save() {
        guard let alert = makeAlert() else { return }
        if existing == nil { alerts.add(alert) } else { alerts.update(alert) }
        if !alerts.notificationsAuthorized { Task { await alerts.requestPermissions() } }
        dismiss()
    }
}
