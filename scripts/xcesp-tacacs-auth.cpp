/**
 * @file    xcesp-tacacs-auth.cpp
 * @brief   TACACS+ centralised authentication for XCESP (0.2.10+)
 * @project XCESP
 * @license LGPL-3.0-or-later
 *
 * Standalone authentication tool used by the shared `xcesp-tacacs` SSH pool
 * account.  sshd's ForceCommand invokes this binary; we prompt the user
 * for their real username + password on the controlling TTY, send a
 * TACACS+ Authentication-Request to the configured server(s), parse the
 * reply, then send an Authorization-Request to retrieve the user's
 * priv-lvl.  The priv-lvl is mapped to an XCESP CliRole (1..4) via the
 * configured priv-lvl-map; we exec /usr/lib/xcesp/xcesp-login with
 * XCESP_ROLE_OVERRIDE + XCESP_AUDIT_USER in the environment.
 *
 * RFC 8907 (TACACS+) packet format is implemented directly — there is
 * no cross-distro client library (Fedora 41 has no libtac), and our
 * needs are narrow (ASCII auth + shell authorization).  The MD5
 * keystream cipher uses libcrypto (linked dynamically; libcrypto is
 * ubiquitous on every Linux distro we target).
 *
 * Config file: /etc/xcesp/tacacs.conf (mode 0600 root:xcesp; written by
 * xcesp-activate from the running config).  Format:
 *
 *     # xcesp tacacs-auth v1
 *     server 10.0.0.50:49
 *     server 10.0.0.51:49
 *     key   shared-secret
 *     timeout 5
 *     priv-lvl-map 15:1 10:2 5:3 0:4
 *
 * Servers are tried in declaration order; the first successful TCP
 * connect attempts authentication.  A REJECT from one server is
 * authoritative (we do NOT failover to a second server on REJECT — only
 * on TCP/timeout failure).  This matches Cisco/Juniper behaviour.
 */

#include <openssl/evp.h>

#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fstream>
#include <iostream>
#include <random>
#include <sstream>
#include <string>
#include <syslog.h>
#include <vector>

