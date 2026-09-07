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
// openvpn3's external-PKI glue for OpenSSL 3 is two C files that upstream
// builds into its client. Each gets its own translation unit here, so their
// file-static symbols cannot collide. Needed for ENABLE_EXTERNAL_PKI, which
// M3 uses for pkcs12 profiles (D192).
#include <openvpn/openssl/xkey/xkey_helper.c>
