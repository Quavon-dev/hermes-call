// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import HermesCallCore

struct ChatDatesTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        return calendar
    }()
    let locale = Locale(identifier: "en_US")

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    var now: Date { date(2026, 9, 30, 18) }

    /// Foundation puts a narrow no-break space before AM/PM.
    func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

    @Test func searchHitsSayTodayAndYesterday() {
        #expect(plain(ChatDates.hitLabel(date(2026, 9, 30, 14, 5), now: now, calendar: calendar, locale: locale)) == "Today, 2:05 PM")
        #expect(plain(ChatDates.hitLabel(date(2026, 9, 29, 9, 12), now: now, calendar: calendar, locale: locale)) == "Yesterday, 9:12 AM")
        #expect(plain(ChatDates.hitLabel(date(2026, 9, 3, 9, 12), now: now, calendar: calendar, locale: locale)) == "Sep 3, 9:12 AM")
        #expect(plain(ChatDates.hitLabel(date(2025, 12, 24, 9, 12), now: now, calendar: calendar, locale: locale)) == "Dec 24, 2025")
    }

    @Test func chatListShowsTimeTodayThenDays() {
        #expect(plain(ChatDates.listLabel(date(2026, 9, 30, 14, 5), now: now, calendar: calendar, locale: locale)) == "2:05 PM")
        #expect(plain(ChatDates.listLabel(date(2026, 9, 29, 9), now: now, calendar: calendar, locale: locale)) == "Yesterday")
        #expect(plain(ChatDates.listLabel(date(2026, 9, 26, 9), now: now, calendar: calendar, locale: locale)) == "Saturday")
        #expect(plain(ChatDates.listLabel(date(2026, 9, 3, 9), now: now, calendar: calendar, locale: locale)) == "Sep 3")
        #expect(plain(ChatDates.listLabel(date(2025, 12, 24), now: now, calendar: calendar, locale: locale)) == "12/24/25")
    }
}
