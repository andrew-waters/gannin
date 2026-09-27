import Foundation
import Observation
import SwiftUI

/// Where a person's bank holidays come from: a country, and optionally one
/// of its regions (such as `GB-SCT`), as the Nager.Date public holiday API
/// names them.
struct BankHolidayRegion: Codable, Hashable {
    var country: String
    var subdivision: String?

    /// England, Scotland and so on rather than their codes, where known.
    static func subdivisionName(_ code: String) -> String {
        let names = ["GB-ENG": "England", "GB-WLS": "Wales", "GB-SCT": "Scotland", "GB-NIR": "Northern Ireland"]
        return names[code] ?? code
    }
}

struct BankHoliday: Codable, Hashable {
    /// `yyyy-MM-dd`, a calendar day wherever the person is.
    let date: String
    let name: String
    /// Regions it applies to; nil when it's national.
    let counties: [String]?
    let global: Bool

    func applies(to region: BankHolidayRegion) -> Bool {
        global || (region.subdivision.map { counties?.contains($0) ?? false } ?? false)
    }
}

/// A person's working days: the org's working week less their bank holidays.
struct WorkingCalendar {
    var week: WorkWeek
    /// Bank holiday names by `yyyy-MM-dd`.
    var holidays: [String: String] = [:]
    /// Set by hand for the person; otherwise their commits suggest one.
    var timeZone: TimeZone?

    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return key(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    static func key(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// The local midnight a `yyyy-MM-dd` key names.
    static func date(_ key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    func holiday(on date: Date, calendar: Calendar = .current) -> String? {
        holidays[Self.key(date, calendar: calendar)]
    }

    func isWorkingDay(_ date: Date, calendar: Calendar = .current) -> Bool {
        week.isWorkingDay(date, in: calendar) && holiday(on: date, calendar: calendar) == nil
    }
}

/// Public holidays by country and year from date.nager.at, cached in
/// Application Support. Only the country code and year are sent.
@Observable
final class BankHolidayStore {
    struct Country: Codable, Hashable {
        let countryCode: String
        let name: String
    }

    private(set) var countries: [Country] = []
    /// Holidays by "GB 2026".
    private(set) var holidays: [String: [BankHoliday]] = [:]
    private var loading: Set<String> = []

    init() {
        countries = (try? Self.read([Country].self, "Countries")) ?? []
    }

    /// The person's working calendar for the years given, from what's loaded.
    func calendar(week: WorkWeek, region: BankHolidayRegion?, years: ClosedRange<Int>) -> WorkingCalendar {
        var calendar = WorkingCalendar(week: week)
        guard let region else { return calendar }
        for year in years {
            for holiday in holidays[Self.cacheKey(region.country, year)] ?? [] where holiday.applies(to: region) {
                calendar.holidays[holiday.date] = holiday.name
            }
        }
        return calendar
    }

    /// Regions with holidays of their own in the country, from its loaded years.
    func subdivisions(of country: String) -> [String] {
        let codes = holidays.filter { $0.key.hasPrefix("\(country) ") }.values.flatMap { $0.flatMap { $0.counties ?? [] } }
        return Set(codes).sorted()
    }

    /// Loads the regions' holidays for the years, from disk or the API.
    func load(_ regions: Set<BankHolidayRegion>, years: ClosedRange<Int>) async {
        for country in Set(regions.map(\.country)) {
            for year in years {
                await load(country: country, year: year)
            }
        }
    }

    func loadCountries() async {
        guard countries.isEmpty, !loading.contains("countries") else { return }
        loading.insert("countries")
        defer { loading.remove("countries") }
        guard let url = URL(string: "https://date.nager.at/api/v3/AvailableCountries"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let list = try? JSONDecoder().decode([Country].self, from: data) else { return }
        countries = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        Self.write(countries, "Countries")
    }

    private func load(country: String, year: Int) async {
        let key = Self.cacheKey(country, year)
        guard holidays[key] == nil, !loading.contains(key) else { return }
        if let cached = try? Self.read([BankHoliday].self, key) {
            holidays[key] = cached
            return
        }
        loading.insert(key)
        defer { loading.remove(key) }
        guard let url = URL(string: "https://date.nager.at/api/v3/PublicHolidays/\(year)/\(country)"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode([BankHoliday].self, from: data) else { return }
        holidays[key] = list
        Self.write(list, key)
    }

    private static func cacheKey(_ country: String, _ year: Int) -> String { "\(country) \(year)" }

    // MARK: Disk cache

    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "BankHolidays", directoryHint: .isDirectory)
    }

    private static func read<Value: Decodable>(_ type: Value.Type, _ name: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(contentsOf: directory.appending(path: "\(name).json")))
    }

    private static func write<Value: Encodable>(_ value: Value, _ name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: directory.appending(path: "\(name).json"), options: .atomic)
        }
    }
}

extension PeopleDatesStore {
    /// Each person's bank holiday region: their own, else the org's.
    func region(for login: String, in org: String, default orgRegion: BankHolidayRegion?) -> BankHolidayRegion? {
        dates(for: login, in: org).holidayRegion ?? orgRegion
    }

    /// Their working calendar: their own pattern or the org's week, less
    /// their bank holidays, in their time zone if one is set.
    func workingCalendar(for login: String, in org: String, orgWeek: WorkWeek, holidays: BankHolidayStore, years: ClosedRange<Int>) -> WorkingCalendar {
        let dates = dates(for: login, in: org)
        var calendar = holidays.calendar(week: dates.workWeek ?? orgWeek, region: dates.holidayRegion ?? orgWeek.holidays, years: years)
        calendar.timeZone = dates.timeZone.flatMap(TimeZone.init(identifier:))
        return calendar
    }
}

/// Picks a country and region for bank holidays.
struct BankHolidayRegionPicker: View {
    @Environment(BankHolidayStore.self) private var store

    let title: String
    /// What no choice means here: "None" for the org, the org's for a person.
    let noneLabel: String
    @Binding var selection: BankHolidayRegion?

    var body: some View {
        Group {
            pickers
        }
        .task(id: selection?.country) {
            await store.loadCountries()
            if let country = selection?.country {
                let year = Calendar.current.component(.year, from: .now)
                await store.load([BankHolidayRegion(country: country)], years: year...year)
            }
        }
    }

    @ViewBuilder
    private var pickers: some View {
        Picker(title, selection: countryBinding) {
            Text(noneLabel).tag(String?.none)
            if let country = selection?.country, !store.countries.contains(where: { $0.countryCode == country }) {
                Text(country).tag(Optional(country))
            }
            ForEach(store.countries, id: \.countryCode) { country in
                Text(country.name).tag(Optional(country.countryCode))
            }
        }
        if let region = selection {
            let subdivisions = store.subdivisions(of: region.country)
            if !subdivisions.isEmpty {
                Picker("Region", selection: subdivisionBinding) {
                    Text("National holidays only").tag(String?.none)
                    ForEach(subdivisions, id: \.self) { Text(BankHolidayRegion.subdivisionName($0)).tag(Optional($0)) }
                }
            }
        }
    }

    private var countryBinding: Binding<String?> {
        Binding {
            selection?.country
        } set: { country in
            selection = country.map { BankHolidayRegion(country: $0) }
        }
    }

    private var subdivisionBinding: Binding<String?> {
        Binding {
            selection?.subdivision
        } set: { subdivision in
            guard let country = selection?.country else { return }
            selection = BankHolidayRegion(country: country, subdivision: subdivision)
        }
    }
}
