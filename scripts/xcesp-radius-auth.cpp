/**
 * @file    xcesp-radius-auth.cpp
 * @brief   RADIUS authentication tool — RFC 2865 Access-Request/Accept client
 * @project XCESP (xcesppkg 0.2.16+)
 *
 * Run as the login shell for the xcesp-radius pool ssh account.  Prompts
 * the operator for their real RADIUS username + password on the tty, sends
 * a single Access-Request UDP packet to the first reachable configured
 * server, validates the Response-Authenticator, extracts the Service-Type
 * attribute from the Access-Accept reply, maps it to one of the four
 * XCESP CliRoles (1=ALL, 2=NO_USER_ACCESS, 3=NO_CONFIG, 4=SHOW_ONLY) via
 * the configured service-type-map, and execs /usr/lib/xcesp/xcesp-login
 * with XCESP_AUDIT_USER and XCESP_ROLE_OVERRIDE set in env.
 *
 * Implements RFC 2865 wire format directly (no libfreeradius-client
 * dependency — see /home/asier/.claude/projects/-home-asier-xsrc/memory/
 * project_tacacs_minor_version.md and project_rfc_constants_audit.md for
 * the rationale: distro-package availability on Fedora 41 was the
 * blocker, and the simpler wire format makes a direct implementation a
 * smaller bug surface than a library we don't control).  Only external
 * dependency is libcrypto for MD5.
 */

#include <openssl/evp.h>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
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
// RADIUS wire constants (RFC 2865)
// ---------------------------------------------------------------------------
//
// Audited verbatim against the RFC text on first compile per the
// rfc-constants-audit memory.  The lesson from TACACS 0.2.13 and 0.2.14
// is: never copy from another implementation, never type from memory,
// always cross-check every numeric value against the spec table.
//
// §3 — Packet codes:
constexpr uint8_t RADIUS_CODE_ACCESS_REQUEST   = 1;
constexpr uint8_t RADIUS_CODE_ACCESS_ACCEPT    = 2;
constexpr uint8_t RADIUS_CODE_ACCESS_REJECT    = 3;
constexpr uint8_t RADIUS_CODE_ACCESS_CHALLENGE = 11;

// §5 — Attribute types (only the ones we send / parse):
constexpr uint8_t RADIUS_ATTR_USER_NAME      = 1;
constexpr uint8_t RADIUS_ATTR_USER_PASSWORD  = 2;
constexpr uint8_t RADIUS_ATTR_NAS_IP_ADDRESS = 4;
constexpr uint8_t RADIUS_ATTR_NAS_PORT       = 5;
constexpr uint8_t RADIUS_ATTR_SERVICE_TYPE   = 6;
constexpr uint8_t RADIUS_ATTR_REPLY_MESSAGE  = 18;
constexpr uint8_t RADIUS_ATTR_NAS_IDENTIFIER = 32;

// §5.6 — Service-Type values (used as the canonical role-mapping key):
//   1  Login-User           → role 3 (NO_CONFIG) in the built-in default
//   2  Framed-User
//   6  Administrative-User  → role 1 (ALL)
//   7  NAS-Prompt-User      → role 2 (NO_USER_ACCESS)
//   8  Authenticate-Only
// Anything unmapped → role 4 (SHOW_ONLY).

// Header is fixed 20 bytes: code(1) + id(1) + length(2) + authenticator(16).
constexpr size_t RADIUS_HEADER_LEN = 20;

// §3 — Length field MUST be between 20 and 4096.
constexpr size_t RADIUS_MAX_LEN = 4096;

// §3 — User-Password chunks are 16 bytes; password is zero-padded.
constexpr size_t RADIUS_PW_CHUNK = 16;

// ---------------------------------------------------------------------------
// Helpers (mirrored from xcesp-tacacs-auth.cpp)
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

// 16 cryptographically random bytes for the Request-Authenticator.
// RFC 2865 §3: "The NAS and RADIUS server share a secret. That shared
// secret followed by the Request Authenticator is put through a one-way
// MD5 hash to create a 16 octet digest value... The Request Authenticator
// MUST be unique and unpredictable for replay protection."
bool randomAuthenticator(uint8_t out[16]) {
    int fd = ::open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;
    size_t got = 0;
    while (got < 16) {
        ssize_t n = ::read(fd, out + got, 16 - got);
        if (n <= 0) { ::close(fd); return false; }
        got += static_cast<size_t>(n);
    }
    ::close(fd);
    return true;
}