namespace {

// ---------------------------------------------------------------------------
// TACACS+ wire constants (RFC 8907)
// ---------------------------------------------------------------------------

constexpr uint8_t TAC_PLUS_MAJOR_VER         = 0xC;
constexpr uint8_t TAC_PLUS_MINOR_VER_DEFAULT = 0x0;
constexpr uint8_t TAC_PLUS_MINOR_VER_ONE     = 0x1;

constexpr uint8_t TAC_PLUS_AUTHEN = 0x01;
constexpr uint8_t TAC_PLUS_AUTHOR = 0x02;

constexpr uint8_t TAC_PLUS_UNENCRYPTED_FLAG = 0x01;
constexpr uint8_t TAC_PLUS_SINGLE_CONNECT_FLAG = 0x04;

constexpr uint8_t TAC_PLUS_AUTHEN_LOGIN  = 0x01;
constexpr uint8_t TAC_PLUS_AUTHEN_TYPE_ASCII = 0x01;
constexpr uint8_t TAC_PLUS_AUTHEN_SVC_LOGIN  = 0x01;

constexpr uint8_t TAC_PLUS_AUTHEN_STATUS_PASS    = 0x01;
constexpr uint8_t TAC_PLUS_AUTHEN_STATUS_FAIL    = 0x02;
constexpr uint8_t TAC_PLUS_AUTHEN_STATUS_GETUSER = 0x05;
constexpr uint8_t TAC_PLUS_AUTHEN_STATUS_GETPASS = 0x06;
constexpr uint8_t TAC_PLUS_AUTHEN_STATUS_RESTART = 0x07;
constexpr uint8_t TAC_PLUS_AUTHEN_STATUS_ERROR   = 0x08;

constexpr uint8_t TAC_PLUS_AUTHEN_METH_TACACSPLUS = 0x06;
constexpr uint8_t TAC_PLUS_AUTHEN_TYPE_NOT_SET    = 0x00;

constexpr uint8_t TAC_PLUS_AUTHOR_STATUS_PASS_ADD  = 0x01;
constexpr uint8_t TAC_PLUS_AUTHOR_STATUS_PASS_REPL = 0x02;
constexpr uint8_t TAC_PLUS_AUTHOR_STATUS_FAIL      = 0x10;
constexpr uint8_t TAC_PLUS_AUTHOR_STATUS_ERROR     = 0x11;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

std::string trim(const std::string& s) {
    size_t a = 0, b = s.size();
    while (a < b && std::isspace(static_cast<unsigned char>(s[a]))) ++a;
    while (b > a && std::isspace(static_cast<unsigned char>(s[b-1]))) --b;
    return s.substr(a, b - a);
}

std::vector<std::string> splitWs(const std::string& s) {
    std::vector<std::string> out;
    std::istringstream iss(s);
    std::string tok;
    while (iss >> tok) out.push_back(tok);
    return out;
}

std::string readPasswordSilent(const std::string& prompt) {
    std::cerr << prompt << std::flush;
    termios oldt;
    if (tcgetattr(STDIN_FILENO, &oldt) == 0) {
        termios newt = oldt;
        newt.c_lflag &= ~ECHO;
        tcsetattr(STDIN_FILENO, TCSANOW, &newt);
    }
    std::string pw;
    std::getline(std::cin, pw);
    if (tcgetattr(STDIN_FILENO, &oldt) == 0) {
        oldt.c_lflag |= ECHO;
        tcsetattr(STDIN_FILENO, TCSANOW, &oldt);
    }
    std::cerr << "\n";
    return pw;
}

uint32_t makeSessionId() {
    std::random_device rd;
    return (static_cast<uint32_t>(rd()) ^ static_cast<uint32_t>(std::time(nullptr)));
}

// ---------------------------------------------------------------------------
// Config parser — /etc/xcesp/tacacs.conf
// ---------------------------------------------------------------------------

struct Server {
    std::string host;
    int         port = 49;
};

struct Config {
    std::vector<Server> servers;
    std::string         secret;
    int                 timeoutS = 5;
    std::string         privLvlMap;   // e.g. "15:1 10:2 5:3 0:4"
};

bool readConfig(const std::string& path, Config& cfg, std::string& err) {
    std::ifstream f(path);
    if (!f) { err = "cannot open " + path; return false; }
    std::string line;
    int lineNo = 0;
    while (std::getline(f, line)) {
        ++lineNo;
        std::string t = trim(line);
        if (t.empty() || t[0] == '#') continue;
        auto sp = t.find_first_of(" \t");
        if (sp == std::string::npos) {
            err = path + ":" + std::to_string(lineNo) + ": malformed line";
            return false;
        }
        std::string key = t.substr(0, sp);
        std::string val = trim(t.substr(sp));
        if (key == "server") {
            Server s;
            auto colon = val.find(':');
            if (colon == std::string::npos) {
                s.host = val;
                s.port = 49;
            } else {
                s.host = val.substr(0, colon);
                s.port = std::atoi(val.substr(colon + 1).c_str());
                if (s.port <= 0) s.port = 49;
            }
            cfg.servers.push_back(s);
        } else if (key == "key" || key == "secret") {
            cfg.secret = val;
        } else if (key == "timeout") {
            cfg.timeoutS = std::atoi(val.c_str());
            if (cfg.timeoutS < 1) cfg.timeoutS = 5;
        } else if (key == "priv-lvl-map") {
            cfg.privLvlMap = val;
        }
        // unknown keys silently ignored — forward-compatible
    }
    if (cfg.servers.empty()) { err = "no servers configured"; return false; }
    if (cfg.secret.empty())  { err = "shared secret missing"; return false; }
    return true;
}

// priv-lvl map: whitespace-separated "<min-priv>:<role>" pairs, evaluated
// in descending priv order.  E.g. "15:1 10:2 5:3 0:4" — priv >= 15 → role 1,
// priv >= 10 → role 2, etc.  Default for unmatched: SHOW_ONLY (4).
int mapPrivLvl(const std::string& mapStr, int privLvl, int defaultRole = 4) {
    auto pairs = splitWs(mapStr);
    struct E { int threshold; int role; };
    std::vector<E> entries;
    for (const auto& p : pairs) {
        auto colon = p.find(':');
        if (colon == std::string::npos) continue;
        E e;
        e.threshold = std::atoi(p.substr(0, colon).c_str());
        e.role      = std::atoi(p.substr(colon + 1).c_str());
        if (e.role < 1 || e.role > 4) continue;
        entries.push_back(e);
    }
    if (entries.empty()) {
        // Built-in defaults: 15→1, 10→2, 5→3, 0→4
        if (privLvl >= 15) return 1;
        if (privLvl >= 10) return 2;
        if (privLvl >= 5)  return 3;
        return 4;
    }
    // Sort by threshold descending, pick first match.
    std::sort(entries.begin(), entries.end(),
              [](const E& a, const E& b){ return a.threshold > b.threshold; });
    for (const auto& e : entries) {
        if (privLvl >= e.threshold) return e.role;
    }
    return defaultRole;
}

// ---------------------------------------------------------------------------
// TACACS+ packet codec
// ---------------------------------------------------------------------------

// Packet header (RFC 8907 §4.1): 12 bytes, fixed.
//   uint8  major.minor version
//   uint8  type            (AUTHEN / AUTHOR / ACCT)
//   uint8  seq_no          (1, 3, 5, ... from client)
//   uint8  flags
//   uint32 session_id
//   uint32 length          (body length, NETWORK BYTE ORDER)
struct PktHeader {
    uint8_t  version;
    uint8_t  type;
    uint8_t  seq;
    uint8_t  flags;
    uint32_t sessionId;
    uint32_t length;
};

void encodeHeader(const PktHeader& h, std::vector<uint8_t>& out) {
    out.resize(12);
    out[0] = h.version;
    out[1] = h.type;
    out[2] = h.seq;
    out[3] = h.flags;
    uint32_t sid = htonl(h.sessionId);
    uint32_t len = htonl(h.length);
    std::memcpy(&out[4], &sid, 4);
    std::memcpy(&out[8], &len, 4);
}

bool decodeHeader(const uint8_t* buf, PktHeader& h) {
    h.version = buf[0];
    h.type    = buf[1];
    h.seq     = buf[2];
    h.flags   = buf[3];
    uint32_t sid, len;
    std::memcpy(&sid, &buf[4], 4);
    std::memcpy(&len, &buf[8], 4);
    h.sessionId = ntohl(sid);
    h.length    = ntohl(len);
    return true;
}

// MD5 keystream (RFC 8907 §4.5).  Generates `n` bytes of pseudo-random
// material derived from session_id, secret, version, seq_no using a
// chained MD5 construction.  XOR'd against the cleartext body.
void md5Keystream(uint32_t sessionId, const std::string& secret,
                  uint8_t version, uint8_t seq,
                  size_t bodyLen, std::vector<uint8_t>& out)
{
    out.clear();
    out.reserve(bodyLen);

    uint32_t sidNet = htonl(sessionId);

    // hash_1 = MD5(session_id || secret || version || seq_no)
    // hash_n = MD5(session_id || secret || version || seq_no || hash_{n-1})
    //
    // Use the EVP interface (OpenSSL 3.x-friendly; not deprecated, unlike
    // the legacy MD5_Init/Update/Final).  MD5 is a non-FIPS algorithm but
    // remains available in the default OpenSSL provider.
    std::vector<uint8_t> prev;
    while (out.size() < bodyLen) {
        EVP_MD_CTX* ctx = EVP_MD_CTX_new();
        EVP_DigestInit_ex(ctx, EVP_md5(), nullptr);
        EVP_DigestUpdate(ctx, &sidNet, 4);
        EVP_DigestUpdate(ctx, secret.data(), secret.size());
        EVP_DigestUpdate(ctx, &version, 1);
        EVP_DigestUpdate(ctx, &seq, 1);
        if (!prev.empty()) EVP_DigestUpdate(ctx, prev.data(), prev.size());
        prev.resize(16);
        unsigned int n = 16;
        EVP_DigestFinal_ex(ctx, prev.data(), &n);
        EVP_MD_CTX_free(ctx);
        out.insert(out.end(), prev.begin(), prev.end());
    }
    out.resize(bodyLen);
}

void encryptBody(uint32_t sessionId, const std::string& secret,
                 uint8_t version, uint8_t seq,
                 std::vector<uint8_t>& body)
{
    if (secret.empty()) return;
    std::vector<uint8_t> ks;
    md5Keystream(sessionId, secret, version, seq, body.size(), ks);
    for (size_t i = 0; i < body.size(); ++i) body[i] ^= ks[i];
}

// ---------------------------------------------------------------------------
// Body builders
// ---------------------------------------------------------------------------

// Authentication START (§5.1):
//   action, priv_lvl, authen_type, service,
//   user_len, port_len, rem_addr_len, data_len,
//   user, port, rem_addr, data
std::vector<uint8_t> buildAuthenStart(const std::string& user,
                                       const std::string& port,
                                       const std::string& remAddr)
{
    std::vector<uint8_t> b;
    b.push_back(TAC_PLUS_AUTHEN_LOGIN);          // action
    b.push_back(0);                              // priv_lvl
    b.push_back(TAC_PLUS_AUTHEN_TYPE_ASCII);     // authen_type
    b.push_back(TAC_PLUS_AUTHEN_SVC_LOGIN);      // service
    b.push_back(static_cast<uint8_t>(user.size()));    // user_len
    b.push_back(static_cast<uint8_t>(port.size()));    // port_len
    b.push_back(static_cast<uint8_t>(remAddr.size())); // rem_addr_len
    b.push_back(0);                              // data_len (no inline data)
    b.insert(b.end(), user.begin(), user.end());
    b.insert(b.end(), port.begin(), port.end());
    b.insert(b.end(), remAddr.begin(), remAddr.end());
    return b;
}

// Authentication CONTINUE (§5.3):
//   user_msg_len, data_len, flags, user_msg, data
std::vector<uint8_t> buildAuthenContinue(const std::string& userMsg)
{
    std::vector<uint8_t> b;
    uint16_t userLen = htons(static_cast<uint16_t>(userMsg.size()));
    uint16_t dataLen = 0;
    b.resize(5);
    std::memcpy(&b[0], &userLen, 2);
    std::memcpy(&b[2], &dataLen, 2);
    b[4] = 0;
    b.insert(b.end(), userMsg.begin(), userMsg.end());
    return b;
}

// Authentication REPLY (§5.2):
//   status, flags, server_msg_len(2), data_len(2), server_msg, data
struct AuthenReply {
    uint8_t status;
    uint8_t flags;
    std::string serverMsg;
};
bool parseAuthenReply(const std::vector<uint8_t>& body, AuthenReply& r) {
    if (body.size() < 6) return false;
    r.status = body[0];
    r.flags  = body[1];
    uint16_t smLen, dataLen;
    std::memcpy(&smLen,   &body[2], 2); smLen   = ntohs(smLen);
    std::memcpy(&dataLen, &body[4], 2); dataLen = ntohs(dataLen);
    if (static_cast<size_t>(6) + smLen + dataLen > body.size()) return false;
    r.serverMsg.assign(reinterpret_cast<const char*>(&body[6]), smLen);
    return true;
}

// Authorization REQUEST (§6.1):
//   authen_method, priv_lvl, authen_type, authen_service,
//   user_len, port_len, rem_addr_len, arg_cnt,
//   arg_1_len .. arg_n_len, user, port, rem_addr, arg_1 .. arg_n
std::vector<uint8_t> buildAuthorRequest(const std::string& user,
                                         const std::string& port,
                                         const std::string& remAddr,
                                         const std::vector<std::string>& args)
{
    std::vector<uint8_t> b;
    b.push_back(TAC_PLUS_AUTHEN_METH_TACACSPLUS);
    b.push_back(0);                              // priv_lvl
    b.push_back(TAC_PLUS_AUTHEN_TYPE_NOT_SET);
    b.push_back(TAC_PLUS_AUTHEN_SVC_LOGIN);
    b.push_back(static_cast<uint8_t>(user.size()));
    b.push_back(static_cast<uint8_t>(port.size()));
    b.push_back(static_cast<uint8_t>(remAddr.size()));
    b.push_back(static_cast<uint8_t>(args.size()));
    for (const auto& a : args) b.push_back(static_cast<uint8_t>(a.size()));
    b.insert(b.end(), user.begin(), user.end());
    b.insert(b.end(), port.begin(), port.end());
    b.insert(b.end(), remAddr.begin(), remAddr.end());
    for (const auto& a : args) b.insert(b.end(), a.begin(), a.end());
    return b;
}

// Authorization RESPONSE (§6.2):
//   status, arg_cnt, server_msg_len(2), data_len(2),
//   arg_1_len .. arg_n_len, server_msg, data, arg_1 .. arg_n
struct AuthorResponse {
    uint8_t                 status;
    std::vector<std::string> args;
    std::string              serverMsg;
};
bool parseAuthorResponse(const std::vector<uint8_t>& body, AuthorResponse& r) {
    if (body.size() < 6) return false;
    r.status      = body[0];
    uint8_t  ac   = body[1];
    uint16_t smLen, dataLen;
    std::memcpy(&smLen,   &body[2], 2); smLen   = ntohs(smLen);
    std::memcpy(&dataLen, &body[4], 2); dataLen = ntohs(dataLen);
    if (size_t(6 + ac) > body.size()) return false;
    std::vector<uint8_t> argLens(body.begin() + 6, body.begin() + 6 + ac);
    size_t pos = 6 + ac;
    if (pos + smLen + dataLen > body.size()) return false;
    r.serverMsg.assign(reinterpret_cast<const char*>(&body[pos]), smLen);
    pos += smLen + dataLen;
    for (uint8_t i = 0; i < ac; ++i) {
        if (pos + argLens[i] > body.size()) return false;
        r.args.emplace_back(reinterpret_cast<const char*>(&body[pos]), argLens[i]);
        pos += argLens[i];
    }
    return true;
}

// ---------------------------------------------------------------------------
// TCP I/O with timeout
// ---------------------------------------------------------------------------

int connectTcp(const std::string& host, int port, int timeoutS, std::string& err) {
    struct addrinfo hints{}, *res = nullptr;
    hints.ai_family   = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    int gai = ::getaddrinfo(host.c_str(), std::to_string(port).c_str(), &hints, &res);
    if (gai != 0) { err = std::string("getaddrinfo: ") + gai_strerror(gai); return -1; }
    int fd = -1;
    for (auto* ai = res; ai != nullptr; ai = ai->ai_next) {
        fd = ::socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        struct timeval tv{ timeoutS, 0 };
        ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        ::setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        if (::connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        ::close(fd);
        fd = -1;
    }
    ::freeaddrinfo(res);
    if (fd < 0) err = std::string("connect: ") + std::strerror(errno);
    return fd;
}

bool sendAll(int fd, const std::vector<uint8_t>& buf) {
    size_t off = 0;
    while (off < buf.size()) {
        ssize_t n = ::send(fd, &buf[off], buf.size() - off, 0);
        if (n <= 0) return false;
        off += static_cast<size_t>(n);
    }
    return true;
}

bool recvN(int fd, size_t n, std::vector<uint8_t>& out) {
    out.resize(n);
    size_t off = 0;
    while (off < n) {
        ssize_t r = ::recv(fd, &out[off], n - off, 0);
        if (r <= 0) return false;
        off += static_cast<size_t>(r);
    }
    return true;
}

// ---------------------------------------------------------------------------
// TacacsClient — one server, one session
// ---------------------------------------------------------------------------

class TacacsClient {
public:
    TacacsClient(int fd, const std::string& secret, uint8_t version)
        : fd_(fd), secret_(secret), version_(version),
          sessionId_(makeSessionId()), seq_(1) {}
    ~TacacsClient() { if (fd_ >= 0) ::close(fd_); }

    bool sendBody(uint8_t type, std::vector<uint8_t> body) {
        PktHeader h;
        h.version   = version_;
        h.type      = type;
        h.seq       = seq_;
        h.flags     = 0;
        h.sessionId = sessionId_;
        h.length    = static_cast<uint32_t>(body.size());
        encryptBody(sessionId_, secret_, version_, seq_, body);
        std::vector<uint8_t> hdr;
        encodeHeader(h, hdr);
        std::vector<uint8_t> pkt;
        pkt.reserve(hdr.size() + body.size());
        pkt.insert(pkt.end(), hdr.begin(), hdr.end());
        pkt.insert(pkt.end(), body.begin(), body.end());
        if (!sendAll(fd_, pkt)) return false;
        seq_ += 2;   // odd from client side
        return true;
    }

    bool recvBody(uint8_t expectType, std::vector<uint8_t>& body) {
        std::vector<uint8_t> hdrBuf;
        if (!recvN(fd_, 12, hdrBuf)) return false;
        PktHeader h;
        decodeHeader(hdrBuf.data(), h);
        if (h.type != expectType)                  return false;
        if (h.sessionId != sessionId_)             return false;
        if (h.length > 1 << 16)                    return false;  // sanity
        if (!recvN(fd_, h.length, body))           return false;
        encryptBody(sessionId_, secret_, version_, h.seq, body);
        return true;
    }

private:
    int          fd_;
    std::string  secret_;
    uint8_t      version_;
    uint32_t     sessionId_;
    uint8_t      seq_;
};

// ---------------------------------------------------------------------------
// High-level auth flow
// ---------------------------------------------------------------------------

bool tacacsAuthenticate(TacacsClient& cli,
                         const std::string& user,
                         const std::string& pass,
                         const std::string& tty,
                         const std::string& remAddr,
                         std::string& err)
{
    // 1. START
    if (!cli.sendBody(TAC_PLUS_AUTHEN, buildAuthenStart(user, tty, remAddr))) {
        err = "send START failed"; return false;
    }

    // Walk reply chain until PASS/FAIL.  Most servers send REPLY-GETPASS
    // immediately (since START already has user_len > 0); some send
    // GETUSER first if user is empty.  Limit to a few rounds to avoid loops.
    for (int round = 0; round < 5; ++round) {
        std::vector<uint8_t> body;
        if (!cli.recvBody(TAC_PLUS_AUTHEN, body)) { err = "recv REPLY failed"; return false; }
        AuthenReply r;
        if (!parseAuthenReply(body, r))            { err = "malformed REPLY"; return false; }

        switch (r.status) {
            case TAC_PLUS_AUTHEN_STATUS_PASS:
                return true;
            case TAC_PLUS_AUTHEN_STATUS_FAIL:
                err = r.serverMsg.empty() ? "TACACS+ authentication failed"
                                          : r.serverMsg;
                return false;
            case TAC_PLUS_AUTHEN_STATUS_GETUSER:
                if (!cli.sendBody(TAC_PLUS_AUTHEN, buildAuthenContinue(user))) {
                    err = "send CONTINUE(user) failed"; return false;
                }
                break;
            case TAC_PLUS_AUTHEN_STATUS_GETPASS:
                if (!cli.sendBody(TAC_PLUS_AUTHEN, buildAuthenContinue(pass))) {
                    err = "send CONTINUE(pass) failed"; return false;
                }
                break;
            case TAC_PLUS_AUTHEN_STATUS_RESTART:
            case TAC_PLUS_AUTHEN_STATUS_ERROR:
            default:
                err = "TACACS+ protocol error (status=" + std::to_string(r.status) + ")";
                return false;
        }
    }
    err = "TACACS+ auth flow exceeded 5 rounds";
    return false;
}

int tacacsAuthorize(TacacsClient& cli,
                     const std::string& user,
                     const std::string& tty,
                     const std::string& remAddr,
                     std::string& err)
{
    // Single Authorization request for service=shell, cmd=  (login shell).
    std::vector<std::string> args = {
        "service=shell",
        "cmd*",     // optional, empty: any cmd
    };
    if (!cli.sendBody(TAC_PLUS_AUTHOR, buildAuthorRequest(user, tty, remAddr, args))) {
        err = "send authorization REQUEST failed";
        return -1;
    }
    std::vector<uint8_t> body;
    if (!cli.recvBody(TAC_PLUS_AUTHOR, body)) { err = "recv RESPONSE failed"; return -1; }
    AuthorResponse r;
    if (!parseAuthorResponse(body, r))         { err = "malformed RESPONSE"; return -1; }
    if (r.status != TAC_PLUS_AUTHOR_STATUS_PASS_ADD &&
        r.status != TAC_PLUS_AUTHOR_STATUS_PASS_REPL) {
        err = r.serverMsg.empty() ? "authorization failed" : r.serverMsg;
        return -1;
    }
    // Extract priv-lvl from av-pairs.  Format: "priv-lvl=15" or "priv-lvl*15"
    // (`=` is mandatory, `*` is optional).
    for (const auto& av : r.args) {
        if (av.size() < 9) continue;
        if (av.compare(0, 8, "priv-lvl") != 0) continue;
        if (av[8] != '=' && av[8] != '*') continue;
        try {
            return std::stoi(av.substr(9));
        } catch (...) { /* fall through */ }
    }
    // No priv-lvl returned — default to 0 (least privilege).
    return 0;
}

} // namespace

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main(int /*argc*/, char* /*argv*/[]) {
    openlog("xcesp-tacacs-auth", LOG_PID, LOG_AUTHPRIV);

    // Best-effort echo to TTY so the user sees we're alive even if config
    // load fails.  Two-line banner so the operator knows what input the
    // tool wants (vs. the prior sshd password prompt, which is a stub —
    // pam_succeed_if short-circuits it and the operator can type anything
    // there).
    std::cerr << "\nXCESP TACACS+ authentication\n";
    std::cerr << "Enter your TACACS+ credentials below.\n";

    Config cfg;
    std::string err;
    if (!readConfig("/etc/xcesp/tacacs.conf", cfg, err)) {
        std::cerr << "configuration error: " << err << "\n";
        syslog(LOG_ERR, "config error: %s", err.c_str());
        return 1;
    }

    std::cerr << "Username: " << std::flush;
    std::string user;
    if (!std::getline(std::cin, user) || user.empty()) {
        std::cerr << "no username\n"; return 1;
    }
    std::string pass = readPasswordSilent("Password: ");

    // Pseudo-TTY identifier (TACACS server logs it; not used for auth).
    char ttyName[64] = "ssh";
    if (isatty(STDIN_FILENO)) {
        const char* tt = ttyname(STDIN_FILENO);
        if (tt && *tt) {
            const char* base = std::strrchr(tt, '/');
            std::strncpy(ttyName, base ? base + 1 : tt, sizeof(ttyName) - 1);
            ttyName[sizeof(ttyName) - 1] = '\0';
        }
    }
    std::string remAddr = "127.0.0.1";   // best-effort — sshd doesn't expose source IP here
    if (const char* sc = std::getenv("SSH_CLIENT")) {
        std::string s(sc);
        auto sp = s.find(' ');
        if (sp != std::string::npos) remAddr = s.substr(0, sp);
        else                          remAddr = s;
    }

    // Try each configured server in order; TCP failure → next server,
    // PASS/FAIL from server → authoritative (no failover).
    for (const auto& srv : cfg.servers) {
        int fd = connectTcp(srv.host, srv.port, cfg.timeoutS, err);
        if (fd < 0) {
            syslog(LOG_WARNING, "tacacs server %s:%d unreachable: %s",
                   srv.host.c_str(), srv.port, err.c_str());
            continue;
        }
        // version: major=12, minor=0 (TAC_PLUS_MINOR_VER_DEFAULT) — per
        // RFC 8907 §5.4.2, ASCII auth MUST use minor=0.  minor=1 is for
        // CHAP / MS-CHAP / PAP only.  Shrubbery's tac_plus rejects the
        // wrong minor version with `Illegal packet ver=193 action=1 type=1`
        // followed by `choose_authen: unacceptable authen method`.
        TacacsClient cli(fd, cfg.secret, (TAC_PLUS_MAJOR_VER << 4) | TAC_PLUS_MINOR_VER_DEFAULT);

        if (!tacacsAuthenticate(cli, user, pass, ttyName, remAddr, err)) {
            std::cerr << "Authentication failed.\n";
            syslog(LOG_NOTICE, "auth-fail user=%s server=%s reason=\"%s\"",
                   user.c_str(), srv.host.c_str(), err.c_str());
            return 1;
        }
        int privLvl = tacacsAuthorize(cli, user, ttyName, remAddr, err);
        if (privLvl < 0) {
            std::cerr << "Authorization failed.\n";
            syslog(LOG_NOTICE, "author-fail user=%s server=%s reason=\"%s\"",
                   user.c_str(), srv.host.c_str(), err.c_str());
            return 1;
        }
        int role = mapPrivLvl(cfg.privLvlMap, privLvl, 4);

        syslog(LOG_NOTICE, "auth-ok user=%s server=%s priv-lvl=%d role=%d",
               user.c_str(), srv.host.c_str(), privLvl, role);

        // Hand off to xcesp-login (which assembles the final xcespcli call).
        setenv("XCESP_AUDIT_USER",     user.c_str(),               1);
        setenv("XCESP_ROLE_OVERRIDE",  std::to_string(role).c_str(), 1);
        execl("/usr/lib/xcesp/xcesp-login", "xcesp-login", static_cast<char*>(nullptr));
        // exec failed
        std::cerr << "exec /usr/lib/xcesp/xcesp-login failed: "
                  << std::strerror(errno) << "\n";
        syslog(LOG_ERR, "exec xcesp-login failed: %s", std::strerror(errno));
        return 1;
    }

    std::cerr << "All TACACS+ servers unreachable.\n";
    syslog(LOG_NOTICE, "auth-unreachable user=%s", user.c_str());
    return 1;
}
