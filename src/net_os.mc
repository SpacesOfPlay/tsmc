// net_os.mc — non-blocking TCP sockets, readiness polling, and DNS.
//
// Sits below the builtins/VM layers (like os_time.mc) so both the event
// loop reactor and the `net` module can use it. Windows-first (Winsock);
// other targets get stubs that report failure until ported.
//
// Return conventions for I/O:
//   recv/send: >=0 bytes moved, 0 clean EOF (recv only),
//              NET_WOULDBLOCK (-1) if it would block, NET_ERR (-2) on error.
//   accept:    >=0 new fd, NET_WOULDBLOCK (-1) if none pending, NET_ERR (-2).
// A socket fd of -1 is the invalid sentinel on every path.

// `struct sockaddr_in` — 16 bytes, network byte order (see net_htons).
struct NetSockAddrIn {
    u16 family;
    u16 port;
    u32 addr;
    u8[8] zero;
}

// WSAPOLLFD / struct pollfd — the readiness descriptor handed to poll.
struct NetPollFd {
    i64 fd;
    i16 events;
    i16 revents;
}

// Windows ADDRINFOA (x64 layout) for getaddrinfo.
struct NetAddrInfo {
    i32 ai_flags;
    i32 ai_family;
    i32 ai_socktype;
    i32 ai_protocol;
    u64 ai_addrlen;
    u8* ai_canonname;
    void* ai_addr;
    void* ai_next;
}

const i32 NET_AF_INET = 2;
const i32 NET_SOCK_STREAM = 1;

// poll event/result bits (Winsock values; standard elsewhere)
const i16 NET_POLLIN  = 0x0100;   // POLLRDNORM — readable
const i16 NET_POLLOUT = 0x0010;   // POLLWRNORM — writable
const i16 NET_POLLERR = 0x0001;   // POLLERR
const i16 NET_POLLHUP = 0x0002;   // POLLHUP

const i32 NET_WOULDBLOCK = -1;
const i32 NET_ERR = -2;

// 127.0.0.1 in network byte order.
const u32 NET_LOOPBACK_BE = 0x0100007F;

// Host → network order, 16-bit.
u16 net_htons(u16 host) {
    return cast(u16, ((host & 0xFF) << 8) | ((host >> 8) & 0xFF));
}

