// NonEmptyReminderFieldTests.swift
// AG-05 | feat/ag05-resident-readonly-candidate
//
// Rigorous verification of non-empty reminder fields:
// - Title, multiline notes, unicode/emoji fidelity
// - Completion status and completionDate
// - Priority mapping (0, 1=High, 5=Medium, 9=Low)
// - Due dates: timed with timezone vs. all-day (no hour/min)
// - Daylight Saving Time (DST) transition semantics
// - Round-trip JSON encoding/decoding

import XCTest
@testable import EventKitBridge

final class NonEmptyReminderFieldTests: XCTestCase {

    // MARK: - 1. Title, Multiline Notes & Unicode/Emoji Fidelity
    func testTitleAndNotesFidelity() throws {
        let multilineNotes = """
        第一行：投保人需求确认
        第二行：重大疾病险保额 ¥1,000,000
        第三行：特约免赔额条款说明（附录 A）
        """
        let title = "📋 尊享安心重疾险保单复核 (高优先 ⚠️)"

        let item = ReminderItem(
            itemID: "item-unicode-01",
            title: title,
            isCompleted: false,
            dueDate: Date(timeIntervalSince1970: 1794200000),
            priority: 1,
            notes: multilineNotes,
            listID: "fixture-list-rich-01",
            isAllDay: false,
            timeZone: "Asia/Shanghai"
        )

        XCTAssertEqual(item.title, title)
        XCTAssertEqual(item.notes, multilineNotes)
        XCTAssertTrue(item.title.contains("⚠️"))
        XCTAssertTrue(item.notes?.contains("¥1,000,000") == true)
        XCTAssertEqual(item.notes?.components(separatedBy: "\n").count, 3)
    }

    // MARK: - 2. Completion Status and Completion Date
    func testCompletionStatusAndDate() throws {
        let created = Date(timeIntervalSince1970: 1794000000)
        let completed = Date(timeIntervalSince1970: 1794050000)

        let completedItem = ReminderItem(
            itemID: "item-completed-01",
            title: "已完成保费划扣",
            isCompleted: true,
            dueDate: nil,
            priority: 0,
            notes: "系统自动扣款成功",
            listID: "fixture-list-rich-01",
            completionDate: completed,
            creationDate: created
        )

        XCTAssertTrue(completedItem.isCompleted)
        XCTAssertEqual(completedItem.completionDate, completed)
        XCTAssertEqual(completedItem.creationDate, created)

        let pendingItem = ReminderItem(
            itemID: "item-pending-01",
            title: "待核保任务",
            isCompleted: false,
            dueDate: nil,
            priority: 5,
            notes: nil,
            listID: "fixture-list-rich-01"
        )

        XCTAssertFalse(pendingItem.isCompleted)
        XCTAssertNil(pendingItem.completionDate)
    }

    // MARK: - 3. Priority Levels
    func testPriorityLevels() throws {
        let pNone = ReminderItem(itemID: "p0", title: "无优先级", priority: 0, listID: "list-1")
        let pHigh = ReminderItem(itemID: "p1", title: "高优先级", priority: 1, listID: "list-1")
        let pMed  = ReminderItem(itemID: "p5", title: "中优先级", priority: 5, listID: "list-1")
        let pLow  = ReminderItem(itemID: "p9", title: "低优先级", priority: 9, listID: "list-1")

        XCTAssertEqual(pNone.priority, 0)
        XCTAssertEqual(pHigh.priority, 1)
        XCTAssertEqual(pMed.priority, 5)
        XCTAssertEqual(pLow.priority, 9)
    }

    // MARK: - 4. Timed Due Date with Explicit TimeZone
    func testTimedDueDateWithExplicitTimeZone() throws {
        var cal = Calendar(identifier: .gregorian)
        guard let tzShanghai = TimeZone(identifier: "Asia/Shanghai") else {
            XCTFail("Missing Asia/Shanghai timezone")
            return
        }
        cal.timeZone = tzShanghai

        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 9
        components.hour = 14
        components.minute = 30
        components.second = 0
        components.timeZone = tzShanghai

        guard let dueDate = cal.date(from: components) else {
            XCTFail("Failed to construct date")
            return
        }

        let item = ReminderItem(
            itemID: "item-timed-01",
            title: "下午预约回访",
            isCompleted: false,
            dueDate: dueDate,
            priority: 1,
            notes: "下午 14:30 准时拨打电话",
            listID: "list-1",
            isAllDay: false,
            timeZone: "Asia/Shanghai"
        )

        XCTAssertFalse(item.isAllDay)
        XCTAssertEqual(item.timeZone, "Asia/Shanghai")
        XCTAssertEqual(item.dueDate, dueDate)

        // Verify hour in Asia/Shanghai is 14
        let extractedHour = cal.component(.hour, from: item.dueDate!)
        XCTAssertEqual(extractedHour, 14)
    }

    // MARK: - 5. All-Day Due Date Semantics
    func testAllDayDueDateSemantics() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 10
        // All-day: hour, minute, second are nil
        components.hour = nil
        components.minute = nil

        let allDayDate = cal.date(from: components)

        let item = ReminderItem(
            itemID: "item-allday-01",
            title: "全天合规审查节点",
            isCompleted: false,
            dueDate: allDayDate,
            priority: 5,
            notes: "当日任意时间完成提交即可",
            listID: "list-1",
            isAllDay: true,
            timeZone: nil
        )

