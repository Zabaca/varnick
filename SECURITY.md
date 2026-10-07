# Security

Launchy runs programs as you, on your Macs, and can reach them from your other Macs and your phone.
This note says who can make it do that, what each setting allows, and one known weakness. It
describes the code as it is; where a statement rests on a design decision, the decision is in
[`docs/adr/`](docs/adr/).

## Reporting a vulnerability

Report it privately through GitHub's private vulnerability reporting: the **Security** tab of this
repository, then **Report a vulnerability**. Please don't open a public issue or pull request for
a vulnerability. No email address is published for reports.

## Skip permissions

Settings › **Skip permissions** starts Claude sessions with `--dangerously-skip-permissions`. Claude
Code then runs its tools, including shell commands and file edits, without asking, in whatever folder the session is
in and as the account that runs Launchy. Anything that can steer a session, such as a web page
Claude reads, a file in the repository, or a prompt, can then act with the account's rights.

- **It is off for a new install.** A Mac that ran an earlier Launchy keeps Skip permissions on, or whatever
  it had stored, and can turn it off in Settings.
- **A peer's start request carries the peer's own choice.** When one Mac starts a session on another, the
  request says whether to skip permissions, and the host follows it, whatever its own setting says. A
  peer you list already reaches the host's account over SSH, so this grants nothing SSH doesn't. The
  Linux relay's own default, for a session that doesn't say, is off.
- The Phone page can start sessions on its host too, through the host's relay, and its sessions follow
  the host's setting.

## Peers over SSH

Peers pair over SSH, with your own keys (ADR 0007). The boundary is:

- **The peer list.** A request other than `hello` is answered only to a Mac the receiver lists, and a Mac
  that isn't listed is never contacted, except by Find Macs and Add, which you start. The request names the
  Mac asking, and the list is checked against that name; the name is not a credential, the SSH login is.
- **The SSH keys.** Launchy runs the relay with `ssh` as the account you gave, with no password prompts
  (`BatchMode`) and a host key accepted on first contact and refused if it later changes. Whoever holds a key
  that logs in as that account can run the relay, and can do anything that account can do anyway.
- **The relay runs as you.** It is Launchy's own binary (or `launchy-peer` on a headless host) running as the
  account the SSH key logs in as, with that account's files and tools. It listens on no network port. On a
  Mac it talks to the running app through a socket that only the account can use.

Between paired Macs, two things are copied to each other, for Recent and search:

- **Your Claude prompts**, with each session's folder, title and agent.
- **Your browsing-history archive**: full page addresses, titles, the names of your Chrome profiles, visit
  counts and last visits, the terms you searched, and each page's description. It is the sender's whole
  archive, sent in pieces.

The receiving Mac stores both in its own database until the Mac is removed from its peer list (or removes
it). Pair only Macs you would show that history to.

## The Phone page

The Phone page is a small web server that serves a host's sessions to your own devices.

- **It is off by default.** On a Mac, Settings › Serve the phone page turns it on. On a headless host, the
  installer's `--page` does.
- **It is published only with `tailscale serve`, to your tailnet** on HTTPS port 8444. Launchy and the
  installer never run `tailscale funnel`, and refuse to publish if Funnel is on for that port or its state
  can't be read.
- **Who is calling comes from Tailscale.** The server takes the first address in the `X-Forwarded-For` header
  that `tailscale serve` adds, asks Tailscale who owns that address (`tailscale whois`), and serves the page
  only to a device you listed on that host, by its tailnet node. Everything the page does is a request to the
  host's own relay, as that device. Changes need a `POST` with a matching `Origin`, and websockets are
  checked against it.
- **A listed device can do most of what a Mac peer can,** except the search sync, upgrades and restarts
  (those are for a listed Mac only): list sessions, start one in a project the host lists, take over and
  type in a terminal. Only list devices you control.

### Loopback mode is weaker. This is a known issue, to be fixed later

The server listens in one of two modes:

