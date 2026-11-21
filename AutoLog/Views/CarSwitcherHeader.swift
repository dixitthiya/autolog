import SwiftUI

/// The one set of numbers behind the car switcher row on every tab.
enum CarSwitcherLayout {
    /// Leading margin of the large navigation title on iPhone (portrait).
    /// Derived from the iOS default, not measured on a device: if the pill ever
    /// looks off from the title, this is the only number to change.
    static let titleLeading: CGFloat = 20
    /// Gap between the large title and the pill row.
    static let top: CGFloat = 8
    /// Gap between the pill row and the first content.
    static let bottom: CGFloat = 16
}

/// The switcher pill (and the Retired pill) with the shared spacing. Used as
/// the first item on every tab, so all five look the same.
/// - `leadingInset`: `titleLeading` in a plain scroll view or stack; 0 inside a
///   `List`, where the list's own side inset already lines up with the title.
/// - `bottom`: 16 normally; Maintenance passes 8 because its filter bar adds 8.
struct CarSwitcherHeader: View {
    var leadingInset: CGFloat = CarSwitcherLayout.titleLeading
    var bottom: CGFloat = CarSwitcherLayout.bottom

    var body: some View {
        CarSwitcherRow()
            .padding(.leading, leadingInset)
            .padding(.trailing, leadingInset)
            .padding(.top, CarSwitcherLayout.top)
            .padding(.bottom, bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// For the `Section` holding a `CarSwitcherHeader(leadingInset: 0)` at the top
    /// of a `List`: no background or separator, no extra insets (the header
    /// brings its own spacing), no gap before the next section.
    func carSwitcherListHeader() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .listSectionSpacing(.custom(0))
    }

    /// For the `List` itself: start the first section right under the title,
    /// as a scroll view does.
    func carSwitcherListContainer() -> some View {
        self.contentMargins(.top, 0, for: .scrollContent)
    }

    /// The page background every tab shares (what the List tabs already use).
    func carSwitcherPageBackground() -> some View {
        self.background(Color(.systemGroupedBackground))
    }
}
