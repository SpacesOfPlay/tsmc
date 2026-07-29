// test_net_os.mc — non-blocking loopback echo through the socket layer:
// connect a client to an ephemeral loopback listener, accept, and
// round-trip a payload, driving everything with WSAPoll. Exit 0 = pass.

import str;
import "../helpers/check.mc";
import "../../src/net_os.mc";

// Poll one fd until it reports readiness (or we give up). Returns revents.
private i16 wait_ready(i64 fd, i16 want, i32 tries) {
    NetPollFd[1] p;
    for i32 t = 0; t < tries; t++ {
        p[0].fd = fd;
        p[0].events = want;
        p[0].revents = 0;
        i32 r = net_os_poll(&p[0], 1, 200);
        if r > 0 { return p[0].revents; }
        if r < 0 { return 0; }
    }
    return 0;
}

i32 main() {
    // net_os is only ported on Windows so far; elsewhere every operation
    // reports failure, so there is nothing to exercise.
    if !net_os_init() {
        print("  SKIP  net_os not ported on this platform\n");
        return 0;
    }

    i64 lfd = net_os_listen4(NET_LOOPBACK_BE, cast(u16, 0));
    check(lfd != -1, "listen on loopback:0");
    u16 port = net_os_port(lfd);
    check(port != 0, "ephemeral port assigned");

    i64 cfd = net_os_connect_start(NET_LOOPBACK_BE, port);
    check(cfd != -1, "connect start");

    // listener readable once the connection arrives
    i16 lr = wait_ready(lfd, NET_POLLIN, 50);
    check((lr & NET_POLLIN) != 0, "listener readable");
    i64 afd = net_os_accept(lfd);
    check(afd >= 0, "accept");

    // client writable once the handshake completes; SO_ERROR confirms it
    i16 cw = wait_ready(cfd, NET_POLLOUT, 50);
    check((cw & NET_POLLOUT) != 0, "client writable");
    check_eq(net_os_connect_result(cfd), 0, "connect succeeded");

    // client -> server
    u8[5] msg = { 104, 101, 108, 108, 111 };   // "hello"
    check_eq(net_os_send(cfd, &msg[0], 5), 5, "client sent 5");
    i16 ar = wait_ready(afd, NET_POLLIN, 50);
    check((ar & NET_POLLIN) != 0, "server readable");
    u8[16] rb;
    check_eq(net_os_recv(afd, &rb[0], 16), 5, "server received 5");
    check(rb[0] == 104 && rb[4] == 111, "server payload matches");

    // server -> client (echo)
    check_eq(net_os_send(afd, &rb[0], 5), 5, "server echoed 5");
    i16 cr = wait_ready(cfd, NET_POLLIN, 50);
    check((cr & NET_POLLIN) != 0, "client readable");
    u8[16] rb2;
    check_eq(net_os_recv(cfd, &rb2[0], 16), 5, "client received 5");
    check(rb2[0] == 104 && rb2[4] == 111, "client payload matches");

    // clean EOF: close server side, client recv returns 0
    net_os_close(afd);
    ignore wait_ready(cfd, NET_POLLIN, 50);
    u8[4] rb3;
    check_eq(net_os_recv(cfd, &rb3[0], 4), 0, "client sees EOF (recv 0)");

    net_os_close(cfd);
    net_os_close(lfd);
    net_os_cleanup();
    return check_done("net_os");
}
