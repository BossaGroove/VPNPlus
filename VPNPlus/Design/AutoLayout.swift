// VPN Plus — a native macOS VPN client.
// Copyright (C) 2026 BossaGroove
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details.
//
// You should have received a copy of the GNU General Public License along
// with this program. If not, see <https://www.gnu.org/licenses/>.

import AppKit

extension NSView {
    /// Take the row's spare width rather than hugging your own content.
    ///
    /// The same helper as the sibling app's, deliberately: both use the
    /// `NSGridView` two-column form, and a field that hugs its text leaves the
    /// column ragged. Lowering compression resistance as well is what lets a
    /// long value shrink instead of forcing the sheet wider.
    func fillsRowWidth(minimumWidth: CGFloat = 120) {
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
        widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth).isActive = true
    }
}
