import Foundation

/// Pure ordering rules behind sidebar workspace drag-and-drop.
public enum WorkspaceOrdering {
    /// Moves `moved` into `target`'s slot, shifting everything else along —
    /// the usual "drop a row onto another row" behavior. Dragging downward
    /// therefore lands *after* the target (removal shifts it up first),
    /// dragging upward lands *before* it.
    ///
    /// Returns `ids` untouched when the drag is a no-op or either id is
    /// unknown, so a stray drop can never scramble the order.
    public static func reorder(_ ids: [UUID], moving moved: UUID, onto target: UUID) -> [UUID] {
        guard moved != target,
              let from = ids.firstIndex(of: moved),
              let to = ids.firstIndex(of: target) else { return ids }
        var result = ids
        result.remove(at: from)
        result.insert(moved, at: to)
        return result
    }
}
