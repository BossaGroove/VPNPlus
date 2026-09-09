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

import Foundation
import Testing
import VPNPlusCore

/// The setup narration, checked for what it must say and what it must never
/// contain (A5, A17; feature-spec 4.1).
struct SetupCopyTests {
    @Test func theExplanationNamesAllThreePrompts() {
        let first = SetupCopy.explanation(again: false)
        #expect(first.title == "One-time setup")
        #expect(first.body.contains("System Settings"))
        #expect(first.body.contains("password"))
        #expect(first.body.contains("VPN configuration"))
        #expect(first.action == "Continue" && first.secondary == "Not now")
    }

    /// D66: no welcome for someone the app has known for a year.
    @Test func reApprovalIsNotAFirstRun() {
        let again = SetupCopy.explanation(again: true)
        #expect(again.title == "VPN Plus needs permission again")
        #expect(!again.body.lowercased().contains("welcome"))
        #expect(again.body.contains("new Mac"))
    }

    @Test func waitingPromisesTheWindowWillNotice() {
        #expect(SetupCopy.waiting.body.contains("this window will notice"))
        #expect(SetupCopy.waiting.action == "Open System Settings again")
    }

    /// D154: a blocked state says what still works, whatever the reason.
    @Test func everyBlockedReasonSaysWhatStillWorks() throws {
        let identifier = try Regex(#"\b[A-Z][A-Z0-9]*_[A-Z0-9_]+\b"#)
        let reasons: [SetupFailure?] = [
            nil, .declined, .unknown, .forbiddenByPolicy, .damaged, .needsRestart,
            .wrongLocation(path: "/Users/someone/Downloads/VPN Plus.app"),
        ]
        for reason in reasons {
            let message = SetupCopy.blocked(reason)
            #expect(message.body.contains("Everything else still works"), "\(String(describing: reason))")
            #expect(!message.title.isEmpty)
            #expect(!message.body.contains(identifier) && !message.body.contains("Error"), "\(String(describing: reason))")
        }
        // Only a stall the user can end offers to continue.
        #expect(SetupCopy.blocked(.declined).action == "Continue setup")
        #expect(SetupCopy.blocked(.forbiddenByPolicy).action == nil)
    }

    /// D62's degrade: without the button, the instruction; with it, no
    /// instruction to compete with the button.
    @Test func theWrongLocationOffersTheMoveOrSaysHow() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let movable = SetupCopy.wrongLocation(path: home + "/Downloads/VPN Plus.app", canMove: true)
        #expect(movable.action == "Move to Applications")
        #expect(movable.body.contains("your Downloads folder"))
        #expect(!movable.body.contains("Drag"))
        let stuck = SetupCopy.wrongLocation(path: "/Volumes/VPN Plus/VPN Plus.app", canMove: false)
        #expect(stuck.action == nil)
        #expect(stuck.body.contains("the disk image") && stuck.body.contains("Drag VPN Plus"))
    }

    /// D156: where it actually is.
    @Test func theWrongLocationIsNamedWhereItIs() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(SetupCopy.folderName(home + "/Downloads/VPN Plus.app") == "your Downloads folder")
        #expect(SetupCopy.folderName("/Volumes/VPN Plus/VPN Plus.app") == "the disk image")
        #expect(SetupCopy.folderName(home + "/Work/VPN Plus.app") == "the “Work” folder")
    }
}
