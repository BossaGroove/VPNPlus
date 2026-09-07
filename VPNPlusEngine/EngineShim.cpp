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

#include <algorithm>
#include <cstring>
#include <map>
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

    bool prepare(const char *profile, const char *username, const char *password,
                 const vpnplus_overrides *overrides, std::string &message)
    {
        ClientAPI::Config config;
        config.content = profile ? profile : "";
        // The user's choice of server, applied without rewriting the profile
        // text, which is stored verbatim (D188).
        if (overrides != nullptr)
        {
            if (overrides->server != nullptr)
                config.serverOverride = overrides->server;
            if (overrides->port != nullptr)
                config.portOverride = overrides->port;
            if (overrides->transport != nullptr)
                config.protoOverride = overrides->transport;
        }
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

namespace {

/// Collects the engine's log lines while a profile is parsed. openvpn3 reports
/// the directives it set aside through its log, and only throws for the fatal
/// ones, so this is the only way to see the whole picture (D187 wants the list,
/// not just a yes or no).
class LogCollector final : public openvpn::ClientAPI::LogReceiver
{
  public:
    void log(const openvpn::ClientAPI::LogInfo &info) override
    {
        std::string line;
        for (const char c : info.text)
        {
            if (c == '\n')
            {
                lines_.push_back(line);
                line.clear();
            }
            else if (c != '\r')
            {
                line += c;
            }
        }
        if (!line.empty())
            lines_.push_back(line);
    }

    const std::vector<std::string> &lines() const
    {
        return lines_;
    }

  private:
    std::vector<std::string> lines_;
};

/// The categories openvpn3 treats as fatal — the `true` argument to
/// `showUnusedOptionsByList` and `showOptionsByFunction` in cliopt.hpp. Every
/// other category is one the engine ignores while still connecting.
bool category_is_fatal(const std::string &category)
{
    static const char *const fatal[] = {
        "Removed deprecated option",
        "Server only option",
        "OpenVPN 2.x command line operation",
        "Option allowed only to be pushed by the server",
        "OpenVPN management interface is not supported by this client",
        "UNKNOWN/UNSUPPORTED OPTIONS",
    };
    for (const char *f : fatal)
        if (category.find(f) != std::string::npos)
            return true;
    return false;
}

/// Directives that must never be set aside, whatever the user asks: without
/// them the tunnel would not do what the profile says (feature-spec 2.9). Kept
/// deliberately small and justified; B7's sweep found only this one in the
/// unrecognised group.
bool never_waivable(const std::string &directive)
{
    return directive == "pkcs12"; // the client identity itself (2.10, D192)
}

/// One directive openvpn3 reported, with the category it reported it under.
struct ReportedDirective
{
    std::string name;
    std::string category;
};

/// openvpn3 logs a category line, then one indexed line per directive:
///     Unsupported option (ignored)
///     0 [resolv-retry] [infinite]
/// Anything else is prose we do not need.
std::vector<ReportedDirective> parse_reported(const std::vector<std::string> &lines)
{
    std::vector<ReportedDirective> out;
    std::string category;
    for (const std::string &raw : lines)
    {
        const size_t begin = raw.find_first_not_of(" \t");
        if (begin == std::string::npos)
            continue;
        const std::string line = raw.substr(begin);
        if (line.rfind("NOTE:", 0) == 0)
            continue;

        // "<n> [name] ..." — an entry under the current category.
        size_t i = 0;
        while (i < line.size() && std::isdigit(static_cast<unsigned char>(line[i])))
            ++i;
        if (i > 0 && i + 1 < line.size() && line[i] == ' ' && line[i + 1] == '[')
        {
            const size_t close = line.find(']', i + 2);
            if (close != std::string::npos && !category.empty())
                out.push_back({line.substr(i + 2, close - i - 2), category});
            continue;
        }
        category = line;
    }
    return out;
}

void report(const std::vector<ReportedDirective> &directives, bool refused,
            vpnplus_directive_callback callback, void *context)
{
    if (callback == nullptr)
        return;
    for (const ReportedDirective &d : directives)
    {
        vpnplus_directive_kind kind = VPNPLUS_DIRECTIVE_IGNORED;
        if (category_is_fatal(d.category))
        {
            const bool unrecognised = d.category.find("UNKNOWN/UNSUPPORTED OPTIONS") != std::string::npos;
            kind = (unrecognised && !never_waivable(d.name) && refused)
                       ? VPNPLUS_DIRECTIVE_WAIVABLE
                       : VPNPLUS_DIRECTIVE_BLOCKING;
        }
        callback(context, d.name.c_str(), d.category.c_str(), kind);
    }
}

} // namespace

extern "C" size_t vpnplus_engine_merge(const char *path, char *profile, size_t profile_size, vpnplus_merge_info *out)
{
    if (out == nullptr)
        return 0;
    std::memset(out, 0, sizeof *out);
    try
    {
        openvpn::ClientAPI::OpenVPNClientHelper helper;
        // Follow references: a profile that names its certificate in a
        // neighbouring file is the ordinary case, and 2.2 wants them inlined.
        const openvpn::ClientAPI::MergeConfig merged = helper.merge_config(path ? path : "", true);
        copy_field(out->status, sizeof out->status, merged.status);
        copy_field(out->message, sizeof out->message, merged.errorText);
        copy_field(out->basename, sizeof out->basename, merged.basename);
        out->reference_count = merged.refPathList.size();
        out->ok = merged.status == "MERGE_SUCCESS";
        if (!out->ok)
        {
            // The engine's error text is "ERR_PROFILE_<code>: <detail>", and for
            // a reference it could not read the detail is the filename — which
            // is what 2.3 must show the user.
            const size_t colon = merged.errorText.find(": ");
            if (colon != std::string::npos && merged.status.find("REF_FAIL") != std::string::npos)
                copy_field(out->missing_reference, sizeof out->missing_reference, merged.errorText.substr(colon + 2));
            return 0;
        }
        const std::string &content = merged.profileContent;
        if (profile != nullptr && content.size() < profile_size)
        {
            std::memcpy(profile, content.data(), content.size());
            profile[content.size()] = '\0';
        }
        return content.size();
    }
    catch (const std::exception &e)
    {
        copy_field(out->status, sizeof out->status, "MERGE_EXCEPTION");
        copy_field(out->message, sizeof out->message, e.what());
        return 0;
    }
}

extern "C" bool vpnplus_engine_describe(const char *profile, vpnplus_profile_info *out,
                                        vpnplus_server_callback servers, void *context)
{
    if (out == nullptr)
        return false;
    std::memset(out, 0, sizeof *out);
    try
    {
        openvpn::ClientAPI::OpenVPNClientHelper helper;
        openvpn::ClientAPI::Config config;
        config.content = profile ? profile : "";
        const openvpn::ClientAPI::EvalConfig eval = helper.eval_config(config);
        copy_field(out->message, sizeof out->message, eval.message);
        if (eval.error)
            return false;
        copy_field(out->profile_name, sizeof out->profile_name, eval.profileName);
        copy_field(out->friendly_name, sizeof out->friendly_name, eval.friendlyName);
        copy_field(out->fixed_username, sizeof out->fixed_username, eval.userlockedUsername);
        out->autologin = eval.autologin;
        out->external_pki = eval.externalPki;
        out->allow_password_save = eval.allowPasswordSave;
        out->private_key_password_required = eval.privateKeyPasswordRequired;
        copy_field(out->static_challenge, sizeof out->static_challenge, eval.staticChallenge);
        out->static_challenge_echo = eval.staticChallengeEcho;
        copy_field(out->remote_host, sizeof out->remote_host, eval.remoteHost);
        copy_field(out->remote_port, sizeof out->remote_port, eval.remotePort);
        copy_field(out->remote_proto, sizeof out->remote_proto, eval.remoteProto);
        out->server_count = eval.serverList.size();
        if (servers != nullptr)
            for (const auto &entry : eval.serverList)
                servers(context, entry.server.c_str(), entry.friendlyName.c_str());
        out->ok = true;
        return true;
    }
    catch (const std::exception &e)
    {
        copy_field(out->message, sizeof out->message, e.what());
        return false;
    }
}

// D189: eval_config accepts almost anything — seven of the eight defects B7
// tested pass it clean — and the ones that matter are thrown when ClientOptions
// is constructed inside connect(). This runs that construction with no network,
// the way upstream's own unit tests do, and reports what would happen.
extern "C" void vpnplus_engine_validate(const char *profile,
                                        const char *const *waive, size_t waive_count,
                                        vpnplus_validation *out,
                                        vpnplus_directive_callback directives, void *context)
{
    if (out == nullptr)
        return;
    out->verdict = VPNPLUS_VERDICT_REFUSED;
    out->refusal = VPNPLUS_REFUSAL_MALFORMED;
    out->message[0] = '\0';

    std::string content = profile ? profile : "";
    std::vector<std::string> honoured;
    for (size_t i = 0; waive != nullptr && i < waive_count; ++i)
    {
        if (waive[i] == nullptr || *waive[i] == '\0')
            continue;
        // 2.9 is enforced here rather than in the caller: a directive whose
        // absence would change what the tunnel does cannot be set aside even
        // if asked, so no UI can bypass the rule by accident.
        if (!never_waivable(waive[i]))
            honoured.push_back(waive[i]);
    }
    if (!honoured.empty())
    {
        // The engine's own way of setting a directive aside; storing the
        // decision with the profile is D187's other half.
        content += "\nignore-unknown-option";
        for (const std::string &name : honoured)
            content += " " + name;
        content += "\n";
    }

    LogCollector collector;
    try
    {
        openvpn::InitProcess::Init init;
        openvpn::Log::Context log_context(&collector);

        openvpn::OptionList options;
        const auto parsed = openvpn::ParseClientConfig::parse(content, nullptr, options);
        if (parsed.error())
        {
            copy_message(out->message, sizeof out->message, parsed.message());
            // The one defect the static parse does catch (B7).
            out->refusal = parsed.message().find("SERVER_LOCKED") != std::string::npos
                               ? VPNPLUS_REFUSAL_SERVER_LOCKED
                               : VPNPLUS_REFUSAL_MALFORMED;
            return;
        }

        openvpn::ClientOptions::Config config;
        config.clientconf.dco = false;
        config.proto_context_options.reset(new openvpn::ProtoContextCompressionOptions());
        openvpn::ClientOptions client_options(options, config);

        const auto reported = parse_reported(collector.lines());
        report(reported, false, directives, context);
        out->refusal = VPNPLUS_REFUSAL_NONE;
        out->verdict = reported.empty() ? VPNPLUS_VERDICT_ACCEPTED : VPNPLUS_VERDICT_ACCEPTED_WITH_WAIVERS;
    }
    catch (const std::exception &e)
    {
        copy_message(out->message, sizeof out->message, e.what());
        const auto reported = parse_reported(collector.lines());
        report(reported, true, directives, context);

        const std::string text = e.what();
        const bool unknown = text.find("UNKNOWN/UNSUPPORTED OPTIONS") != std::string::npos;
        bool key_store = false;
        for (const auto &d : reported)
            if (never_waivable(d.name) && category_is_fatal(d.category))
                key_store = true;

        out->refusal = key_store ? VPNPLUS_REFUSAL_EXTERNAL_KEY_STORE
                       : unknown ? VPNPLUS_REFUSAL_UNKNOWN_DIRECTIVES
                                 : VPNPLUS_REFUSAL_UNSUPPORTED_FEATURE;
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

extern "C" bool vpnplus_engine_prepare(vpnplus_engine *engine, const char *profile, const char *username, const char *password, const vpnplus_overrides *overrides, char *message, size_t message_size)
{
    if (engine == nullptr)
        return false;
    try
    {
        std::string text;
        const bool ok = engine->client->prepare(profile, username, password, overrides, text);
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
