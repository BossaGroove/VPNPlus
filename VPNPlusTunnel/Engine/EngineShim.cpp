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
// The one translation unit that compiles openvpn3 (D179). Upstream has no
// library target — per-target defines such as the log macro are baked into
// whichever unit includes the core, so its own client does what we do here:
// include client/ovpncli.cpp directly and build the core as part of itself.
//
// Logging (D175): with OPENVPN_LOG left undefined, ovpncli.cpp routes every
// engine log line through a thread-local LogReceiver to
// OpenVPNClient::log(), the virtual our subclass overrides in M2. That
// override is the seam A9's "keep every status" rule hangs on; it exists
// because this file compiles the core, and it cannot be bolted on from outside.

#define OPENVPN_CORE_API_VISIBILITY_HIDDEN

#include <client/ovpncli.cpp>
#include <openvpn/crypto/data_epoch.cpp>
#include <openvpn/common/version.hpp>

#include "VPNPlusEngine.h"

extern "C" const char *vpnplus_engine_version(void)
{
    return OPENVPN_VERSION;
}

extern "C" const char *vpnplus_engine_platform(void)
{
    static const std::string value = openvpn::ClientAPI::OpenVPNClientHelper::platform();
    return value.c_str();
}
