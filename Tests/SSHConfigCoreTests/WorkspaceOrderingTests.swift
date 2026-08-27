import Testing
import Foundation
@testable import SSHConfigCore

private let a = UUID(), b = UUID(), c = UUID()

@Test func draggingDownLandsAfterTheTarget() {
    #expect(WorkspaceOrdering.reorder([a, b, c], moving: a, onto: c) == [b, c, a])
}

@Test func draggingUpLandsBeforeTheTarget() {
    #expect(WorkspaceOrdering.reorder([a, b, c], moving: c, onto: a) == [c, a, b])
}

@Test func adjacentSwap() {
    #expect(WorkspaceOrdering.reorder([a, b, c], moving: b, onto: a) == [b, a, c])
}

@Test func droppingOntoItselfChangesNothing() {
    #expect(WorkspaceOrdering.reorder([a, b, c], moving: b, onto: b) == [a, b, c])
}

@Test func unknownIdsChangeNothing() {
    let stranger = UUID()
    #expect(WorkspaceOrdering.reorder([a, b], moving: stranger, onto: a) == [a, b])
    #expect(WorkspaceOrdering.reorder([a, b], moving: a, onto: stranger) == [a, b])
}
