// Named after a package on purpose: "expkg" below must not resolve to
// this file, and the two siblings must not stand in for their packages.
import { tag } from "pkgindex";
import expkg from "expkg";
import extra from "expkg/extra";

export async function report(): Promise<string> {
  const dyn = await import("pkgmain");
  return [tag, expkg.entry.startsWith("exports-"), extra.extra, dyn.default.pad(7, 3)].join(" | ");
}
