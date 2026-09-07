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
// OpenVPNClient::log(), overridden below. That override is the seam A9's
// "keep every status" rule hangs on; it exists because this file compiles the
// core, and it cannot be bolted on from outside.

#define OPENVPN_CORE_API_VISIBILITY_HIDDEN

#include <client/ovpncli.cpp>
#include <openvpn/crypto/data_epoch.cpp>
#include <openvpn/common/version.hpp>
#include <openvpn/tun/builder/capture.hpp>
#include <openvpn/client/cliopt.hpp>

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "VPNPlusEngine.h"

namespace {

using namespace openvpn;

void copy_message(char *out, size_t size, const std::string &text)
{
    if (out == nullptr || size == 0)
        return;
    const size_t n = std::min(text.size(), size - 1);
    std::memcpy(out, text.data(), n);
    out[n] = '\0';
}

void copy_field(char *out, size_t size, const std::string &text)
{
    copy_message(out, size, text);
}

/// The engine, behind the boundary. Every openvpn3 callback lands here and
/// leaves as plain C.
class Client final : public ClientAPI::OpenVPNClient
{
  public:
    Client(const vpnplus_engine_callbacks &callbacks, std::string client_version)
        : callbacks_(callbacks), client_version_(std::move(client_version))
    {
    }

    bool prepare(const char *profile, const char *username, const char *password, std::string &message)
    {
        ClientAPI::Config config;
        config.content = profile ? profile : "";
        config.guiVersion = client_version_;
        config.info = true;   // INFO events carry server messages the user should see
        config.dco = false;   // no data-channel offload on macOS
        // Not persisted: every reconnect is a fresh engine that establishes
        // its own tunnel, and a stale tunnel left holding the default route is
        // exactly what broke reconnects (M2.5).
        config.tunPersist = false;
        config.googleDnsFallback = false;
        config.allowLocalLanAccess = false;

        const ClientAPI::EvalConfig eval = eval_config(config);
        if (eval.error)
        {
            message = eval.message;
            return false;
        }
        if (eval.externalPki)
        {
            message = "This profile keeps its client certificate outside the file, which is not supported yet.";
            return false;
        }
        const std::string user = username ? username : "";
        const std::string pass = password ? password : "";
        if (!user.empty() || !pass.empty())
        {
            ClientAPI::ProvideCreds creds;
            creds.username = user;
            creds.password = pass;
            const ClientAPI::Status status = provide_creds(creds);
            if (status.error)
            {
                message = status.message;
                return false;
            }
        }
        return true;
    }

    bool run(std::string &message)
    {
        const ClientAPI::Status status = connect();
        if (status.error)
        {
            message = status.status.empty() ? status.message : status.status + ": " + status.message;
            return false;
        }
        return true;
    }

    bool connection_info_into(vpnplus_connection_info &out)
    {
        const ClientAPI::ConnectionInfo info = connection_info();
        if (!info.defined)
            return false;
        copy_field(out.user, sizeof out.user, info.user);
        copy_field(out.server_host, sizeof out.server_host, info.serverHost);
        copy_field(out.server_port, sizeof out.server_port, info.serverPort);
        copy_field(out.server_proto, sizeof out.server_proto, info.serverProto);
        copy_field(out.server_ip, sizeof out.server_ip, info.serverIp);
        copy_field(out.vpn_ip4, sizeof out.vpn_ip4, info.vpnIp4);
        copy_field(out.vpn_ip6, sizeof out.vpn_ip6, info.vpnIp6);
        copy_field(out.gateway4, sizeof out.gateway4, info.gw4);
        copy_field(out.gateway6, sizeof out.gateway6, info.gw6);
        copy_field(out.client_ip, sizeof out.client_ip, info.clientIp);
        copy_field(out.tun_name, sizeof out.tun_name, info.tunName);
        return true;
    }

    // ── OpenVPNClient's pure virtuals ────────────────────────────────────

    void event(const ClientAPI::Event &ev) override
    {
        if (callbacks_.event)
            callbacks_.event(callbacks_.context, ev.name.c_str(), ev.info.c_str(), ev.error, ev.fatal);
    }

