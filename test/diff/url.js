// URL / URLSearchParams (WHATWG globals — no import needed).

// --- URLSearchParams ---
const p = new URLSearchParams("a=1&b=2&a=3&c=hello%20world");
console.log(p.get("a"), p.getAll("a").join(","), p.has("b"), p.has("z"), p.get("c"));
console.log(p.toString(), p.size);
p.append("d", "x y"); p.set("a", "9"); p.delete("b");
console.log(p.toString());
console.log(new URLSearchParams({ x: "1", y: "2" }).toString());
console.log(new URLSearchParams([["k", "v"], ["k", "w"]]).toString());
const q = new URLSearchParams("z=1&a=2&m=3"); q.sort();
console.log(q.toString());
const acc = []; p.forEach((v, k) => acc.push(k + ":" + v)); console.log(acc.join(" "));
console.log([...q.keys()].join(","), [...q.entries()].map((e) => e.join("=")).join("&"));

// --- URL: absolute ---
const u = new URL("https://user:pass@example.com:8443/p/a/t?x=1&y=2#frag");
console.log(u.protocol, u.username, u.password, u.hostname, u.port);
console.log(u.host, u.pathname, u.search, u.hash, u.origin);
console.log(u.href, u.searchParams.get("x"), u.searchParams.get("y"));
const d = new URL("http://a.com:80/x/");
console.log(d.port, d.host, d.origin, d.href, d.pathname);
console.log(new URL("http://h.com").pathname, new URL("https://h.com/?q").search);
console.log(new URL("file:///etc/hosts").protocol, new URL("file:///etc/hosts").origin);
console.log(String(new URL("https://x.com/a")), new URL("https://x.com/a").toJSON());

// --- URL: relative resolution ---
const base = "https://example.com/dir/page.html?q=1#h";
for (const rel of ["/api/v1", "sub/x", "../up", "./same", "?newq", "#newh", "//cdn.com/lib.js", "https://other.com/z"]) {
  console.log(rel, "->", new URL(rel, base).href);
}
console.log(new URL("a/b/../c", "http://h.com/x/y/z").pathname);
console.log(new URL("/p", new URL(base)).href);

// --- error ---
try { new URL("not a url"); console.log("no throw"); }
catch (e) { console.log(e.constructor.name, e.message.includes("Invalid URL")); }