        XCTAssertTrue(item.isAllDay)
        XCTAssertNil(item.timeZone)
        XCTAssertNotNil(item.dueDate)
    }

    // MARK: - 6. Daylight Saving Time (DST) Transition Semantics
    func testDaylightSavingTimeTransition() throws {
        guard let tzNY = TimeZone(identifier: "America/New_York") else {
            XCTFail("Missing America/New_York timezone")
            return
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tzNY

        // 2026 DST ends in US on Sunday, November 1, 2026 (clocks go back 1h at 02:00)
        // 1) Saturday Oct 31, 2026 12:00 EDT (UTC-4)
        var compEDT = DateComponents()
        compEDT.year = 2026
        compEDT.month = 10
        compEDT.day = 31
        compEDT.hour = 12
        compEDT.minute = 0
        compEDT.timeZone = tzNY
        let dateEDT = cal.date(from: compEDT)!

        // 2) Monday Nov 2, 2026 12:00 EST (UTC-5)
        var compEST = DateComponents()
        compEST.year = 2026
        compEST.month = 11
        compEST.day = 2
        compEST.hour = 12
        compEST.minute = 0
        compEST.timeZone = tzNY
        let dateEST = cal.date(from: compEST)!

        XCTAssertTrue(tzNY.isDaylightSavingTime(for: dateEDT))
        XCTAssertFalse(tzNY.isDaylightSavingTime(for: dateEST))

        let itemEDT = ReminderItem(
            itemID: "item-dst-edt",
            title: "Pre-DST Call",
            dueDate: dateEDT,
            listID: "list-1",
            timeZone: "America/New_York"
        )
        let itemEST = ReminderItem(
            itemID: "item-dst-est",
            title: "Post-DST Call",
            dueDate: dateEST,
            listID: "list-1",
            timeZone: "America/New_York"
        )

        // Difference in elapsed wall-clock hours: 48h + 1h = 49 real hours
        let diffSeconds = itemEST.dueDate!.timeIntervalSince(itemEDT.dueDate!)
        XCTAssertEqual(diffSeconds, 49 * 3600, "DST transition adds 1 hour to real elapsed time across 'fall back'")
    }

    // MARK: - 7. Round-Trip JSON Serialization & Deserialization
    func testRoundTripJSONSerialization() throws {
        let originalItems = [
            ReminderItem(
                itemID: "rt-01",
                title: "核保任务 A",
                isCompleted: true,
                dueDate: Date(timeIntervalSince1970: 1794124800),
                priority: 1,
                notes: "第一条详细说明",
                listID: "list-1",
                isAllDay: false,
                timeZone: "Asia/Shanghai",
                completionDate: Date(timeIntervalSince1970: 1794130000),
                creationDate: Date(timeIntervalSince1970: 1794000000),
                url: "https://example.com/policy/12345"
            ),
            ReminderItem(
                itemID: "rt-02",
                title: "全天备忘 B",
                isCompleted: false,
                dueDate: Date(timeIntervalSince1970: 1794182400),
                priority: 5,
                notes: nil,
                listID: "list-1",
                isAllDay: true,
                timeZone: nil
            )
        ]

        let encoder = JSONEncoder()
        let data = try encoder.encode(originalItems)

        let decoder = JSONDecoder()
        let decodedItems = try decoder.decode([ReminderItem].self, from: data)

        XCTAssertEqual(decodedItems.count, 2)
        XCTAssertEqual(decodedItems[0].itemID, "rt-01")
        XCTAssertEqual(decodedItems[0].title, "核保任务 A")
        XCTAssertTrue(decodedItems[0].isCompleted)
        XCTAssertEqual(decodedItems[0].priority, 1)
        XCTAssertEqual(decodedItems[0].notes, "第一条详细说明")
        XCTAssertEqual(decodedItems[0].isAllDay, false)
        XCTAssertEqual(decodedItems[0].timeZone, "Asia/Shanghai")
        XCTAssertEqual(decodedItems[0].url, "https://example.com/policy/12345")

        XCTAssertEqual(decodedItems[1].itemID, "rt-02")
        XCTAssertEqual(decodedItems[1].title, "全天备忘 B")
        XCTAssertFalse(decodedItems[1].isCompleted)
        XCTAssertEqual(decodedItems[1].priority, 5)
        XCTAssertNil(decodedItems[1].notes)
        XCTAssertEqual(decodedItems[1].isAllDay, true)
    }

    // MARK: - 8. FakeEventKitStore Rich Non-Empty Reminders Query
    func testFakeStoreReturnsRichNonEmptyReminders() async throws {
        let verifier = SourceVerifier(
            allowedSourceTypes: ["caldav"],
            allowedSourceTitles: ["iCloud"],
            listBindings: [
                "fake-list-icloud-rich": SourceIdentity(sourceID: "src-icloud-primary", sourceType: "calDAV", sourceTitle: "iCloud")
            ],
            requireExplicitBinding: true
        )
        let store = FakeEventKitStore(sourceVerifier: verifier, isAuthorized: true)
        let items = try await store.fetchReminders(listID: "fake-list-icloud-rich")

        XCTAssertEqual(items.count, 4)

        // Find unicode item
        guard let unicodeItem = items.first(where: { $0.itemID == "r-rich-04" }) else {
            XCTFail("r-rich-04 missing in fake store")
            return
        }
        XCTAssertTrue(unicodeItem.title.contains("投保人回访"))
        XCTAssertEqual(unicodeItem.priority, 1)
        XCTAssertTrue(unicodeItem.notes?.contains("确认医疗补充险保额") == true)

        // Find all-day item
        guard let allDayItem = items.first(where: { $0.itemID == "r-rich-02" }) else {
            XCTFail("r-rich-02 missing in fake store")
            return
        }
        XCTAssertTrue(allDayItem.isAllDay)

        // Find completed item
        guard let completedItem = items.first(where: { $0.itemID == "r-rich-03" }) else {
            XCTFail("r-rich-03 missing in fake store")
            return
        }
        XCTAssertTrue(completedItem.isCompleted)
        XCTAssertNotNil(completedItem.completionDate)
    }
}