    void acc_event(const ClientAPI::AppCustomControlMessageEvent &ev) override
    {
        if (callbacks_.event)
        {
            const std::string info = ev.protocol + ": " + ev.payload;
            callbacks_.event(callbacks_.context, "APP_CUSTOM_CONTROL", info.c_str(), false, false);
        }
    }

    void log(const ClientAPI::LogInfo &li) override
    {
        if (!callbacks_.log)
            return;
        std::string text = li.text;
        while (!text.empty() && (text.back() == '\n' || text.back() == '\r'))
            text.pop_back();
        callbacks_.log(callbacks_.context, text.c_str());
    }

    void external_pki_cert_request(ClientAPI::ExternalPKICertRequest &req) override
    {
        req.error = true;
        req.errorText = "external PKI is not supported yet";
    }

    void external_pki_sign_request(ClientAPI::ExternalPKISignRequest &req) override
    {
        req.error = true;
        req.errorText = "external PKI is not supported yet";
    }

    bool pause_on_connection_timeout() override
    {
        // D177: the engine's own timeouts are never the user-facing deadline;
        // the provider ends a stalled attempt, so the engine keeps trying.
        return false;
    }

    // D208: under NetworkExtension the OS already routes this process's
    // sockets around its own tunnel. Nothing to do except record the local
    // address, so a regression would show in the diagnostics.
    bool socket_protect(openvpn_io::detail::socket_type socket, std::string remote, bool ipv6) override
    {
        sockaddr_storage local{};
        socklen_t len = sizeof local;
        std::string where = "unknown";
        if (getsockname(socket, reinterpret_cast<sockaddr *>(&local), &len) == 0)
        {
            char buf[INET6_ADDRSTRLEN] = {};
            if (local.ss_family == AF_INET)
                inet_ntop(AF_INET, &reinterpret_cast<sockaddr_in *>(&local)->sin_addr, buf, sizeof buf);
            else if (local.ss_family == AF_INET6)
                inet_ntop(AF_INET6, &reinterpret_cast<sockaddr_in6 *>(&local)->sin6_addr, buf, sizeof buf);
            const unsigned port = local.ss_family == AF_INET
                                      ? ntohs(reinterpret_cast<sockaddr_in *>(&local)->sin_port)
                                      : ntohs(reinterpret_cast<sockaddr_in6 *>(&local)->sin6_port);
            where = std::string(buf) + ":" + std::to_string(port);
        }
        if (callbacks_.log)
        {
            const std::string text = "transport socket to " + remote + (ipv6 ? " (IPv6)" : "") + " bound locally to " + where;
            callbacks_.log(callbacks_.context, text.c_str());
        }
        return true;
    }

    // ── TunBuilderBase: record everything, deliver it once at establish ──

    // TunBuilderCapture implements every setter but not this one, and the
    // base returns false — which failed the first real connection at
    // TUN_SETUP after the server had already pushed its config. A new tunnel
    // starts from an empty capture.
    bool tun_builder_new() override
    {
        capture_.reset(new TunBuilderCapture());
        return true;
    }
    bool tun_builder_set_layer(int layer) override { return capture_->tun_builder_set_layer(layer); }
    bool tun_builder_set_remote_address(const std::string &address, bool ipv6) override
    {
        return capture_->tun_builder_set_remote_address(address, ipv6);
    }
    bool tun_builder_add_address(const std::string &address, int prefix_length, const std::string &gateway, bool ipv6, bool net30) override
    {
        return capture_->tun_builder_add_address(address, prefix_length, gateway, ipv6, net30);
    }
    bool tun_builder_set_route_metric_default(int metric) override
    {
        return capture_->tun_builder_set_route_metric_default(metric);
    }
    bool tun_builder_reroute_gw(bool ipv4, bool ipv6, unsigned int flags) override
    {
        return capture_->tun_builder_reroute_gw(ipv4, ipv6, flags);
    }
    bool tun_builder_add_route(const std::string &address, int prefix_length, int metric, bool ipv6) override
    {
        return capture_->tun_builder_add_route(address, prefix_length, metric, ipv6);
    }
    bool tun_builder_exclude_route(const std::string &address, int prefix_length, int metric, bool ipv6) override
    {
        return capture_->tun_builder_exclude_route(address, prefix_length, metric, ipv6);
    }
    bool tun_builder_set_dns_options(const DnsOptions &dns) override
    {
        return capture_->tun_builder_set_dns_options(dns);
    }
    bool tun_builder_set_mtu(int mtu) override { return capture_->tun_builder_set_mtu(mtu); }
    bool tun_builder_set_session_name(const std::string &name) override
    {
        return capture_->tun_builder_set_session_name(name);
    }
    bool tun_builder_add_proxy_bypass(const std::string &host) override
    {
        return capture_->tun_builder_add_proxy_bypass(host);
    }
    bool tun_builder_set_proxy_auto_config_url(const std::string &url) override
    {
        return capture_->tun_builder_set_proxy_auto_config_url(url);
    }
    bool tun_builder_set_proxy_http(const std::string &host, int port) override
    {
        return capture_->tun_builder_set_proxy_http(host, port);
    }
    bool tun_builder_set_proxy_https(const std::string &host, int port) override
    {
        return capture_->tun_builder_set_proxy_https(host, port);
    }
    bool tun_builder_add_wins_server(const std::string &address) override
    {
        return capture_->tun_builder_add_wins_server(address);
    }
    bool tun_builder_set_allow_family(int af, bool allow) override
    {
        return capture_->tun_builder_set_allow_family(af, allow);
    }
    bool tun_builder_set_allow_local_dns(bool allow) override
    {
        return capture_->tun_builder_set_allow_local_dns(allow);
    }

