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

// -- Importing a profile ----------------------------------------------------

/// What merging a profile from disk produced.
typedef struct {
    bool ok;
    char status[64];             ///< the engine's own status code, for the log
    char message[512];           ///< the engine's own error text, for the log
    char basename[256];          ///< the file's name, a sensible default title
    char missing_reference[512]; ///< the referenced file it could not read, when that is why it failed
    size_t reference_count;      ///< referenced files successfully inlined
} vpnplus_merge_info;

/// Reads a profile from disk and inlines the files it references, so the stored
/// text is self-contained. Returns the byte length the merged text needs; when
/// that exceeds profile_size nothing is written and the call should be repeated
/// with a larger buffer. out is filled in either way, and the length is 0 on
/// failure.
size_t vpnplus_engine_merge(const char *path, char *profile, size_t profile_size, vpnplus_merge_info *out);

/// One server a profile offers. label is the issuer's own name for it, empty
/// when it supplied none.
typedef void (*vpnplus_server_callback)(void *context, const char *host, const char *label);

/// What a profile says about itself, without connecting.
typedef struct {
    bool ok;
    char message[512];
    char profile_name[256];
    char friendly_name[256];
    /// The username the profile fixes, empty when the user may choose. A fixed
    /// username is shown read-only rather than as an empty field.
    char fixed_username[256];
    bool autologin;           ///< needs no username or password
    bool external_pki;        ///< its client identity lives outside the file
    bool allow_password_save; ///< false means the save option is not offered at all
    bool private_key_password_required;
    char static_challenge[512]; ///< an extra prompt the server asks for, empty when none
    bool static_challenge_echo; ///< whether that answer may be shown as it is typed
    char remote_host[256];
    char remote_port[16];
    char remote_proto[16];
    size_t server_count;
} vpnplus_profile_info;

/// Fills out from the profile text, and calls servers once per alternate
/// server. Returns out->ok.
bool vpnplus_engine_describe(const char *profile, vpnplus_profile_info *out,
                             vpnplus_server_callback servers, void *context);

// -- Validating a profile ---------------------------------------------------

typedef enum {
    VPNPLUS_VERDICT_ACCEPTED = 0,
    /// Usable, but the engine ignores directives the profile carries. Disclosed
    /// as a count with the list behind it, never buried.
    VPNPLUS_VERDICT_ACCEPTED_WITH_WAIVERS = 1,
    VPNPLUS_VERDICT_REFUSED = 2,
} vpnplus_verdict;

typedef enum {
    VPNPLUS_REFUSAL_NONE = 0,
    /// Not a profile we can read at all.
    VPNPLUS_REFUSAL_MALFORMED = 1,
    /// Locked to a server that hands out its own configuration: the wrong file.
    VPNPLUS_REFUSAL_SERVER_LOCKED = 2,
    /// Its client identity is in a key store we cannot read (pkcs12).
    VPNPLUS_REFUSAL_EXTERNAL_KEY_STORE = 3,
    /// It needs something the engine does not implement, and would not work.
    VPNPLUS_REFUSAL_UNSUPPORTED_FEATURE = 4,
    /// It carries directives the engine does not recognise. These may be set
    /// aside by the user and the profile imported anyway.
    VPNPLUS_REFUSAL_UNKNOWN_DIRECTIVES = 5,
} vpnplus_refusal;

typedef enum {
    /// The engine ignores it and connects anyway. Already waived; disclose it.
    VPNPLUS_DIRECTIVE_IGNORED = 0,
    /// Unrecognised. The user may set it aside; pass it back in waive.
    VPNPLUS_DIRECTIVE_WAIVABLE = 1,
    /// A refusal with a real reason. Never waivable: without it the tunnel
    /// would not do what the profile says.
    VPNPLUS_DIRECTIVE_BLOCKING = 2,
} vpnplus_directive_kind;

/// One directive the engine set aside or refused. reason is the engine's own
/// wording for its category.
typedef void (*vpnplus_directive_callback)(void *context, const char *directive,
                                           const char *reason, vpnplus_directive_kind kind);

typedef struct {
    vpnplus_verdict verdict;
    vpnplus_refusal refusal;
    char message[1024];
} vpnplus_validation;

/// Parses a profile exactly the way connecting would, with no network, and
/// reports what would happen. waive names directives the user has agreed to set
/// aside (only ones reported as WAIVABLE); pass NULL and 0 for none.
/// directives is called once per directive set aside or refused.
void vpnplus_engine_validate(const char *profile,
                             const char *const *waive, size_t waive_count,
                             vpnplus_validation *out,
                             vpnplus_directive_callback directives, void *context);

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

/// A user's choice that changes where or how this connection is made. Any
/// field may be NULL or empty, meaning "use what the profile says".
typedef struct {
    const char *server;   ///< host to connect to instead of the profile's
    const char *port;
    const char *transport;
} vpnplus_overrides;

/// Evaluates the profile and stores the credentials. Must succeed before run().
/// Either credential may be NULL or empty, and `overrides` may be NULL. On
/// false, `message` explains.
bool vpnplus_engine_prepare(vpnplus_engine *engine, const char *profile,
                            const char *username, const char *password,
                            const vpnplus_overrides *overrides,
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
