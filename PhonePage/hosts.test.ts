import { describe, expect, test } from "bun:test";
import { addressHost, hostLinks, hostNodes, parseNodeNames } from "./hosts";
import { shapeHome } from "./home";

const own = "mac-mini.example.ts.net";
const nodes = new Set([own, "linux-box.example.ts.net", "alexs-macbook-pro.example.ts.net", "phone-1.example.ts.net"]);
const reply = (...hosts: Array<[string, string]>) => ({ hosts: hosts.map(([name, address]) => ({ name, address })) });
const links = (...hosts: Array<[string, string]>) => hostLinks(reply(...hosts), own, nodes, 8444);

describe("the address of a listed host", () => {
  test("drops user@ and keeps a plain name", () => {
    expect(addressHost("alex@linux-box")).toBe("linux-box");
    expect(addressHost("mac-mini.example.ts.net")).toBe("mac-mini.example.ts.net");
    expect(addressHost("Alex@Linux-Box")).toBe("linux-box");
  });

  test("is nothing for a port, an IPv6 address, a zone, an option or an empty name", () => {
    for (const address of ["alex@linux-box:2222", "[fd7a::1]", "fe80::1%en0", "-oProxyCommand=x", "", "alex@", "a b", "linux_box"]) expect(addressHost(address)).toBeNull();
  });
});

describe("the nodes of the listed hosts", () => {
  test("are the tailnet names the links are built on, this host's own left out", () => {
    expect(hostNodes(reply(["linux box", "alex@linux-box"], ["Self", "alex@mac-mini"], ["Check", "alex@check"]), own, nodes))
      .toEqual([{ name: "linux box", dns: "linux-box.example.ts.net" }]);
  });
});

describe("the links to the other hosts' pages", () => {
  test("a name with no dot is read under this host's tailnet suffix", () => {
    expect(links(["linux box", "alex@linux-box"])).toEqual([{ name: "linux box", url: "https://linux-box.example.ts.net:8444/" }]);
  });

  test("a MagicDNS name is a link as it stands", () => {
    expect(links(["The Pro", "alexs-macbook-pro.example.ts.net"])).toEqual([{ name: "The Pro", url: "https://alexs-macbook-pro.example.ts.net:8444/" }]);
  });

  test("this host's own page gets none, by either spelling", () => {
    expect(links(["Self", "mac-mini.example.ts.net"], ["Self", "alex@mac-mini"])).toEqual([]);
  });

  test("an address that isn't a node of the tailnet gets none", () => {
    expect(links(["Check", "alex@check"], ["Elsewhere", "box.example.com"], ["An IP", "100.64.0.9"], ["Port", "alex@linux-box:22"])).toEqual([]);
  });

  test("a host listed twice shows once, and the order is the list's", () => {
    expect(links(["linux box", "alex@linux-box"], ["Pro", "alex@alexs-macbook-pro"], ["linux box again", "linux-box.example.ts.net"]).map((link) => link.name)).toEqual(["linux box", "Pro"]);
  });

  test("a missing name falls back to the host's label, and control characters go", () => {
    expect(links(["", "alex@linux-box"])[0].name).toBe("linux-box");
    expect(links(["lin\u0007ux box\n", "alex@linux-box"])[0].name).toBe("linux box");
  });

  test("an odd reply gives no links", () => {
    expect(hostLinks({}, own, nodes, 8444)).toEqual([]);
    expect(hostLinks({ hosts: "x" }, own, nodes, 8444)).toEqual([]);
    expect(hostLinks({ hosts: [1, null, { name: 3, address: 4 }] }, own, nodes, 8444)).toEqual([]);
  });

  test("with no node list there are no links, whatever was listed", () => {
    expect(hostLinks(reply(["linux box", "alex@linux-box"]), own, new Set(), 8444)).toEqual([]);
  });

  test("the page's port is the one in the link", () => {
    expect(hostLinks(reply(["linux box", "alex@linux-box"]), own, nodes, 9000)[0].url).toBe("https://linux-box.example.ts.net:9000/");
  });
});

describe("the tailnet's own nodes", () => {
  test("are this node and each peer, lowercase and with no final dot", () => {
    const text = JSON.stringify({ Self: { DNSName: "Mac-Mini.example.ts.net." }, Peer: { a: { DNSName: "linux-box.example.ts.net." }, b: { HostName: "no-dns" }, c: 7 } });
    expect([...parseNodeNames(text)].sort()).toEqual(["linux-box.example.ts.net", "mac-mini.example.ts.net"]);
  });

  test("are nothing when the text isn't the status", () => {
    expect(parseNodeNames("not json").size).toBe(0);
    expect(parseNodeNames("[]").size).toBe(0);
  });
});

describe("what the browser is told", () => {
  test("holds names and URLs and no id or address", () => {
    const device = { id: "5f0f3a4e-2b6e-4c0a-9d58-0a2f6f8d1c11", node: "n", name: "Phone" };
    const peerID = "00000000-0000-4000-8000-000000000001";
    const shaped = links(["linux box", "alex@linux-box"]);
    const home = shapeHome({
      host: { name: "Mac mini", headless: false }, loopback: false, device,
      tabs: { ok: true, reply: { tabs: [] } }, recent: { ok: true, reply: { recent: [] } }, hosts: shaped,
    });
    const json = JSON.stringify(home);
    expect(home.hosts).toEqual(shaped);
    expect(json).not.toContain(peerID);
    expect(json).not.toContain("alex@");
  });
});