    int tun_builder_establish() override
    {
        if (!callbacks_.establish)
            return -1;

        // Flatten the capture into C. The vectors below own the storage the
        // pointers refer to for the duration of the callback.
        std::vector<vpnplus_address> addresses;
        for (const auto &a : capture_->tunnel_addresses)
            addresses.push_back({a.address.c_str(), a.prefix_length, a.gateway.c_str(), a.ipv6});

        std::vector<vpnplus_route> included, excluded;
        for (const auto &r : capture_->add_routes)
            included.push_back({r.address.c_str(), r.prefix_length, r.ipv6});
        for (const auto &r : capture_->exclude_routes)
            excluded.push_back({r.address.c_str(), r.prefix_length, r.ipv6});

        std::vector<std::string> dns_storage, domain_storage;
        for (const auto &[priority, server] : capture_->dns_options.servers)
        {
            (void)priority;
            for (const auto &addr : server.addresses)
                dns_storage.push_back(addr.address);
            for (const auto &d : server.domains)
                domain_storage.push_back(d.domain);
        }
        for (const auto &d : capture_->dns_options.search_domains)
            domain_storage.push_back(d.domain);
        std::vector<const char *> dns, domains;
        for (const auto &s : dns_storage)
            dns.push_back(s.c_str());
        for (const auto &s : domain_storage)
            domains.push_back(s.c_str());

        vpnplus_tun_settings settings{};
        settings.remote_address = capture_->remote_address.address.c_str();
        settings.remote_ipv6 = capture_->remote_address.ipv6;
        settings.session_name = capture_->session_name.c_str();
        settings.mtu = capture_->mtu;
        settings.addresses = addresses.data();
        settings.address_count = addresses.size();
        settings.included_routes = included.data();
        settings.included_route_count = included.size();
        settings.excluded_routes = excluded.data();
        settings.excluded_route_count = excluded.size();
        settings.reroute_ipv4 = capture_->reroute_gw.ipv4;
        settings.reroute_ipv6 = capture_->reroute_gw.ipv6;
        settings.block_ipv6 = capture_->block_ipv6;
        settings.dns_servers = dns.data();
        settings.dns_server_count = dns.size();
        settings.search_domains = domains.data();
        settings.search_domain_count = domains.size();

        return callbacks_.establish(callbacks_.context, &settings);
    }

    bool tun_builder_persist() override { return false; }

    void tun_builder_teardown(bool disconnect) override
    {
        if (callbacks_.teardown)
            callbacks_.teardown(callbacks_.context, disconnect);
    }

  private:
    vpnplus_engine_callbacks callbacks_;
    std::string client_version_;
    // Reference-counted and non-copyable, hence the pointer.
    TunBuilderCapture::Ptr capture_{new TunBuilderCapture()};
};

} // namespace