uint8_t makeIdentifier() {
    std::random_device rd;
    return static_cast<uint8_t>(rd() & 0xFF);
}

// MD5 via the EVP interface (OpenSSL 3.x friendly, not the deprecated
// legacy MD5_Init/Update/Final).  Same pattern as xcesp-tacacs-auth.
struct Md5 {
    EVP_MD_CTX* ctx;
    Md5() : ctx(EVP_MD_CTX_new()) {
        EVP_DigestInit_ex(ctx, EVP_md5(), nullptr);
    }
    ~Md5() { EVP_MD_CTX_free(ctx); }
    void update(const void* p, size_t n) { EVP_DigestUpdate(ctx, p, n); }
    void update(const std::string& s) { update(s.data(), s.size()); }
    void update(const std::vector<uint8_t>& v) { update(v.data(), v.size()); }
    void finish(uint8_t out[16]) {
        unsigned int n = 16;
        EVP_DigestFinal_ex(ctx, out, &n);
    }
};

// ---------------------------------------------------------------------------
// Config parser — /etc/xcesp/radius.conf
// ---------------------------------------------------------------------------

struct Server {
    std::string host;
    int         port = 1812;
};

struct Config {
    std::vector<Server> servers;
    std::string         secret;
    int                 timeoutS       = 3;   // UDP timeout per attempt
    int                 retransmits    = 2;   // additional attempts per server
    std::string         serviceTypeMap;       // e.g. "6:1 7:2 1:3"
    std::string         nasIdentifier;        // optional; sent if non-empty
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
                s.port = 1812;
            } else {
                s.host = val.substr(0, colon);
                s.port = std::atoi(val.substr(colon + 1).c_str());
                if (s.port <= 0) s.port = 1812;
            }
            cfg.servers.push_back(s);
        } else if (key == "key" || key == "secret") {
            cfg.secret = val;
        } else if (key == "timeout") {
            cfg.timeoutS = std::atoi(val.c_str());
            if (cfg.timeoutS < 1) cfg.timeoutS = 3;
        } else if (key == "retransmits") {
            cfg.retransmits = std::atoi(val.c_str());
            if (cfg.retransmits < 0) cfg.retransmits = 2;
        } else if (key == "service-type-map") {
            cfg.serviceTypeMap = val;
        } else if (key == "nas-identifier") {
            cfg.nasIdentifier = val;
        }
        // unknown keys silently ignored — forward-compatible
    }
    if (cfg.servers.empty()) { err = "no servers configured"; return false; }
    if (cfg.secret.empty())  { err = "shared secret missing"; return false; }
    return true;
}

// service-type-map: whitespace-separated "<svc-type>:<role>" pairs (exact
// match, not threshold like the TACACS priv-lvl map — Service-Type is a
// closed enum, not a privilege ordering).  Default when empty: 6→1, 7→2,
// 1→3, anything else → defaultRole.
int mapServiceType(const std::string& mapStr, int svcType, int defaultRole = 4) {
    auto pairs = splitWs(mapStr);
    if (pairs.empty()) {
        // Built-in defaults — see §5.6 Service-Type values.
        switch (svcType) {
            case 6: return 1;   // Administrative-User
            case 7: return 2;   // NAS-Prompt-User
            case 1: return 3;   // Login-User
            default: return defaultRole;
        }
    }
    for (const auto& p : pairs) {
        auto colon = p.find(':');
        if (colon == std::string::npos) continue;
        int t = std::atoi(p.substr(0, colon).c_str());
        int r = std::atoi(p.substr(colon + 1).c_str());
        if (r < 1 || r > 4) continue;
        if (t == svcType) return r;
    }
    return defaultRole;
}

// ---------------------------------------------------------------------------
// Attribute packing helpers
// ---------------------------------------------------------------------------

void pushAttr(std::vector<uint8_t>& attrs, uint8_t type,
              const uint8_t* value, size_t valueLen)
{
    // RFC 2865 §5: attribute length is the total of type(1) + length(1) +
    // value, capped at 255.  Caller ensures value sizes are valid for the
    // attributes they send.
    attrs.push_back(type);
    attrs.push_back(static_cast<uint8_t>(2 + valueLen));
    attrs.insert(attrs.end(), value, value + valueLen);
}