when os(windows) {
    const i32 _FIONBIO = 0x8004667E;
    const i32 _SOL_SOCKET = 0xFFFF;
    const i32 _SO_ERROR = 0x1007;
    const i32 _SO_REUSEADDR = 4;
    const i32 _WSAEWOULDBLOCK = 10035;

    extern "ws2_32.dll" {
        i32 WSAStartup(u16 ver, void* data);
        i32 WSACleanup();
        i64 socket(i32 af, i32 type, i32 proto);
        i32 closesocket(i64 s);
        i32 ioctlsocket(i64 s, i32 cmd, u32* argp);
        i32 bind(i64 s, void* name, i32 namelen);
        i32 listen(i64 s, i32 backlog);
        i64 accept(i64 s, void* addr, i32* addrlen);
        i32 connect(i64 s, void* name, i32 namelen);
        i32 recv(i64 s, u8* buf, i32 len, i32 flags);
        i32 send(i64 s, u8* buf, i32 len, i32 flags);
        i32 getsockopt(i64 s, i32 level, i32 opt, void* val, i32* len);
        i32 setsockopt(i64 s, i32 level, i32 opt, void* val, i32 len);
        i32 getsockname(i64 s, void* name, i32* namelen);
        i32 WSAPoll(void* fds, u32 nfds, i32 timeout);
        i32 WSAGetLastError();
        i32 getaddrinfo(u8* node, u8* service, void* hints, void** res);
        void freeaddrinfo(void* res);
    }

    bool net_os_init() {
        u8[408] data;   // WSADATA (Winsock 2.2)
        return WSAStartup(0x0202, &data[0]) == 0;
    }

    void net_os_cleanup() { WSACleanup(); }

    private void _set_nonblocking(i64 fd) {
        u32 one = 1;
        ignore ioctlsocket(fd, _FIONBIO, &one);
    }

    private void _fill_addr(NetSockAddrIn* a, u32 ip_be, u16 port) {
        a.family = cast(u16, NET_AF_INET);
        a.port = net_htons(port);
        a.addr = ip_be;
        for i32 i = 0; i < 8; i++ { a.zero[i] = 0; }
    }

    // A fresh non-blocking TCP socket, or -1.
    i64 net_os_socket() {
        i64 fd = socket(NET_AF_INET, NET_SOCK_STREAM, 0);
        if fd == -1 { return -1; }
        _set_nonblocking(fd);
        return fd;
    }

    // Bind + listen on bind_be:port (non-blocking). Returns fd or -1.
    i64 net_os_listen4(u32 bind_be, u16 port) {
        i64 fd = socket(NET_AF_INET, NET_SOCK_STREAM, 0);
        if fd == -1 { return -1; }
        i32 opt = 1;
        ignore setsockopt(fd, _SOL_SOCKET, _SO_REUSEADDR, &opt, 4);
        NetSockAddrIn a;
        _fill_addr(&a, bind_be, port);
        if bind(fd, &a, 16) != 0 { closesocket(fd); return -1; }
        if listen(fd, 128) != 0 { closesocket(fd); return -1; }
        _set_nonblocking(fd);
        return fd;
    }

    // Local port a socket is bound to (host order), or 0.
    u16 net_os_port(i64 fd) {
        NetSockAddrIn a;
        i32 len = 16;
        if getsockname(fd, &a, &len) != 0 { return 0; }
        return net_htons(a.port);
    }

    // Accept a pending connection: >=0 fd, NET_WOULDBLOCK, or NET_ERR.
    i64 net_os_accept(i64 lfd) {
        NetSockAddrIn a;
        i32 len = 16;
        i64 c = accept(lfd, &a, &len);
        if c == -1 {
            if WSAGetLastError() == _WSAEWOULDBLOCK { return NET_WOULDBLOCK; }
            return NET_ERR;
        }
        _set_nonblocking(c);
        return c;
    }

    // Start a non-blocking connect. Returns the fd (connection in progress
    // or already complete), or -1 on immediate failure. Poll for writable,
    // then confirm with net_os_connect_result.
    i64 net_os_connect_start(u32 ip_be, u16 port) {
        i64 fd = net_os_socket();
        if fd == -1 { return -1; }
        NetSockAddrIn a;
        _fill_addr(&a, ip_be, port);
        if connect(fd, &a, 16) == 0 { return fd; }         // rare: instant
        if WSAGetLastError() == _WSAEWOULDBLOCK { return fd; }
        closesocket(fd);
        return -1;
    }

    // 0 = connected, >0 = connect error code, still checks via SO_ERROR.
    i32 net_os_connect_result(i64 fd) {
        i32 err = 0;
        i32 len = 4;
        if getsockopt(fd, _SOL_SOCKET, _SO_ERROR, &err, &len) != 0 { return NET_ERR; }
        return err;
    }

    i32 net_os_recv(i64 fd, u8* buf, i32 len) {
        i32 n = recv(fd, buf, len, 0);
        if n >= 0 { return n; }
        if WSAGetLastError() == _WSAEWOULDBLOCK { return NET_WOULDBLOCK; }
        return NET_ERR;
    }

    i32 net_os_send(i64 fd, u8* buf, i32 len) {
        i32 n = send(fd, buf, len, 0);
        if n >= 0 { return n; }
        if WSAGetLastError() == _WSAEWOULDBLOCK { return NET_WOULDBLOCK; }
        return NET_ERR;
    }

    void net_os_close(i64 fd) { ignore closesocket(fd); }

    i32 net_os_poll(NetPollFd* fds, i32 n, i32 timeout_ms) {
        return WSAPoll(cast(void*, fds), cast(u32, n), timeout_ms);
    }

    // Resolve a hostname to its first IPv4 address (network-order u32),
    // or 0 on failure. A dotted-quad string resolves without a lookup.
    u32 net_os_resolve4(u8* host) {
        void* res = null;
        if getaddrinfo(host, null, null, &res) != 0 { return 0; }
        u32 out = 0;
        void* cur = res;
        while cur != null {
            NetAddrInfo* ai = cast(NetAddrInfo*, cur);
            if ai.ai_family == NET_AF_INET && ai.ai_addr != null {
                NetSockAddrIn* sa = cast(NetSockAddrIn*, ai.ai_addr);
                out = sa.addr;
                break;
            }
            cur = ai.ai_next;
        }
        freeaddrinfo(res);
        return out;
    }
}
else {
    // Non-Windows: not yet ported. Everything reports failure so builds
    // stay green; the `net` module surfaces this as an unsupported error.
    bool net_os_init() { return false; }
    void net_os_cleanup() { }
    i64 net_os_socket() { return -1; }
    i64 net_os_listen4(u32 bind_be, u16 port) { return -1; }
    u16 net_os_port(i64 fd) { return cast(u16, 0); }
    i64 net_os_accept(i64 lfd) { return NET_ERR; }
    i64 net_os_connect_start(u32 ip_be, u16 port) { return -1; }
    i32 net_os_connect_result(i64 fd) { return NET_ERR; }
    i32 net_os_recv(i64 fd, u8* buf, i32 len) { return NET_ERR; }
    i32 net_os_send(i64 fd, u8* buf, i32 len) { return NET_ERR; }
    void net_os_close(i64 fd) { }
    i32 net_os_poll(NetPollFd* fds, i32 n, i32 timeout_ms) { return -1; }
    u32 net_os_resolve4(u8* host) { return 0; }
}