- **Socket mode:** on a Unix socket in a folder only your account can enter, so only your account can send it
  a request, and only `tailscale serve` does.
- **Loopback mode:** on `127.0.0.1:18444`. Any process on the Mac can connect to it, other user accounts on
  the Mac included, and can send an `X-Forwarded-For` header naming a listed device's tailnet address,
  the `Host` and `Origin` the page expects, and the rest. The server then treats the request as that device
  and answers it. A local process can pose as a listed device, start and drive sessions, and so get a
  shell as the account that runs Launchy. The tailnet's addresses and the page's name aren't secrets.

Launchy falls back to loopback when it can't serve a socket, for one of these reasons:

- **The Tailscale app's own command line** can't serve one.
- **An older standalone command line** can't.
- **No Tailscale command line was found**, or the one found didn't answer.
- **The Tailscale daemon refuses a socket to a user who isn't root** (the case for Homebrew's).

Settings names the reason when the page is on loopback, and the page itself shows a "Loopback mode" note.

Advice, until loopback mode is fixed:

- Use socket mode, by the remedy for the reason Settings names:
  - a refused socket: press **Use a socket** in Settings (the button shows only for this reason), and see
    ADR 0011 for the fix outside Launchy for a Homebrew-installed Tailscale daemon;
  - the Tailscale app's command line: updating the app does not help. Launchy uses the app's command line
    whenever the app is installed, so a standalone command line (such as Homebrew's) takes over only on a Mac
    without the app;
  - an older command line: install a newer one;
  - no command line found or none answering: install one where Launchy looks (the README lists the places).
- Or don't serve the page on a Mac that other people have accounts on, or run programs you don't trust.
- On a headless host the page always uses a socket.

### The administrator prompt

When Tailscale refuses to serve a socket to your user, **Use a socket** (and only that button) tries once
more with `tailscale serve` run as root through macOS's password prompt. It is the one place Launchy asks
for your password. The command is the same `serve` you would run with `sudo`, and it runs the `tailscale`
executable that Launchy found, as root, whoever owns that file. You can refuse it: cancel the prompt, or never press the button,
and the page stays on loopback with the weakness above. Nothing asks for a password by itself.

## Upgrades from origin/main

Settings › Peers can upgrade a Mac. **Upgrade** fetches `origin/main` in the checkout Launchy runs from,
fast-forwards to it and runs `make build`, which compiles and runs whatever that commit holds,
including the `Makefile`. A restart is separate and needs its own confirmation.

So anyone who can push to the repository a Mac fetches from can run code on that Mac, as its user, once
the user presses Upgrade (or Upgrade all, which asks once and lists each machine). A fork fetches
its own `origin`, not this repository: check which remote a checkout is using before you upgrade from it.
An upgrade leaves alone a checkout that isn't on `main` or has uncommitted changes to tracked files, and
refuses one whose `main` has commits `origin/main` lacks while `origin/main` has others, instead of building it.

The Linux installer works from the checkout it runs in, not from `origin`: it builds the committed
`Packages/LaunchyPeer` as it is at that checkout's `HEAD`, on the host.

## Other things Launchy fetches and runs

- **Downloads are pinned and checked.** The build checks the Metal shaders and zmx against SHA-256 digests
  in the `Makefile`; the installer does the same for zmx and Bun; the models are downloaded at fixed
  revisions from Hugging Face.
- **A model server.** With Server chosen for Search embeddings or Text generation, Launchy sends the
  searches and prompts typed, the text it embeds and each conversation's first prompt to the server you
  name, over HTTP or HTTPS. It accepts only an address whose name resolves to the tailnet or this Mac, and follows no
  redirect and no system proxy; it does not pin the address between its check and the connection. A
  server can therefore read those texts and the key you give it. Name only a server you run.
- **TypeSafe.** With a key and the relevance filter on TypeSafe, searches and result descriptions leave the
  Mac. See the README's Privacy section.