void pushAttrString(std::vector<uint8_t>& attrs, uint8_t type,
                    const std::string& s)
{
    pushAttr(attrs, type,
             reinterpret_cast<const uint8_t*>(s.data()), s.size());
}

void pushAttrU32(std::vector<uint8_t>& attrs, uint8_t type, uint32_t v) {
    uint32_t be = htonl(v);
    pushAttr(attrs, type, reinterpret_cast<const uint8_t*>(&be), 4);
}

// User-Password encryption (RFC 2865 §5.2):
//   p = password, zero-padded up to a multiple of 16 bytes.
//   b1 = MD5(secret || Request-Authenticator)
//   c1 = p1 XOR b1
//   for i > 1:
//     bi = MD5(secret || c_{i-1})
//     ci = pi XOR bi
//   Send c1 c2 ... cn.
std::vector<uint8_t> encryptUserPassword(const std::string& password,
                                          const std::string& secret,
                                          const uint8_t requestAuth[16])
{
    // Pad up to 16-byte boundary with zero bytes.  Empty password → one
    // chunk of 16 zeros (still gets encrypted; server compares).
    size_t padLen = ((password.size() + RADIUS_PW_CHUNK - 1) / RADIUS_PW_CHUNK) * RADIUS_PW_CHUNK;
    if (padLen == 0) padLen = RADIUS_PW_CHUNK;
    std::vector<uint8_t> plain(padLen, 0);
    std::memcpy(plain.data(), password.data(), password.size());

    std::vector<uint8_t> cipher(padLen, 0);
    uint8_t prev[16];
    std::memcpy(prev, requestAuth, 16);

    for (size_t off = 0; off < padLen; off += RADIUS_PW_CHUNK) {
        // b_i = MD5(secret || (RA or c_{i-1}))
        uint8_t b[16];
        {
            Md5 m;
            m.update(secret);
            m.update(prev, 16);
            m.finish(b);
        }
        for (size_t i = 0; i < RADIUS_PW_CHUNK; ++i)
            cipher[off + i] = plain[off + i] ^ b[i];
        std::memcpy(prev, cipher.data() + off, 16);
    }
    return cipher;
}

// ---------------------------------------------------------------------------
// Packet builder — Access-Request
// ---------------------------------------------------------------------------

struct AccessRequest {
    uint8_t              id;
    uint8_t              authenticator[16];
    std::vector<uint8_t> wire;      // ready to send
};

bool buildAccessRequest(const Config& cfg, const std::string& user,
                         const std::string& password,
                         const std::string& nasIp,
                         AccessRequest& req, std::string& err)
{
    if (!randomAuthenticator(req.authenticator)) {
        err = "cannot read /dev/urandom"; return false;
    }
    req.id = makeIdentifier();

    // Build attribute list.
    std::vector<uint8_t> attrs;
    pushAttrString(attrs, RADIUS_ATTR_USER_NAME, user);

    auto encPw = encryptUserPassword(password, cfg.secret, req.authenticator);
    pushAttr(attrs, RADIUS_ATTR_USER_PASSWORD, encPw.data(), encPw.size());

    if (!nasIp.empty()) {
        in_addr a{};
        if (inet_pton(AF_INET, nasIp.c_str(), &a) == 1) {
            pushAttr(attrs, RADIUS_ATTR_NAS_IP_ADDRESS,
                     reinterpret_cast<const uint8_t*>(&a.s_addr), 4);
        }
    }
    if (!cfg.nasIdentifier.empty()) {
        pushAttrString(attrs, RADIUS_ATTR_NAS_IDENTIFIER, cfg.nasIdentifier);
    }
    // Service-Type hint: Authenticate-Only (8) — we are doing pure auth,
    // not a framed/login session at the NAS level.  RFC 2865 §5.6 lets
    // the server override in the reply.
    pushAttrU32(attrs, RADIUS_ATTR_SERVICE_TYPE, 8);

    size_t totalLen = RADIUS_HEADER_LEN + attrs.size();
    if (totalLen > RADIUS_MAX_LEN) { err = "request too large"; return false; }

    req.wire.clear();
    req.wire.reserve(totalLen);
    req.wire.push_back(RADIUS_CODE_ACCESS_REQUEST);
    req.wire.push_back(req.id);
    uint16_t lenBe = htons(static_cast<uint16_t>(totalLen));
    req.wire.push_back(static_cast<uint8_t>(lenBe & 0xFF));
    req.wire.push_back(static_cast<uint8_t>((lenBe >> 8) & 0xFF));
    req.wire.insert(req.wire.end(), req.authenticator, req.authenticator + 16);
    req.wire.insert(req.wire.end(), attrs.begin(), attrs.end());
    return true;
}

