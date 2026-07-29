// test_reactor_net.mc — the reactor drives a loopback echo end to end
// through the dispatch hook: connect completes on writable, the listener
// accepts on readable, bytes round-trip, and the loop exits once every
// handle is closed/unref'd. Exit 0 = pass.

import str;
import "../helpers/check.mc";
import "../../src/value.mc";
import "../../src/object.mc";
import "../../src/vm.mc";
import "../../src/net_os.mc";

i32 g_lidx = -1;   // listener handle
i32 g_cidx = -1;   // client handle
i32 g_aidx = -1;   // accepted (server-side) handle
bool g_client_sent = false;
bool g_got_echo = false;
u8[16] g_recv;
i32 g_recv_n = 0;

// Reactor hook: a one-shot echo across three handles.
void test_hook(VM* vm, i32 idx, i16 revents) {
    i64 fd = vm_handle_fd(vm, idx);
    if idx == g_lidx {
        if (revents & NET_POLLIN) != 0 {
            i64 afd = net_os_accept(fd);
            if afd >= 0 {
                g_aidx = vm_handle_add(vm, afd, 0, value_undefined());
                vm_handle_set_interest(vm, g_aidx, NET_POLLIN);
                // one connection is enough — stop polling / holding the listener
                vm_handle_set_interest(vm, g_lidx, cast(i16, 0));
                vm_handle_unref(vm, g_lidx);
            }
        }
        return;
    }
    if idx == g_cidx {
        if !g_client_sent && (revents & NET_POLLOUT) != 0 {
            if net_os_connect_result(fd) == 0 {
                u8[5] msg = { 104, 101, 108, 108, 111 };   // "hello"
                ignore net_os_send(fd, &msg[0], 5);
                g_client_sent = true;
                vm_handle_set_interest(vm, g_cidx, NET_POLLIN);
            }
        } else if (revents & NET_POLLIN) != 0 {
            i32 n = net_os_recv(fd, &g_recv[0], 16);
            if n > 0 { g_recv_n = n; g_got_echo = true; }
            net_os_close(fd);
            vm_handle_close(vm, g_cidx);
            vm_handle_unref(vm, g_cidx);
        }
        return;
    }
    if idx == g_aidx {
        if (revents & NET_POLLIN) != 0 {
            u8[16] b;
            i32 n = net_os_recv(fd, &b[0], 16);
            if n > 0 { ignore net_os_send(fd, &b[0], n); }   // echo
            net_os_close(fd);
            vm_handle_close(vm, g_aidx);
            vm_handle_unref(vm, g_aidx);
        }
        return;
    }
}

i32 main() {
    // net_os is only ported on Windows so far; elsewhere listen/connect
    // report failure and the reactor would wait forever for events.
    if !net_os_init() {
        print("  SKIP  net_os not ported on this platform\n");
        return 0;
    }
    VM m;
    vm_init(&m);
    vm_set_reactor_hook(&m, &test_hook);

    i64 lfd = net_os_listen4(NET_LOOPBACK_BE, cast(u16, 0));
    check(lfd != -1, "listen");
    u16 port = net_os_port(lfd);
    g_lidx = vm_handle_add(&m, lfd, 0, value_undefined());
    vm_handle_set_interest(&m, g_lidx, NET_POLLIN);

    i64 cfd = net_os_connect_start(NET_LOOPBACK_BE, port);
    check(cfd != -1, "connect start");
    g_cidx = vm_handle_add(&m, cfd, 0, value_undefined());
    vm_handle_set_interest(&m, g_cidx, NET_POLLOUT);

    i32 st = vm_run_event_loop(&m);
    check_eq(st, 0, "reactor loop clean exit");
    check(g_got_echo, "client got echo via the reactor");
    check_eq(g_recv_n, 5, "echo length 5");
    check(g_recv[0] == 104 && g_recv[4] == 111, "echo payload matches");

    net_os_close(lfd);
    net_os_cleanup();
    vm_destroy(&m);
    return check_done("reactor_net");
}
