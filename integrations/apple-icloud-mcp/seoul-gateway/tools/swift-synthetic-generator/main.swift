// main.swift
// Swift Synthetic Data Generator for Seoul MCP Gateway Integration Tests
// Zero EventKit dependencies - uses pure Swift Foundation types matching EventKitBridge protocol.

import Foundation

public struct SourceIdentity: Codable {
    public let sourceID: String
    public let sourceType: String
    public let sourceTitle: String

    public init(sourceID: String, sourceType: String = "calDAV", sourceTitle: String = "iCloud") {
        self.sourceID = sourceID
        self.sourceType = sourceType
        self.sourceTitle = sourceTitle
    }
}

public struct RemindersList: Codable {
    public let listID: String
    public let title: String
    public let sourceID: String
    public let sourceType: String
    public let sourceName: String
    public let color: String
    public let isImmutable: Bool

    public init(
        listID: String,
        title: String,
        sourceID: String,
        sourceType: String = "calDAV",
        sourceName: String = "iCloud",
        color: String = "#007AFF",
        isImmutable: Bool = true
    ) {
        self.listID = listID
        self.title = title
        self.sourceID = sourceID
        self.sourceType = sourceType
        self.sourceName = sourceName
        self.color = color
        self.isImmutable = isImmutable
    }
}

public struct ReminderItem: Codable {
    public let itemID: String
    public let title: String
    public let isCompleted: Bool
    public let dueDate: Date?
    public let priority: Int
    public let notes: String?
    public let listID: String

    public init(
        itemID: String,
        title: String,
        isCompleted: Bool = false,
        dueDate: Date? = nil,
        priority: Int = 0,
        notes: String? = nil,
        listID: String
    ) {
        self.itemID = itemID
        self.title = title
        self.isCompleted = isCompleted
        self.dueDate = dueDate
        self.priority = priority
        self.notes = notes
        self.listID = listID
    }
}

func main() {
    let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
    let fileManager = FileManager.default

    // Default Swift Foundation JSONEncoder matching EventKitBridgeServer.swift
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    let testListID = "9D9A****03F3"
    let testSourceID = "src-icloud-test-01"

    // 1. Synthetic Lists
    let lists = [
        RemindersList(
            listID: testListID,
            title: "M****试",
            sourceID: testSourceID,
            sourceType: "calDAV",
            sourceName: "iCloud",
            color: "#007AFF",
            isImmutable: true
        ),
        RemindersList(
            listID: "list-second-02",
            title: "日常提醒",
            sourceID: testSourceID,
            sourceType: "calDAV",
            sourceName: "iCloud",
            color: "#34C759",
            isImmutable: true
        )
    ]
    let listsData = try! encoder.encode(lists)
    let listsPath = "\(outputDir)/synthetic_lists.json"
    try! listsData.write(to: URL(fileURLWithPath: listsPath))
    print("Generated \(listsPath) (\(listsData.count) bytes)")

    // 2. Synthetic Items (Valid with numeric Cocoa Reference Date and omitted nil fields)
    // 2026-11-10 00:00:00 UTC = 1794268800 in Unix seconds = 815961600 in Cocoa seconds
    let date1 = Date(timeIntervalSince1970: 1794268800)
    let date2 = Date(timeIntervalSince1970: 1794355200)

    let items = [
        ReminderItem(
            itemID: "item-swift-01",
            title: "Swift 合成提醒事项 1",
            isCompleted: false,
            dueDate: date1,
            priority: 1,
            notes: "核保附录条款审核",
            listID: testListID
        ),
        ReminderItem(
            itemID: "item-swift-02",
            title: "Swift 合成提醒事项 2 (无截止日期/无备注)",
            isCompleted: true,
            dueDate: nil,
            priority: 0,
            notes: nil,
            listID: testListID
        ),
        ReminderItem(
            itemID: "item-swift-03",
            title: "Swift 合成提醒事项 3",
            isCompleted: false,
            dueDate: date2,
            priority: 5,
            notes: "保单生效通知",
            listID: testListID
        )
    ]
    let itemsData = try! encoder.encode(items)
    let itemsPath = "\(outputDir)/synthetic_items.json"
    try! itemsData.write(to: URL(fileURLWithPath: itemsPath))
    print("Generated \(itemsPath) (\(itemsData.count) bytes)")

    // 3. Synthetic Cross-List Ownership Violation (itemID claims foreign listID)
    let leakedItems = [
        ReminderItem(
            itemID: "item-leaked-999",
            title: "跨列表越权条目",
            isCompleted: false,
            dueDate: date1,
            priority: 1,
            notes: "恶意注入的数据",
            listID: "unauthorized-foreign-list-id-888" // Cross-list mismatch!
        )
    ]
    let leakedData = try! encoder.encode(leakedItems)
    let leakedPath = "\(outputDir)/synthetic_mismatched_ownership.json"
    try! leakedData.write(to: URL(fileURLWithPath: leakedPath))
    print("Generated \(leakedPath) (\(leakedData.count) bytes)")

    // 4. Synthetic Invalid Date Payload (Raw JSON with unparseable non-date string)
    let invalidDateJson = """
    [
      {
        "dueDate": "INVALID_NOT_A_DATE_VALUE",
        "isCompleted": false,
        "itemID": "item-bad-date-1",
        "listID": "\(testListID)",
        "priority": 1,
        "title": "非法日期提醒条目"
      }
    ]
    """
    let invalidDatePath = "\(outputDir)/synthetic_invalid_date.json"
    try! invalidDateJson.data(using: .utf8)!.write(to: URL(fileURLWithPath: invalidDatePath))
    print("Generated \(invalidDatePath)")
}

main()