// ---------------------------------------------------------------------------
// Packet parser — Access-Accept / Reject / Challenge
// ---------------------------------------------------------------------------

struct ReplyAttr {
    uint8_t              type;
    std::vector<uint8_t> value;
};

struct AccessReply {
    uint8_t                code;
    uint8_t                id;
    uint8_t                authenticator[16];
    std::vector<ReplyAttr> attrs;
};

// Validate Response-Authenticator (RFC 2865 §3):
//   ResponseAuth = MD5(Code | ID | Length | RequestAuth | Attributes | Secret)
// If mismatch, discard the packet — treat as if no reply (caller retries).
bool validateResponse(const std::vector<uint8_t>& pkt,
                       const uint8_t requestAuth[16],
                       const std::string& secret)
{
    if (pkt.size() < RADIUS_HEADER_LEN) return false;
    // Substitute the request authenticator into the bytes we'll hash:
    // the response-authenticator field (offsets 4..19) is replaced with
    // the request-authenticator before the MD5 input is built.
    std::vector<uint8_t> hashIn(pkt.begin(), pkt.end());
    std::memcpy(&hashIn[4], requestAuth, 16);

    uint8_t expected[16];
    {
        Md5 m;
        m.update(hashIn.data(), hashIn.size());
        m.update(secret);
        m.finish(expected);
    }
    // Constant-time compare to avoid timing leaks on a per-byte equality.
    uint8_t diff = 0;
    for (size_t i = 0; i < 16; ++i) diff |= expected[i] ^ pkt[4 + i];
    return diff == 0;
}

bool parseAccessReply(const std::vector<uint8_t>& pkt, AccessReply& r,
                      std::string& err)
{
    if (pkt.size() < RADIUS_HEADER_LEN) {
        err = "reply truncated"; return false;
    }
    r.code = pkt[0];
    r.id   = pkt[1];
    uint16_t len = (static_cast<uint16_t>(pkt[2]) |
                    (static_cast<uint16_t>(pkt[3]) << 8));
    len = ntohs(len);
    if (len < RADIUS_HEADER_LEN || len > pkt.size()) {
        err = "reply length field invalid"; return false;
    }
    std::memcpy(r.authenticator, &pkt[4], 16);
    size_t off = RADIUS_HEADER_LEN;
    while (off < len) {
        if (off + 2 > len) { err = "attribute truncated"; return false; }
        uint8_t t = pkt[off];
        uint8_t l = pkt[off + 1];
        if (l < 2 || off + l > len) {
            err = "attribute length invalid"; return false;
        }
        ReplyAttr a;
        a.type = t;
        a.value.assign(pkt.begin() + off + 2, pkt.begin() + off + l);
        r.attrs.push_back(std::move(a));
        off += l;
    }
    return true;
}

// Find Service-Type AVP — 4-byte big-endian uint32.  Returns -1 if absent.
int extractServiceType(const AccessReply& r) {
    for (const auto& a : r.attrs) {
        if (a.type != RADIUS_ATTR_SERVICE_TYPE) continue;
        if (a.value.size() != 4) continue;
        uint32_t be;
        std::memcpy(&be, a.value.data(), 4);
        return static_cast<int>(ntohl(be));
    }
    return -1;
}

// Concatenate any Reply-Message AVPs (printable text the server wants the
// user to see — typically a reason for a Reject).
std::string extractReplyMessage(const AccessReply& r) {
    std::string out;
    for (const auto& a : r.attrs) {
        if (a.type != RADIUS_ATTR_REPLY_MESSAGE) continue;
        if (!out.empty()) out += " ";
        out.append(reinterpret_cast<const char*>(a.value.data()), a.value.size());
    }
    return out;
}

// ---------------------------------------------------------------------------
// UDP send/receive with timeout + retransmit
// ---------------------------------------------------------------------------

