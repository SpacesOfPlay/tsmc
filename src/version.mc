// version.mc — the one place tsmc's version number is written.
//
// `tsmc --version` prints it, the test suite checks that line, and the
// release verb in build.mc names its downloadable binaries with it. The
// release workflow refuses to publish a tag that disagrees with it, so a
// release is: set this, commit, tag, push.
//
// Between releases it carries a -dev suffix, which no tag can match.

str TSMC_VERSION = "0.1.0-dev";
