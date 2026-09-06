// VPN Plus — a native macOS VPN client.
// Copyright (C) 2026 VPN Plus contributors
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

import Foundation
import NetworkExtension

// A system extension is a real executable and supplies its own entry point.
// An app extension does not — the host provides one and reads
// NSExtensionPrincipalClass from Info.plist. This file is one of the concrete
// differences between the two packagings, and the reason B14's evidence
// (gathered against an app extension) has to be repeated at C4.
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}

dispatchMain()
