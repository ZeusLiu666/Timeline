import Foundation

@main
struct TimelineDateSupportTests {
    static func main() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
            utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        }
        let ordered = [date(2027, 3, 1), date(2027, 1, 1), date(2026, 12, 31), date(2026, 2, 1), date(2025, 12, 31), date(2025, 1, 1)]
        let markers = ordered.indices.map { index in
            TimelineDateSupport.showsYear(for: ordered[index], previousDate: index > 0 ? ordered[index - 1] : nil, calendar: utc)
        }
        precondition(markers == [true, false, true, false, true, false], "Years belong to the latest visible record of each descending year group")
        precondition(TimelineDateSupport.showsYear(for: date(2026, 10, 16), previousDate: nil, calendar: utc), "A one-record timeline needs a year anchor")
        precondition(!TimelineDateSupport.showsYear(for: date(2026, 10, 16), previousDate: date(2026, 10, 16), calendar: utc), "Same-day records must not repeat the year")
        let withTodayPlaceholder = [date(2026, 10, 16), date(2026, 10, 15), date(2026, 2, 1), date(2025, 12, 31), date(2025, 1, 1)]
        let placeholderMarkers = withTodayPlaceholder.indices.map { index in
            TimelineDateSupport.showsYear(for: withTodayPlaceholder[index], previousDate: index > 0 ? withTodayPlaceholder[index - 1] : nil, calendar: utc)
        }
        precondition(placeholderMarkers == [true, false, false, true, false], "A today placeholder anchors its year and older rows do not duplicate it")
        precondition(TimelineDateSupport.showsYear(for: date(2027, 1, 1), previousDate: nil, calendar: utc), "A New Year placeholder anchors the new year")
        precondition(TimelineDateSupport.showsYear(for: date(2026, 12, 31), previousDate: date(2027, 1, 1), calendar: utc), "The latest previous-year record retains its year below a New Year placeholder")
        var shanghai = utc
        shanghai.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let localNewYear = date(2025, 12, 31, hour: 16)
        let localPreviousYear = date(2025, 12, 31, hour: 15, minute: 59)
        precondition(TimelineDateSupport.showsYear(for: localNewYear, previousDate: localPreviousYear, calendar: shanghai), "A year boundary uses the person's local calendar")
        precondition(!TimelineDateSupport.showsYear(for: localNewYear, previousDate: localPreviousYear, calendar: utc), "The same instants remain within one UTC year")
        print("PASS: latest year anchors, today placeholder, same-day records, local New Year")
    }
}
