import AppKit
import Carbon
@testable import DockDoor
import Foundation
import Testing

struct CmdTabSelectionTrackerTests {
    @Test func echoOfOurOwnWriteIsIgnored() {
        var tracker = CmdTabSelectionTracker()
        tracker.didWrite(10)

        let reported = tracker.nativeSelectionChanged(to: 10)

        #expect(reported == false)
        #expect(tracker.userMoveGeneration == 0)
    }

    @Test func genuineMoveIsReportedAndInvalidatesPendingWrites() {
        var tracker = CmdTabSelectionTracker()
        tracker.didWrite(10)
        let pendingGeneration = tracker.userMoveGeneration

        let reported = tracker.nativeSelectionChanged(to: 20)

        #expect(reported)
        #expect(tracker.lastSyncedPID == 20)
        #expect(tracker.isCurrent(generation: pendingGeneration) == false)
    }

    @Test func movingBackToAnEarlierAppIsStillAGenuineMove() {
        var tracker = CmdTabSelectionTracker()
        let moves = [10, 20, 10].map { tracker.nativeSelectionChanged(to: $0) }

        #expect(moves == [true, true, true])
        #expect(tracker.userMoveGeneration == 3)
    }

    @Test func writesAreSkippedOnlyForTheAppAlreadyHighlighted() {
        var tracker = CmdTabSelectionTracker()
        tracker.seed(10)

        #expect(tracker.needsWrite(for: 10) == false)
        #expect(tracker.isInSync(with: 10))
        #expect(tracker.needsWrite(for: 20))
        #expect(tracker.needsWrite(for: nil))
    }

    @Test func resetNeverReusesAnEarlierGeneration() {
        var tracker = CmdTabSelectionTracker()
        _ = tracker.nativeSelectionChanged(to: 10)
        let scheduledBeforeReset = tracker.userMoveGeneration

        tracker.reset()

        #expect(tracker.isCurrent(generation: scheduledBeforeReset) == false)
        #expect(tracker.lastSyncedPID == nil)
    }

    @Test func aFailedWriteDisablesFurtherWritesUntilReset() {
        var tracker = CmdTabSelectionTracker()
        tracker.writeFailed()

        #expect(tracker.needsWrite(for: 20) == false)
        #expect(tracker.isInSync(with: 20) == false)

        tracker.reset()
        #expect(tracker.needsWrite(for: 20))
        #expect(tracker.writesDisabled == false)
    }

    @Test func aPanelWriteMakesTheNextNativeNotificationAnEcho() {
        var tracker = CmdTabSelectionTracker()
        tracker.didWrite(30)

        let reported = tracker.nativeSelectionChanged(to: 30)

        #expect(tracker.needsWrite(for: 30) == false)
        #expect(reported == false)
    }
}

struct CmdTabStripGeometryTests {
    @Test func flipsAgainstThePrimaryDisplayHeightIncludingTheRectHeight() {
        // 1117pt-tall primary display, strip 88pt tall whose top edge is 514pt from the top.
        let rect = CmdTabStripGeometry.appKitRect(
            axPosition: CGPoint(x: 38, y: 514),
            size: CGSize(width: 1652, height: 88),
            primaryScreenHeight: 1117
        )

        #expect(rect.origin.x == 38)
        #expect(rect.origin.y == 515)
        #expect(rect.maxY == 603)
    }

    @Test func handlesADisplayArrangedAboveThePrimary() {
        // AX y is negative for displays above the primary; the AppKit rect ends up above its top.
        let rect = CmdTabStripGeometry.appKitRect(
            axPosition: CGPoint(x: 0, y: -400),
            size: CGSize(width: 800, height: 100),
            primaryScreenHeight: 1117
        )

        #expect(rect.origin.y == 1417)
        #expect(rect.maxY > 1117)
    }

    @Test func budgetIsTheSpaceBetweenTheBarAndTheStripMinusTheGap() {
        let budget = CmdTabStripGeometry.heightBudget(panelTop: 1035, stripTop: 602, gap: 12, floor: 120)
        #expect(budget == 421)
    }

    @Test func budgetNeverDropsBelowTheFloor() {
        let budget = CmdTabStripGeometry.heightBudget(panelTop: 700, stripTop: 690, gap: 12, floor: 120)
        #expect(budget == 120)
    }
}

struct CmdTabSessionKeyTests {
    @Test func tabAndTheBackwardKeyStayWithTheNativeStrip() {
        #expect(CmdTabSessionKey.disposition(forKeyCode: Int64(kVK_Tab)) == .passToSystem)
        #expect(CmdTabSessionKey.disposition(forKeyCode: Int64(kVK_ANSI_Grave)) == .passToSystem)
    }

    @Test func escapeUsesTheExistingDismissBranch() {
        #expect(CmdTabSessionKey.disposition(forKeyCode: Int64(kVK_Escape)) == .escape)
    }

    @Test func keysThatTheNativeSwitcherTreatsAsActionsAreAlwaysConsumed() {
        // Command+Q quits and Command+H hides the highlighted app in the native switcher.
        for key in [kVK_ANSI_Q, kVK_ANSI_H, kVK_ANSI_W, kVK_ANSI_M, kVK_ANSI_A, kVK_Return, kVK_Space, kVK_LeftArrow, kVK_DownArrow, kVK_Delete] {
            #expect(CmdTabSessionKey.disposition(forKeyCode: Int64(key)) == .consume)
        }
    }
}

@MainActor
struct SwitcherHeightBudgetTests {
    @Test func limitIsTheVisibleHeightWithoutABudget() throws {
        let screen = try #require(NSScreen.main)
        SwitcherHeightBudget.current = nil

        #expect(SwitcherHeightBudget.limit(for: screen) == screen.visibleFrame.height)
    }

    @Test func aBudgetOnlyEverLowersTheLimit() throws {
        let screen = try #require(NSScreen.main)
        defer { SwitcherHeightBudget.current = nil }

        SwitcherHeightBudget.current = 300
        #expect(SwitcherHeightBudget.limit(for: screen) == min(300, screen.visibleFrame.height))

        SwitcherHeightBudget.current = screen.visibleFrame.height + 500
        #expect(SwitcherHeightBudget.limit(for: screen) == screen.visibleFrame.height)
    }
}
