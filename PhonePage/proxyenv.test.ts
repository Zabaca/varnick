import { describe, expect, test } from "bun:test";
import { withLocalNoProxy } from "./proxy";

describe("the NO_PROXY value", () => {
  test("keeps what was there and adds the localhost entries once", () => {
    expect(withLocalNoProxy(undefined)).toBe("localhost,127.0.0.1,[::1]");
    expect(withLocalNoProxy("")).toBe("localhost,127.0.0.1,[::1]");
    expect(withLocalNoProxy("a.example.test, LOCALHOST ,::1")).toBe("a.example.test,LOCALHOST,::1,127.0.0.1,[::1]");
    const once = withLocalNoProxy("a.example.test");
    expect(once).toBe("a.example.test,localhost,127.0.0.1,[::1]");
    expect(withLocalNoProxy(`${once},${once}`)).toBe(once);
  });
});

// Bun reads the proxy variables when it starts but NO_PROXY again at every request (not documented, so this is the check on a Bun
// upgrade). A test already running can't set the proxy, so this starts another with HTTP_PROXY and HTTPS_PROXY at a proxy that is not
// there and no NO_PROXY, and sets nothing itself: the port proxy's own start must keep its requests to localhost off the proxy.
describe("with a proxy configured in the environment", () => {
  test("the port proxy's tests still pass", async () => {
    const env: Record<string, string> = {};
    for (const [name, value] of Object.entries(process.env)) if (value !== undefined && !/^(http_proxy|https_proxy|all_proxy|no_proxy)$/i.test(name)) env[name] = value;
    for (const name of ["HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"]) env[name] = "http://proxy.example.test:9";
    const child = Bun.spawn([process.execPath, "test", "./portproxy.test.ts"], { cwd: import.meta.dir, env, stdout: "pipe", stderr: "pipe" });
    const [out, err, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    const report = `${out}\n${err}`;
    expect(report).toMatch(/\b0 fail\b/);
    expect(report).not.toMatch(/\b[1-9][0-9]* fail\b/);
    expect(code).toBe(0);
  }, 60_000);
});