// Open UDP socket connected to host:port.  Caller closes fd.  Returns
// the local IPv4 we ended up bound to (for the NAS-IP-Address attr in
// the next request — we build the request *after* connect so this works).
int connectUdp(const std::string& host, int port, std::string& localIp,
                std::string& err)
{
    struct addrinfo hints{}, *res = nullptr;
    hints.ai_family   = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    int gai = ::getaddrinfo(host.c_str(), std::to_string(port).c_str(),
                             &hints, &res);
    if (gai != 0) { err = std::string("getaddrinfo: ") + gai_strerror(gai); return -1; }
    int fd = -1;
    for (auto* ai = res; ai != nullptr; ai = ai->ai_next) {
        fd = ::socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        if (::connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) {
            // Pick up the local address kernel chose.
            sockaddr_storage ss{};
            socklen_t sl = sizeof(ss);
            if (::getsockname(fd, reinterpret_cast<sockaddr*>(&ss), &sl) == 0) {
                char buf[INET6_ADDRSTRLEN] = {0};
                if (ss.ss_family == AF_INET) {
                    auto* sin = reinterpret_cast<sockaddr_in*>(&ss);
                    inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf));
                    localIp = buf;
                }
            }
            break;
        }
        ::close(fd);
        fd = -1;
    }
    ::freeaddrinfo(res);
    if (fd < 0) err = std::string("connect: ") + std::strerror(errno);
    return fd;
}

bool sendUdp(int fd, const std::vector<uint8_t>& pkt) {
    ssize_t n = ::send(fd, pkt.data(), pkt.size(), 0);
    return n == static_cast<ssize_t>(pkt.size());
}

// Receive one datagram with a timeout.  Returns:
//   1  packet received (in out)
//   0  timeout
//  -1  socket error
int recvUdpTimeout(int fd, int timeoutSec, std::vector<uint8_t>& out) {
    struct pollfd pfd{};
    pfd.fd = fd;
    pfd.events = POLLIN;
    int rc = ::poll(&pfd, 1, timeoutSec * 1000);
    if (rc < 0) return -1;
    if (rc == 0) return 0;
    if ((pfd.revents & POLLIN) == 0) return -1;
    out.resize(RADIUS_MAX_LEN);
    ssize_t n = ::recv(fd, out.data(), out.size(), 0);
    if (n <= 0) return -1;
    out.resize(static_cast<size_t>(n));
    return 1;
}

