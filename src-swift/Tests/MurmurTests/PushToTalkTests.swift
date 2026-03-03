import Foundation
import MurmurCore

@MainActor func runPushToTalkTests() {
    suite("PushToTalk") {
        let ptt = PushToTalk(config: AppConfig())
        check(ptt.status == .idle, "initial status is idle")
        check(!ptt.isSessionActive, "isSessionActive starts as false")
    }
}
