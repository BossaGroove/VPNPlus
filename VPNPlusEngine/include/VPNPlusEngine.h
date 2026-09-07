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

// The C surface of the engine (D179). Swift sees this header and nothing else
// of openvpn3: no openvpn3 type appears here, and none crosses into Swift.
//
// Threading: vpnplus_engine_run() blocks on the caller's thread for the life
// of the connection and invokes every callback on that same thread. stop(),
// pause(), resume() and reconnect() may be called from any other thread while
// run() is blocked. Strings passed to callbacks are valid only for the
// duration of the callback; copy them.

#pragma once

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The engine's version string, for example "3.11.7". Static storage; never free it.
const char *vpnplus_engine_version(void);

/// The engine's own description of the platform it was built for. Static storage.
const char *vpnplus_engine_platform(void);

/// Parses a profile the way connect() would, with no network, and reports the
/// first defect. Returns true when the profile would be accepted. On false,
/// `message` receives a NUL-terminated explanation (truncated to fit).
bool vpnplus_engine_validate(const char *profile, char *message, size_t message_size);

/// One local tunnel address, as the server pushed it.
typedef struct {
    const char *address;
    int prefix_length;
    const char *gateway;   ///< may be empty
    bool ipv6;
} vpnplus_address;

/// One route the tunnel should carry (or exclude).
typedef struct {
    const char *address;
    int prefix_length;
    bool ipv6;
} vpnplus_route;

/// Everything the engine asked the tunnel builder for, delivered once, right
/// before it needs a descriptor. Maps onto NEPacketTunnelNetworkSettings.
typedef struct {
    const char *remote_address;        ///< the server's real address; excluded from the tunnel by the OS
    bool remote_ipv6;
    const char *session_name;
    int mtu;                           ///< 0 when the server did not say
    const vpnplus_address *addresses;
    size_t address_count;
    const vpnplus_route *included_routes;
    size_t included_route_count;
    const vpnplus_route *excluded_routes;
    size_t excluded_route_count;
    bool reroute_ipv4;                 ///< redirect-gateway: carry all IPv4
    bool reroute_ipv6;
    bool block_ipv6;
    const char *const *dns_servers;
    size_t dns_server_count;
    const char *const *search_domains;
    size_t search_domain_count;
} vpnplus_tun_settings;

typedef struct {
    void *context;
    /// One engine log line, without its trailing newline.
    void (*log)(void *context, const char *text);
    /// One engine event. `info` may be empty. `fatal` means the engine will disconnect.
    void (*event)(void *context, const char *name, const char *info, bool error, bool fatal);
    /// Apply the settings and return a tunnel descriptor the engine will own
    /// from now on, or -1 to fail the connection. May block.
    int (*establish)(void *context, const vpnplus_tun_settings *settings);
    /// The engine is done with the tunnel. `disconnect` is false on a reconnect.
    void (*teardown)(void *context, bool disconnect);
} vpnplus_engine_callbacks;

typedef struct vpnplus_engine vpnplus_engine;

/// `client_version` is reported to the server as the GUI version (IV_GUI_VER).
vpnplus_engine *vpnplus_engine_create(const vpnplus_engine_callbacks *callbacks, const char *client_version);
void vpnplus_engine_destroy(vpnplus_engine *engine);

/// Evaluates the profile and stores the credentials. Must succeed before run().
/// Either credential may be NULL or empty. On false, `message` explains.
bool vpnplus_engine_prepare(vpnplus_engine *engine, const char *profile,
                            const char *username, const char *password,
                            char *message, size_t message_size);

/// Connects, and returns only when the connection has ended. Returns false
/// when it ended with an error, with `message` set.
bool vpnplus_engine_run(vpnplus_engine *engine, char *message, size_t message_size);

void vpnplus_engine_stop(vpnplus_engine *engine);
void vpnplus_engine_pause(vpnplus_engine *engine, const char *reason);
void vpnplus_engine_resume(vpnplus_engine *engine);
void vpnplus_engine_reconnect(vpnplus_engine *engine, int seconds);

typedef struct {
    char user[128];
    char server_host[256];
    char server_port[16];
    char server_proto[16];
    char server_ip[64];
    char vpn_ip4[64];
    char vpn_ip6[64];
    char gateway4[64];
    char gateway6[64];
    char client_ip[64];
    char tun_name[32];
} vpnplus_connection_info;

/// Valid once the CONNECTED event has been delivered. Returns false before that.
bool vpnplus_engine_connection_info(vpnplus_engine *engine, vpnplus_connection_info *out);

typedef struct {
    long long bytes_in;
    long long bytes_out;
    long long packets_in;
    long long packets_out;
    /// Milliseconds since the last packet arrived, in the engine's binary
    /// milliseconds (1/1024 s); -1 when no packet has arrived yet.
    int last_packet_received;
} vpnplus_transport_stats;

void vpnplus_engine_transport_stats(vpnplus_engine *engine, vpnplus_transport_stats *out);

#ifdef __cplusplus
}
#endif
