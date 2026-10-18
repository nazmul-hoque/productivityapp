import Foundation
import Testing
@testable import TaskCore

func day(_ s: String) -> LocalDay { LocalDay(iso: s)! }

struct LocalDayTests {
    @Test func weekdays() {
        #expect(day("1970-01-01").weekday == .thursday)
        #expect(day("2026-10-14").weekday == .wednesday)
        #expect(day("2026-10-18").weekday == .sunday)
        #expect(day("2000-02-29").weekday == .tuesday)
    }

    @Test func dayNumberRoundTrips() {
        for n in stride(from: -800_000, through: 800_000, by: 997) {
            #expect(LocalDay(dayNumber: n).dayNumber == n)
        }
        #expect(day("1970-01-01").dayNumber == 0)
    }

    @Test func monthArithmeticClamps() {
        #expect(day("2026-01-31").adding(months: 1) == day("2026-02-28"))
        #expect(day("2028-01-31").adding(months: 1) == day("2028-02-29"))
        #expect(day("2026-11-15").adding(months: 3) == day("2027-02-15"))
        #expect(day("2026-03-15").adding(months: -4) == day("2025-11-15"))
        #expect(day("2028-02-29").adding(years: 1) == day("2029-02-28"))
    }

    @Test func nextWeekday() {
        let wed = day("2026-10-14")
        #expect(wed.next(.wednesday) == wed)
        #expect(wed.next(.wednesday, includingToday: false) == day("2026-10-21"))
        #expect(wed.next(.friday) == day("2026-10-16"))
        #expect(wed.next(.monday) == day("2026-10-19"))
        #expect(wed.startOfWeek == day("2026-10-12"))
    }

    @Test func isoParsing() {
        #expect(LocalDay(iso: "2026-02-30") == nil)
        #expect(LocalDay(iso: "2026-13-01") == nil)
        #expect(LocalDay(iso: "nope") == nil)
        #expect(day("2026-02-03").description == "2026-02-03")
    }

    @Test func dateConversionUsesTimeZone() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let toronto = TimeZone(identifier: "America/Toronto")!
        let instant = day("2026-10-18").date(at: TimeOfDay(hour: 22), timeZone: toronto)
        #expect(LocalDay(instant, timeZone: toronto) == day("2026-10-18"))
        #expect(LocalDay(instant, timeZone: tokyo) == day("2026-10-19"))
    }

    @Test func codableAsISOString() throws {
        let data = try JSONEncoder().encode([day("2026-10-18")])
        #expect(String(decoding: data, as: UTF8.self) == "[\"2026-10-18\"]")
        #expect(try JSONDecoder().decode([LocalDay].self, from: data) == [day("2026-10-18")])
    }
}

struct FractionalIndexTests {
    @Test func betweenEnds() {
        let a = FractionalIndex.between(nil, nil)
        let b = FractionalIndex.between(a, nil)
        let c = FractionalIndex.between(nil, a)
        #expect(c < a && a < b)
    }

    @Test func repeatedInsertionStaysOrdered() {
        // Insert repeatedly at the front, the back, and between two fixed keys.
        var keys = [FractionalIndex.first]
        for _ in 0..<200 { keys.insert(FractionalIndex.between(nil, keys.first), at: 0) }
        for _ in 0..<200 { keys.append(FractionalIndex.between(keys.last, nil)) }
        var low = keys[200], high = keys[201]
        for _ in 0..<200 {
            let mid = FractionalIndex.between(low, high)
            #expect(low < mid && mid < high)
            high = mid
        }
        low = "a"; high = "b"
        for _ in 0..<200 {
            let mid = FractionalIndex.between(low, high)
            #expect(low < mid && mid < high)
            low = mid
        }
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { !$0.hasSuffix("0") })
    }

    @Test func manyKeys() {
        let keys = FractionalIndex.keys(between: "A", "B", count: 50)
        #expect(keys.count == 50)
        #expect(keys == keys.sorted())
        #expect(keys.allSatisfy { $0 > "A" && $0 < "B" })
    }
}
