<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/varnick-mark-dark.svg">
    <img src="docs/assets/varnick-mark-light.svg" width="64" height="64" alt="">
  </picture>
</p>

<h1 align="center">Varnick</h1>

<p align="center">
  <b>Your Claude sessions, one keystroke away.</b><br>
  A floating panel for Claude Code, terminals and every page you've visited.
</p>

<p align="center">
  <a href="https://github.com/Zabaca/varnick/releases/latest/download/Varnick.zip">Download for Mac</a>
  &nbsp;·&nbsp;
  <a href="https://varnick.com">varnick.com</a>
</p>

## What it does

- **Find a page Chrome forgot.** Varnick keeps your Chrome history in an archive on your Mac that outlives
  Chrome's own, and searches it by meaning as well as by words.
- **Keep a session next to what it works on.** Claude Code sessions, terminals, web pages and files open side by
  side in one panel.
- **Resume any session by describing it.** Every Claude Code session you've had is listed and searchable.
- **Reach a session on another machine.** Pair Varnick on your other Macs, or a headless Linux host, over SSH.
- **Check on a session from your phone,** with a page served to your own devices over Tailscale.
- **Ask out loud.** Say "Hey Varnick" to search your history and sessions, or to have it point at something on
  your screen.

Varnick is not affiliated with or endorsed by Anthropic. Claude and Claude Code are Anthropic's.

## Install

You need an Apple Silicon Mac with macOS 14 or later, and the [Claude Code](https://claude.com/claude-code) CLI.

1. Download `Varnick.zip` from [the latest release](https://github.com/Zabaca/varnick/releases/latest).
2. Unzip it, move `Varnick.app` to Applications, and open it.
3. macOS asks for each permission the first time a feature needs it.

The app is signed and notarized. It doesn't update itself: to update, quit Varnick from its menu bar menu and
replace the app with the newest download.

Chrome (the only browser it reads), [Bun](https://bun.sh) and [Tailscale](https://tailscale.com) are optional;
the [guide](docs/guide.md#requirements) says which features need them.

## Privacy

Your history archive, Claude transcripts, voice transcripts and search models stay on your Mac. Out of the box,
the only requests Varnick makes are to the pages in your history, once each and without cookies, to read their
descriptions. It downloads models from Hugging Face only when you ask.

Anything else leaves only when you turn it on:

- **Pairing a Mac** copies your browsing history and Claude prompts to it.
- **Choosing TypeSafe** for the relevance filter sends your searches, and the titles, sites and descriptions of
  their results, to TypeSafe. With Hey Varnick on, so does what you say, and with Point at the screen, the text
  of the window you ask about.
- **Screen access** lets Claude sessions read the window in front, which goes to Anthropic with the session.
- **A model server** you name gets your searches, your prompts and the text it embeds, and nothing goes past it.

Everything Varnick reads, records and sends, and what it lets others do, is in
[Privacy and security](docs/privacy-and-security.md).

## More

- [Guide](docs/guide.md): every feature, its settings and its defaults.
- [Building from source](docs/building.md), and installing the relay on a Linux host.
- [Privacy and security](docs/privacy-and-security.md): what Varnick sends, what Skip permissions, peers, the
  Phone page and upgrades let others do, and how to report a vulnerability.
- [Contributing](CONTRIBUTING.md): how the code is checked and how work is planned. The design is in
  [`docs/adr/`](docs/adr/) and [`docs/problems/`](docs/problems/).
- The varnick.com page is in [`site/`](site/).

## Licence

Apache License 2.0 (see [`LICENSE`](LICENSE)). Copyright 2026 Zabaca. Third-party code and models are listed in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