// ---------------------------------------------------------------------------
// One full RADIUS exchange against one server.
// ---------------------------------------------------------------------------
//
// Returns:
//    > 0   priv-role index (1..4) — caller does map and exec.  reply.code
//          was Access-Accept and Response-Authenticator validated.
//    == 0  server replied REJECT or CHALLENGE — authoritative failure, no
//          failover.  errStr populated.
//    < 0   server unreachable or replied with an undecodable packet —
//          caller may try the next configured server.
//
int radiusOneShot(int fd, const Config& cfg,
                   const AccessRequest& req,
                   AccessReply& reply, std::string& errStr,
                   int& outServiceType, bool& authoritativeFailure)
{
    authoritativeFailure = false;
    int attemptsLeft = cfg.retransmits + 1;
    while (attemptsLeft-- > 0) {
        if (!sendUdp(fd, req.wire)) {
            errStr = std::string("send: ") + std::strerror(errno);
            return -1;
        }
        std::vector<uint8_t> pkt;
        int rc = recvUdpTimeout(fd, cfg.timeoutS, pkt);
        if (rc < 0) { errStr = "recv error"; return -1; }
        if (rc == 0) {
            errStr = "timeout";
            continue;   // retransmit
        }
        // Validate Response-Authenticator before parsing — a packet that
        // doesn't validate is treated as forged/replayed and discarded.
        if (!validateResponse(pkt, req.authenticator, cfg.secret)) {
            errStr = "response-authenticator mismatch (discarded)";
            // Spec recommends silent drop and continue waiting.  We treat
            // this as a retransmit trigger so a single bad packet does not
            // kill the exchange.
            continue;
        }
        if (!parseAccessReply(pkt, reply, errStr)) return -1;
        if (reply.id != req.id) {
            errStr = "reply id does not match request";
            continue;
        }
        if (reply.code == RADIUS_CODE_ACCESS_ACCEPT) {
            outServiceType = extractServiceType(reply);
            return 1;
        }
        if (reply.code == RADIUS_CODE_ACCESS_REJECT) {
            std::string msg = extractReplyMessage(reply);
            errStr = msg.empty() ? "Access-Reject" : ("Access-Reject: " + msg);
            authoritativeFailure = true;
            return 0;
        }
        if (reply.code == RADIUS_CODE_ACCESS_CHALLENGE) {
            // RFC 2865 §4.4 challenge/response (typically OTP / MFA).  Not
            // supported in 0.2.16 — treat as authentication failure with
            // a distinctive message so the operator knows why.
            errStr = "Access-Challenge (MFA/OTP) not supported by this client";
            authoritativeFailure = true;
            return 0;
        }
        errStr = std::string("unexpected code ") + std::to_string(reply.code);
        return -1;
    }
    return -1;
}

} // namespace

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main(int /*argc*/, char* /*argv*/[]) {
    openlog("xcesp-radius-auth", LOG_PID, LOG_AUTHPRIV);

    // Two-line banner mirrors xcesp-tacacs-auth for operator familiarity.
    std::cerr << "\nXCESP RADIUS authentication\n";
    std::cerr << "Enter your RADIUS credentials below.\n";

    Config cfg;
    std::string err;
    if (!readConfig("/etc/xcesp/radius.conf", cfg, err)) {
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

    // remAddr is best-effort — used as NAS-IP-Address only if we cannot
    // get the local socket address from getsockname after connect.  The
    // RADIUS server typically logs it for accounting purposes.
    std::string remAddr;
    if (const char* sc = std::getenv("SSH_CLIENT")) {
        std::string s(sc);
        auto sp = s.find(' ');
        remAddr = (sp != std::string::npos) ? s.substr(0, sp) : s;
        (void)remAddr;  // not currently used (kept for future NAS-Identifier work)
    }

    // Try each configured server in order.  UDP timeout + retransmits →
    // next server.  Access-Reject / Access-Challenge → authoritative.
    for (const auto& srv : cfg.servers) {
        std::string localIp;
        int fd = connectUdp(srv.host, srv.port, localIp, err);
        if (fd < 0) {
            syslog(LOG_WARNING, "radius server %s:%d unreachable: %s",
                   srv.host.c_str(), srv.port, err.c_str());
            continue;
        }

        AccessRequest req;
        if (!buildAccessRequest(cfg, user, pass, localIp, req, err)) {
            ::close(fd);
            std::cerr << "request build failed: " << err << "\n";
            syslog(LOG_ERR, "request build: %s", err.c_str());
            return 1;
        }

        AccessReply reply;
        int  svcType = -1;
        bool authoritative = false;
        int rc = radiusOneShot(fd, cfg, req, reply, err, svcType, authoritative);
        ::close(fd);

        if (rc > 0) {
            int role = mapServiceType(cfg.serviceTypeMap, svcType, 4);
            syslog(LOG_NOTICE, "auth-ok user=%s server=%s service-type=%d role=%d",
                   user.c_str(), srv.host.c_str(), svcType, role);

            // Hand off to xcesp-login (assembles the final xcespcli call).
            setenv("XCESP_AUDIT_USER",    user.c_str(),                  1);
            setenv("XCESP_ROLE_OVERRIDE", std::to_string(role).c_str(),  1);
            execl("/usr/lib/xcesp/xcesp-login", "xcesp-login",
                  static_cast<char*>(nullptr));
            // exec failed
            std::cerr << "exec /usr/lib/xcesp/xcesp-login failed: "
                      << std::strerror(errno) << "\n";
            syslog(LOG_ERR, "exec xcesp-login failed: %s", std::strerror(errno));
            return 1;
        }
        if (rc == 0) {
            // Authoritative failure — do not try other servers.
            std::cerr << "Authentication failed.\n";
            syslog(LOG_NOTICE, "auth-fail user=%s server=%s reason=\"%s\"",
                   user.c_str(), srv.host.c_str(), err.c_str());
            return 1;
        }
        // rc < 0: server unreachable / undecodable — try next.
        syslog(LOG_WARNING, "auth-retry user=%s server=%s reason=\"%s\"",
               user.c_str(), srv.host.c_str(), err.c_str());
    }

    std::cerr << "All RADIUS servers unreachable.\n";
    syslog(LOG_NOTICE, "auth-unreachable user=%s", user.c_str());
    return 1;
}
