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
// The C surface of the engine shim. Swift sees this header and nothing else
// of openvpn3 (D179): no openvpn3 type appears in a Swift signature. What is
// here is what M1 needs to prove the engine is linked; M2 grows it into the
// TunnelAdapter contract.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/// The engine's version string, for example "3.11.7". Static storage; never free it.
const char *vpnplus_engine_version(void);

/// The engine's own description of the platform it was built for. Static storage.
const char *vpnplus_engine_platform(void);

#ifdef __cplusplus
}
#endif
