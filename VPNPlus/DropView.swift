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
import UniformTypeIdentifiers

/// A view that accepts a dropped profile. One of import's three ways in (2.1);
/// the others are File > Import Profile… and double-clicking in the Finder.
final class DropView: NSView {
    var onDrop: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func url(from sender: any NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            // A dropped file is offered as a profile when it is the type we
            // declare or a plain text file; anything else is refused rather
            // than read and rejected afterwards.
            .urlReadingContentsConformToTypes: [ProfileImporter.profileType.identifier, UTType.plainText.identifier],
        ]
        return sender.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: options)?
            .compactMap { $0 as? URL }
            .first
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        url(from: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let url = url(from: sender) else { return false }
        onDrop?(url)
        return true
    }
}