struct vpnplus_engine
{
    std::unique_ptr<Client> client;
};

extern "C" const char *vpnplus_engine_version(void)
{
    return OPENVPN_VERSION;
}

extern "C" const char *vpnplus_engine_platform(void)
{
    static const std::string value = openvpn::ClientAPI::OpenVPNClientHelper::platform();
    return value.c_str();
}

// D189: eval_config accepts almost anything; the defects that matter are thrown
// when ClientOptions is constructed inside connect(). This runs that
// construction with no network, the way upstream's own unit tests do.
extern "C" bool vpnplus_engine_validate(const char *profile, char *message, size_t message_size)
{
    try
    {
        openvpn::InitProcess::Init init;
        openvpn::OptionList options;
        openvpn::ClientOptions::Config config;
        config.clientconf.dco = false;
        config.proto_context_options.reset(new openvpn::ProtoContextCompressionOptions());
        const auto parsed = openvpn::ParseClientConfig::parse(profile ? profile : "", nullptr, options);
        if (parsed.error())
        {
            copy_message(message, message_size, parsed.message());
            return false;
        }
        openvpn::ClientOptions client_options(options, config);
        return true;
    }
    catch (const std::exception &e)
    {
        copy_message(message, message_size, e.what());
        return false;
    }
}

extern "C" vpnplus_engine *vpnplus_engine_create(const vpnplus_engine_callbacks *callbacks, const char *client_version)
{
    if (callbacks == nullptr)
        return nullptr;
    try
    {
        auto *engine = new vpnplus_engine;
        engine->client = std::make_unique<Client>(*callbacks, client_version ? client_version : "");
        return engine;
    }
    catch (...)
    {
        return nullptr;
    }
}

extern "C" void vpnplus_engine_destroy(vpnplus_engine *engine)
{
    delete engine;
}

extern "C" bool vpnplus_engine_prepare(vpnplus_engine *engine, const char *profile, const char *username, const char *password, char *message, size_t message_size)
{
    if (engine == nullptr)
        return false;
    try
    {
        std::string text;
        const bool ok = engine->client->prepare(profile, username, password, text);
        if (!ok)
            copy_message(message, message_size, text);
        return ok;
    }
    catch (const std::exception &e)
    {
        copy_message(message, message_size, e.what());
        return false;
    }
}

extern "C" bool vpnplus_engine_run(vpnplus_engine *engine, char *message, size_t message_size)
{
    if (engine == nullptr)
        return false;
    try
    {
        std::string text;
        const bool ok = engine->client->run(text);
        if (!ok)
            copy_message(message, message_size, text);
        return ok;
    }
    catch (const std::exception &e)
    {
        copy_message(message, message_size, e.what());
        return false;
    }
}

extern "C" void vpnplus_engine_stop(vpnplus_engine *engine)
{
    if (engine)
        engine->client->stop();
}

extern "C" void vpnplus_engine_pause(vpnplus_engine *engine, const char *reason)
{
    if (engine)
        engine->client->pause(reason ? reason : "");
}

extern "C" void vpnplus_engine_resume(vpnplus_engine *engine)
{
    if (engine)
        engine->client->resume();
}

extern "C" void vpnplus_engine_reconnect(vpnplus_engine *engine, int seconds)
{
    if (engine)
        engine->client->reconnect(seconds);
}

extern "C" bool vpnplus_engine_connection_info(vpnplus_engine *engine, vpnplus_connection_info *out)
{
    if (engine == nullptr || out == nullptr)
        return false;
    std::memset(out, 0, sizeof *out);
    return engine->client->connection_info_into(*out);
}

extern "C" void vpnplus_engine_transport_stats(vpnplus_engine *engine, vpnplus_transport_stats *out)
{
    if (engine == nullptr || out == nullptr)
        return;
    const openvpn::ClientAPI::TransportStats stats = engine->client->transport_stats();
    out->bytes_in = stats.bytesIn;
    out->bytes_out = stats.bytesOut;
    out->packets_in = stats.packetsIn;
    out->packets_out = stats.packetsOut;
    out->last_packet_received = stats.lastPacketReceived;
}
