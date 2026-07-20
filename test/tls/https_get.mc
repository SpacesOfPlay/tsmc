// Manual (network-dependent) driver: non-blocking HTTPS GET to a real
// server through the TLS session pump. Prints the response status line.
// Run: build with minc against src/tls_native.mc; not part of the gated
// suite. Host via arg is not wired; edit HOST below.

import "../../src/tls_native.mc";
import "../../src/net_os.mc";

private i32 hexval(u8 c) {
    if c >= cast(u8, 48) && c <= cast(u8, 57) { return cast(i32, c) - 48; }
    if c >= cast(u8, 97) && c <= cast(u8, 102) { return cast(i32, c) - 97 + 10; }
    if c >= cast(u8, 65) && c <= cast(u8, 70) { return cast(i32, c) - 65 + 10; }
    return 0;
}

i32 main() {
    u8* host = cast(u8*, "example.com");
    if !net_os_init() { print("WSA init failed\n"); return 1; }
    u32 ip = net_os_resolve4(host);
    if ip == 0 { print("DNS failed\n"); return 1; }
    i64 fd = net_os_connect_start(ip, cast(u16, 443));
    if fd == -1 { print("connect failed\n"); return 1; }

    // example.com ECDSA SPKI pin (from picotls-minc example 10; may drift)
    u8* pinhex = cast(u8*, "b5d8f3ee8e63dbb30037ab85336fe928630649b4b204c4a2494d6be6ac382433");
    u8[32] pin;
    for i32 i = 0; i < 32; i++ {
        i32 hi = hexval(*(pinhex + i * 2));
        i32 lo = hexval(*(pinhex + i * 2 + 1));
        pin[i] = cast(u8, (hi << 4) | lo);
    }
    tls_set_ecdsa_pin(&pin[0]);
    TlsSession* s = tls_session_new(host);
    if s == null { print("session alloc failed\n"); return 1; }

    bool connected = false;
    bool sent = false;
    u8[65536] resp;
    i32 resp_len = 0;
    bool want_write = true;

    for i32 iters = 0; iters < 5000; iters++ {
        NetPollFd[1] p;
        p[0].fd = fd;
        p[0].events = NET_POLLIN;
        if !connected || want_write { p[0].events = NET_POLLIN | NET_POLLOUT; }
        p[0].revents = 0;
        i32 pr = net_os_poll(&p[0], 1, 4000);
        if pr < 0 { print("poll error\n"); break; }
        if pr == 0 { print("timeout\n"); break; }

        if !connected {
            if (p[0].revents & NET_POLLOUT) != 0 {
                if net_os_connect_result(fd) != 0 { print("connect refused\n"); break; }
                connected = true;
            } else {
                continue;
            }
        }

        i32 flags = tls_pump(s, fd);
        want_write = (flags & TLS_WANT_WRITE) != 0;
        if (flags & TLS_ERR) != 0 { print("TLS error\n"); break; }

        if tls_established(s) && !sent {
            sent = true;
            u8* req = cast(u8*, "GET / HTTP/1.0\r\nHost: example.com\r\nConnection: close\r\n\r\n");
            i32 rlen = 0;
            while *(req + rlen) != cast(u8, 0) { rlen++; }
            tls_write(s, fd, req, rlen);
        }

        if (flags & TLS_HAS_DATA) != 0 {
            while resp_len < 65536 {
                i32 n = tls_read(s, &resp[resp_len], 65536 - resp_len);
                if n <= 0 { break; }
                resp_len += n;
            }
        }
        if (flags & TLS_EOF) != 0 { break; }
    }

    i32 line = 0;
    while line < resp_len && resp[line] != cast(u8, 13) && resp[line] != cast(u8, 10) { line++; }
    str status;
    status.data = &resp[0];
    status.len = line;
    print("handshake={} bytes={}\n", tls_established(s) ? 1 : 0, resp_len);
    print("status: {}\n", status);
    net_os_close(fd);
    return 0;
}
