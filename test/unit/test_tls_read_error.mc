// test_tls_read_error.mc -- a TLS session whose socket is reset fails.
//
// A read that returns an error is not "nothing yet". Taken for that, a reset
// connection stays readable with nothing to read, the reactor keeps waking the
// socket, and the program waits forever with no event: an HTTPS response that
// never completes and never fails. The reset here is a real one: the server
// accepts, lets the ClientHello arrive, and closes without reading it, and a
// close with unread data resets the connection. Exit 0 = pass.

import str;
import net;
import "../helpers/check.mc";
import "../../src/tls_native.mc";

// Waits up to 2 s for `events` on fd. Returns the events that came.
private i16 wait_for(i64 fd, i16 events) {
    NetPollFd pf;
    pf.fd = fd;
    pf.events = events;
    pf.revents = 0;
    ignore net_poll(&pf, 1, 2000);
    return pf.revents;
}

i32 main() {
    if !net_init() {
        print("  SKIP  net not available on this platform\n");
        return 0;
    }
    i64 lfd = net_nb_listen4(NET_LOOPBACK_BE, cast(u16, 0));
    check(lfd != -1, "listen");
    u16 port = net_fd_port(lfd);
    i64 cfd = net_connect_start(NET_LOOPBACK_BE, port);
    check(cfd != -1, "connect start");
    check(wait_for(lfd, NET_POLLIN) != 0, "the connection arrives");
    i64 afd = net_try_accept(lfd);
    check(afd >= 0, "accepted");
    check((wait_for(cfd, NET_POLLOUT) & NET_POLLOUT) != 0, "connected");

    TlsSession* s = tls_session_new(null, true);
    check(s != null, "session");
    i32 st = tls_pump(s, cfd);
    check((st & TLS_ERR) == 0, "the ClientHello goes out");
    st = tls_pump(s, cfd);
    check((st & TLS_ERR) == 0 && !tls_failed(s), "nothing to read yet is not a failure");

    // The ClientHello reaches the server, which closes without reading it.
    check((wait_for(afd, NET_POLLIN) & NET_POLLIN) != 0, "the server has the ClientHello");
    net_fd_close(afd);
    check(wait_for(cfd, NET_POLLIN) != 0, "the reset makes the client readable");

    st = tls_pump(s, cfd);
    check((st & TLS_ERR) != 0, "a reset fails the session");
    check(tls_failed(s), "and the session stays failed");
    check_eq(tls_error_code(s), TLS_ERR_READ, "as a read error");

    tls_session_free(s);
    net_fd_close(cfd);
    net_fd_close(lfd);
    net_shutdown();
    return check_done("tls_read_error");
}
