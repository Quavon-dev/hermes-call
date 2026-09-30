// SPDX-License-Identifier: MIT
import Foundation

/// Dates as the chat shows them: relative words for the last two days, like Messages.
public enum ChatDates {
    /// Search hits: "Today, 2:05 PM", "Yesterday, 9:12 AM", "Sep 3, 9:12 AM"; another year: "Dec 24, 2025".
    public static func hitLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = date.formatted(style(calendar, locale).hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return "\(date.formatted(style(calendar, locale).month(.abbreviated).day())), \(time)"
        }
        return date.formatted(style(calendar, locale).month(.abbreviated).day().year())
    }

    /// The chat list: the time today, "Yesterday", the weekday within the last week, then the date.
    public static func listLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let base = style(calendar, locale)
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(base.hour().minute()) }
        let startOfToday = calendar.startOfDay(for: now)
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday), date >= yesterday { return "Yesterday" }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo {
            return date.formatted(base.weekday(.wide))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(base.month(.abbreviated).day()) }
        var numeric = Date.FormatStyle(date: .numeric, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        numeric = numeric.year(.twoDigits)
        return date.formatted(numeric)
    }

    private static func style(_ calendar: Calendar, _ locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    }
}
