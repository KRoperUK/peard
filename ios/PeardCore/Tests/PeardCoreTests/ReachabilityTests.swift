import XCTest

@testable import PeardCore

/// #345: a cancelled NWPathMonitor cannot be restarted, so a stop/start cycle
/// has to build a fresh one; and registered handlers must be releasable so they
/// (and whatever they capture) do not leak.
///
/// NWPathMonitor delivers on a queue of its own and needs a real network path,
/// so these cover the parts the public contract lets us assert deterministically
/// without a network: the lifecycle does not trap, state stays readable, and the
/// handler list can be cleared and re-populated.
final class ReachabilityTests: XCTestCase {
    func testStartStopStartDoesNotTrap() {
        let reach = Reachability()
        reach.start()
        reach.stop()
        // The bug was restarting the cancelled monitor here; a fresh one is made
        // instead. Reaching this line without a trap is the assertion.
        reach.start()
        reach.stop()
    }

    func testOptimisticBeforeFirstUpdate() {
        let reach = Reachability()
        // Before any path update, online/unconstrained is the safe default so a
        // launch does not start out withholding sends or in low-data behaviour.
        XCTAssertTrue(reach.isOnline)
        XCTAssertFalse(reach.isConstrained)
    }

    func testRemoveHandlersIsCallableAndReRegisterWorks() {
        let reach = Reachability()
        reach.onChange { _ in }
        reach.onConstrainedChange { _ in }
        // Releasing handlers must not trap, and a later registration starts a
        // fresh list rather than appending to a released one.
        reach.removeHandlers()
        reach.onChange { _ in }
        reach.removeHandlers()
    }

    func testStartIsIdempotent() {
        let reach = Reachability()
        reach.start()
        reach.start() // second start is a no-op, not a second monitor
        reach.stop()
    }
}
