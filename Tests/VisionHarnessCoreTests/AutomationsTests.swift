import XCTest
@testable import VisionHarnessCore

final class AutomationsTests: XCTestCase {
    // MARK: Cron

    func testCronNextBasicDaily() throws {
        // "30 8 * * *" — the next 08:30 strictly after the reference.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let base = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9, minute: 0))!
        let next = try XCTUnwrap(CronParser.next(after: base, expr: "30 8 * * *", timeZone: "America/Los_Angeles"))
        let parts = cal.dateComponents([.day, .hour, .minute], from: next)
        XCTAssertEqual(parts.hour, 8)
        XCTAssertEqual(parts.minute, 30)
        XCTAssertEqual(parts.day, 4)   // 09:00 is past that day's 08:30
    }

    func testCronNextWeekdays() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // 2026-11-06 is a Friday; next weekday 08:00 after Friday 10:00 is Monday the 9th.
        let friday = cal.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 10, minute: 0))!
        let next = try XCTUnwrap(CronParser.next(after: friday, expr: "0 8 * * 1-5", timeZone: "UTC"))
        XCTAssertEqual(cal.component(.weekday, from: next), 2)   // Monday
        XCTAssertEqual(cal.component(.day, from: next), 9)
    }

    func testCronVixieDaySemantics() throws {
        // Both dom and dow restricted: OR. The 13th of Nov 2026 is a Friday.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let base = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12, minute: 0))!
        // "0 0 13 * 1" — the 13th OR any Monday.
        let next = try XCTUnwrap(CronParser.next(after: base, expr: "0 0 13 * 1", timeZone: "UTC"))
        let day = cal.component(.day, from: next)
        // The 11th (Wed) doesn't match, the 13th does — before the next Monday (16th).
        XCTAssertEqual(day, 13)
    }

    func testCronStepsAndLists() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let base = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 0, minute: 0))!
        // "*/15 9-17 * * *" — next is 09:00 same day.
        let next = try XCTUnwrap(CronParser.next(after: base, expr: "*/15 9-17 * * *", timeZone: "UTC"))
        XCTAssertEqual(cal.dateComponents([.hour, .minute], from: next), DateComponents(hour: 9, minute: 0))
        // "5,35 12 1,15 * *" — the next 12:05/12:35 after Jan 1 00:01 is Jan 1 12:05.
        let next15 = try XCTUnwrap(CronParser.next(after: base, expr: "5,35 12 1,15 * *", timeZone: "UTC"))
        XCTAssertEqual(cal.dateComponents([.day, .hour, .minute], from: next15),
                       DateComponents(day: 1, hour: 12, minute: 5))
        // And after that one, the next is 12:35 the same day.
        let next35 = try XCTUnwrap(CronParser.next(after: next15, expr: "5,35 12 1,15 * *", timeZone: "UTC"))
        XCTAssertEqual(cal.dateComponents([.day, .hour, .minute], from: next35),
                       DateComponents(day: 1, hour: 12, minute: 35))
    }

    func testCronInvalid() {
        XCTAssertNil(CronParser.next(after: Date(), expr: "not a cron", timeZone: "UTC"))
        XCTAssertNil(CronParser.next(after: Date(), expr: "61 * * * *", timeZone: "UTC"))
        XCTAssertNil(CronParser.next(after: Date(), expr: "* * *", timeZone: "UTC"))
    }

    func testCronImpossibleDayReturnsNil() throws {
        // Feb 30 never exists: the search must end, not spin.
        let start = Date()
        let next = CronParser.next(after: start, expr: "0 0 30 2 *", timeZone: "UTC")
        XCTAssertNil(next)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    // MARK: Schedule next + labels

    func testIntervalNext() throws {
        let anchor = Date(timeIntervalSince1970: 1_000_000)
        let next = try XCTUnwrap(AutomationNext.next(.interval(seconds: 1800, anchor: anchor),
                                                     after: anchor.addingTimeInterval(3_700)))
        // 3,700s after the anchor: the next multiple of 1,800 is at 5,400s.
        XCTAssertEqual(next.timeIntervalSince(anchor), 5_400, accuracy: 1)
    }

    func testOnceNext() throws {
        let at = Date().addingTimeInterval(60)
        XCTAssertEqual(AutomationNext.next(.once(at: at), after: Date()), at)
        XCTAssertNil(AutomationNext.next(.once(at: at), after: at.addingTimeInterval(1)))
    }

    // MARK: Store + persistence

    func testStoreRecordRunAndOnceDisables() throws {
        var store = AutomationStore()
        let id = UUID().uuidString
        store.add(Automation(id: id, name: "Tick", prompt: "Do the thing",
                             schedule: .interval(seconds: 300, anchor: nil)))
        store.recordRun(id: id, status: "complete", duration: 12, sessionID: "s1", detail: nil)
        let recorded = try XCTUnwrap(store.automation(id: id))
        XCTAssertEqual(recorded.runCount, 1)
        XCTAssertEqual(recorded.lastStatus, "complete")
        XCTAssertEqual(recorded.lastDuration, 12)
        XCTAssertEqual(recorded.history.count, 1)

        // A once-schedule disables itself after its run.
        store.add(Automation(id: "one", name: "One", prompt: "p", schedule: .once(at: .now)))
        store.recordRun(id: "one", status: "complete", duration: 1, sessionID: nil, detail: nil)
        XCTAssertFalse(try XCTUnwrap(store.automation(id: "one")).enabled)
    }

    func testPersistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-automations-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("automations.json")
        var store = AutomationStore()
        store.add(Automation(name: "Sync", prompt: "Run the sync", schedule: .cron(expr: "30 8 * * 1-5", timeZone: "UTC")))
        try AutomationFile.save(store, to: url)
        let loaded = try XCTUnwrap(AutomationFile.load(from: url))
        XCTAssertEqual(loaded.automations.count, 1)
        XCTAssertEqual(loaded.automations[0].name, "Sync")
        if case .cron(let expr, let tz) = loaded.automations[0].schedule {
            XCTAssertEqual(expr, "30 8 * * 1-5")
            XCTAssertEqual(tz, "UTC")
        } else {
            XCTFail("cron schedule did not round-trip")
        }
    }

    // MARK: Scheduler

    func testSchedulerDueAndNoStampede() throws {
        let scheduler = AutomationScheduler()
        var store = AutomationStore()
        let id = UUID().uuidString
        var automation = Automation(id: id, name: "Hourly", prompt: "p", schedule: .interval(seconds: 3600, anchor: nil))
        automation.createdAt = Date().addingTimeInterval(-7_200)   // created 2h ago
        store.add(automation)
        scheduler.replaceStore(store)
        let now0 = Date()
        // Never run: its first fire is one period after it is first seen.
        XCTAssertTrue(scheduler.dueAutomations(now: now0).isEmpty, "not due the moment it is seen")
        XCTAssertTrue(scheduler.dueAutomations(now: now0.addingTimeInterval(3_600)).map(\.id).contains(id),
                      "due one period later")
        // A recorded run resets the clock: not due again for a period.
        scheduler.recordRun(id: id, status: "complete", duration: 1, sessionID: nil, detail: nil)
        XCTAssertTrue(scheduler.dueAutomations(now: now0).isEmpty, "just ran — not due")
        // (a minute of slack: recordRun's Date() lands just after now0)
        XCTAssertTrue(scheduler.dueAutomations(now: now0.addingTimeInterval(3_660)).map(\.id).contains(id),
                      "due again a period after the run")
    }

    func testSchedulerUpcomingExpands() throws {
        let scheduler = AutomationScheduler()
        var store = AutomationStore()
        let every = Automation(id: "a", name: "Every", prompt: "p", schedule: .interval(seconds: 600, anchor: nil))
        store.add(every)
        scheduler.replaceStore(store)
        let dates = scheduler.upcoming(now: Date(), horizon: 3_600)
        XCTAssertGreaterThanOrEqual(dates.count, 5)
        XCTAssertLessThanOrEqual(dates.count, 7)   // one per 10 minutes within the hour
        // Sorted.
        for (a, b) in zip(dates, dates.dropFirst()) {
            XCTAssertLessThanOrEqual(a.date, b.date)
        }
    }

    // MARK: OpenClaw compatibility

    func testOpenClawImportAndRoundTrip() throws {
        let json = """
        {"version":1,"jobs":[
          {"id":"job-1","agentId":"main","sessionKey":"agent:main:main","name":"Morning Sync",
           "enabled":true,"createdAtMs":1776279620144,
           "schedule":{"kind":"cron","expr":"30 8 * * 1-5","tz":"America/Los_Angeles"},
           "sessionTarget":"isolated","wakeMode":"now",
           "payload":{"kind":"agentTurn","message":"Run the sync","timeoutSeconds":300},
           "delivery":{"mode":"none"},"state":{}},
          {"id":"job-2","name":"Not a prompt","enabled":true,
           "schedule":{"kind":"cron","expr":"* * * * *","tz":"UTC"},
           "payload":{"kind":"systemEvent"},"state":{}},
          {"id":"job-3","name":"Every 30","enabled":true,"createdAtMs":1776279620144,
           "schedule":{"kind":"every","everyMs":1800000},
           "payload":{"kind":"agentTurn","message":"Check the queue"},"state":{}}
        ]}
        """
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-openclaw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("jobs.json")
        try json.write(to: url, atomically: true, encoding: .utf8)

        let jobs = OpenClawCompat.importJobs(from: url)
        // job-1 and job-3 import; job-2 (systemEvent) is skipped.
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(jobs[0].name, "Morning Sync")
        XCTAssertEqual(jobs[0].id, "job-1")
        if case .cron(let expr, let tz) = jobs[0].schedule {
            XCTAssertEqual(expr, "30 8 * * 1-5")
            XCTAssertEqual(tz, "America/Los_Angeles")
        } else { XCTFail("expected cron") }
        XCTAssertEqual(jobs[0].timeoutSeconds, 300)
        if case .interval(let seconds, _) = jobs[1].schedule {
            XCTAssertEqual(seconds, 1_800)
        } else { XCTFail("expected interval") }

        // And the export reads back into OpenClaw's shape.
        let exported = OpenClawCompat.exportJSON(jobs)
        let file = try JSONDecoder().decode(OpenClawJobsFile.self, from: exported)
        XCTAssertEqual(file.version, 1)
        XCTAssertEqual(file.jobs?.count, 2)
        XCTAssertEqual(file.jobs?[0].schedule?.expr, "30 8 * * 1-5")
        XCTAssertEqual(file.jobs?[1].schedule?.everyMs, 1_800_000)
    }
}
