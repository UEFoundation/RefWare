import Foundation
import RefWareCore
import SwiftUI

/// What just happened, for windows to show: captures from the browser, and
/// requests to open a particular claim.
@MainActor
final class UIEvents: ObservableObject {
    static let shared = UIEvents()

    struct CaptureNotice: Identifiable, Equatable {
        let id = UUID()
        let idi: IDI
        let summary: String
        /// The capture created a new record (a candidate to merge into the record you were resolving).
        let isNew: Bool
        let date = Date()
    }

    @Published var capture: CaptureNotice?
    @Published var claimToShow: String?
    /// A record windows should select (e.g. the survivor after a merge).
    @Published var select: IDI?
}
