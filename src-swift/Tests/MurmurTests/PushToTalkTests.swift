import Foundation
import MurmurCore

@MainActor func runPushToTalkTests() {
    suite("PushToTalk") {
        let ptt = PushToTalk(config: AppConfig())
        check(ptt.status == .idle, "initial status is idle")
        check(!ptt.isSessionActive, "isSessionActive starts as false")
    }

    suite("PushToTalk generation counter") {
        // Fast double-press: second handleStart() should increment generation,
        // so any pending handleStop() from generation 1 will bail before inserting.
        let ptt2 = PushToTalk(config: AppConfig())
        ptt2.handleStart()
        ptt2.handleStop()
        ptt2.handleStart()  // second session begins; generation is now 2
        // Can't easily test async insert bail-out in sync test, but verify state is clean:
        check(ptt2.isSessionActive, "second session is active after rapid double-press")
    }
}
