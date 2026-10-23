import SwiftUI
import PersistedCore

struct MenuSchedulePage: View {
    @Bindable var model: AppModel
    let delete: (LayoutSchedule) -> Void
    @State private var editing: LayoutSchedule?
    private var eligibleLayouts: [PersistedCore.Layout] { model.library.layouts.filter { !$0.importedNeedsMapping } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let draft = editing {
                    ScheduleEditor(model: model, schedule: draft) { editing = nil }.id(draft.id)
                } else {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("A layout for your day").font(.title3.weight(.semibold))
                            Text("Focus at nine. Calls after lunch.").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { createSchedule() } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderedProminent).disabled(eligibleLayouts.isEmpty)
                            .accessibilityLabel("Add schedule")
                    }
                    if model.library.schedules.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "clock").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                            Text("No schedules yet").font(.headline)
                            Text(eligibleLayouts.isEmpty ? "Save a layout or map an imported layout to start scheduling." : "Choose a layout, a time window, and the days it should apply.")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Add schedule") { createSchedule() }.disabled(eligibleLayouts.isEmpty)
                        }.frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                    ForEach(model.library.schedules) { schedule in
                        VStack(alignment: .leading, spacing: 11) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(schedule.name).font(.headline)
                                    Text(model.library.layouts.first { $0.id == schedule.layoutID }?.name ?? "Unavailable layout")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("Enable \(schedule.name)", isOn: Binding(get: { schedule.enabled }, set: { value in
                                    var changed = schedule; changed.enabled = value; model.upsertSchedule(changed)
                                })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            }
                            HStack {
                                Label("\(time(schedule.startMinute)) – \(time(schedule.endMinute))", systemImage: "clock")
                                Spacer()
                                Button("Edit") { editing = schedule }.buttonStyle(.link)
                                Button { delete(schedule) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).accessibilityLabel("Delete \(schedule.name)")
                            }.font(.caption)
                            Text(days(schedule.weekdays) + (schedule.startMinute > schedule.endMinute ? " · Ends next day" : ""))
                                .font(.caption2).foregroundStyle(.secondary)
                        }.padding(14).background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 11))
                    }
                    Text("Applies once during each time window when the saved displays are available and Accessibility is enabled. Times use this Mac’s time zone. If schedules overlap, the first matching schedule takes priority.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(18)
        }.scrollIndicators(.visible)
    }
    private func createSchedule() {
        guard let layout = eligibleLayouts.first(where: { $0.id == model.selectedLayoutID }) ?? eligibleLayouts.first else { return }
        editing = LayoutSchedule(name: "", layoutID: layout.id, weekdays: [2, 3, 4, 5, 6], startMinute: 540, endMinute: 720)
    }
    private func time(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
    private func days(_ selected: Set<Int>) -> String {
        if selected.count == 7 { return "Every day" }
        if selected == Set([2, 3, 4, 5, 6]) { return "Weekdays" }
        return [2, 3, 4, 5, 6, 7, 1].filter { selected.contains($0) }.map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
    }
}

private struct ScheduleEditor: View {
    let model: AppModel
    @State var schedule: LayoutSchedule
    var finished: () -> Void
    private var valid: Bool { schedule.isValid && model.library.layouts.contains { $0.id == schedule.layoutID && !$0.importedNeedsMapping } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.library.schedules.contains { $0.id == schedule.id } ? "Edit schedule" : "New schedule").font(.title3.weight(.semibold))
            TextField("Name, e.g. Deep work", text: $schedule.name).textFieldStyle(.roundedBorder)
            Picker("Layout", selection: $schedule.layoutID) {
                ForEach(model.library.layouts.filter { !$0.importedNeedsMapping }) { Text($0.name).tag($0.id) }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Days").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                        Button {
                            if schedule.weekdays.contains(day) { schedule.weekdays.remove(day) }
                            else { schedule.weekdays.insert(day) }
                        } label: {
                            Text(Calendar.current.veryShortWeekdaySymbols[day - 1]).font(.callout.weight(.medium))
                                .frame(maxWidth: .infinity).frame(height: 32)
                                .background(schedule.weekdays.contains(day) ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                                .foregroundStyle(schedule.weekdays.contains(day) ? Color.accentColor : Color.secondary)
                        }.buttonStyle(.plain)
                            .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                            .accessibilityValue(schedule.weekdays.contains(day) ? "Selected" : "Not selected")
                    }
                }
            }
            HStack {
                DatePicker("From", selection: minuteBinding(\.startMinute), displayedComponents: .hourAndMinute)
                Spacer(minLength: 12)
                DatePicker("Until", selection: minuteBinding(\.endMinute), displayedComponents: .hourAndMinute)
            }
            if schedule.startMinute > schedule.endMinute {
                Label("Continues into the following day", systemImage: "moon").font(.caption).foregroundStyle(.secondary)
            } else if schedule.startMinute == schedule.endMinute {
                Text("Choose different start and end times.").font(.caption).foregroundStyle(.orange)
            }
            Toggle("Enable this schedule", isOn: $schedule.enabled).toggleStyle(.switch).controlSize(.small)
            Text("The layout is applied once per window. Your manual changes are then left alone until the next scheduled window.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", action: finished).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save schedule") {
                    schedule.name = schedule.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.upsertSchedule(schedule)
                    if model.errorMessage == nil { finished() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
    }
    private func minuteBinding(_ keyPath: WritableKeyPath<LayoutSchedule, Int>) -> Binding<Date> {
        Binding(get: {
            let value = schedule[keyPath: keyPath]
            return Calendar.current.date(bySettingHour: value / 60, minute: value % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            schedule[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }
}
