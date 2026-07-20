// picotls.mc — TLS 1.3 core, vendored subset (see THIRD_PARTY.md).
//
// This router pulls in only the transport-agnostic buffer API and its
// crypto backends. It deliberately omits the upstream port's `net`,
// `thread`, and `pico_https` layers: tsmc owns its (non-blocking) sockets
// and event loop, and drives TLS purely through ptls_handshake /
// ptls_receive / ptls_send over in-memory buffers.

import cstdlib_shim;
import cfile_shim;
import picotls_shim;
import picotls_lib;
import picotls_bridges;
import picotls_bridges_p256;
import picotls_bridges_rsa;
