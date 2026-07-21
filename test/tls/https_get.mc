// Manual (network-dependent) driver: non-blocking HTTPS GET to a real
// server through the TLS session pump, with the default CA-chain +
// hostname validation. Prints the response status line. Run: build with
// minc against src/tls_native.mc; not part of the gated suite. Host via
// arg is not wired; edit HOST below.

import "../../src/tls_native.mc";
import "../../src/net_os.mc";

i32 main() {
    u8* host = cast(u8*, "example.com");
    if !net_os_init() { print("WSA init failed\n"); return 1; }
    u32 ip = net_os_resolve4(host);
    if ip == 0 { print("DNS failed\n"); return 1; }
    i64 fd = net_os_connect_start(ip, cast(u16, 443));
    if fd == -1 { print("connect failed\n"); return 1; }

    TlsSession* s = tls_session_new(host, false);
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
