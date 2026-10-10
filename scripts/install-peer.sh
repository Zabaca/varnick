#!/usr/bin/env bash
# Install or update Varnick's headless relay on a Linux host, from the Mac you build on.
#
#   scripts/install-peer.sh <user@host> [--name NAME] [--page | --no-page] [--commit REV] [--uninstall]
#
#   --name NAME    the host's name in the Macs' lists, written to config.json only when there is none
#                  (default: its hostname with hyphens as spaces, so linux-box is "linux box")
#   --page         also installs the Phone page (ADR 0011): `PhonePage/` as committed, Bun if the host has none (pinned,
#                  checked by SHA-256), a systemd user unit that runs the server on a socket in ~/.varnick/phone, and
#                  publishes 8444 to it with `tailscale serve`. Without --page, a host that has the unit keeps it, gets
#                  its files updated and its port kept published
#   --no-page      unpublishes 8444 and removes the unit, its files and its socket
#   --commit REV   ships what REV holds, not what this checkout is on: the package, the Phone page, the far half and the
#                  protocol and Mac command the verify uses all come from that commit (a full or short hash, or a ref such
#                  as origin/main), and the working tree's changes are not looked at. The near half, this script, is the
#                  working tree's. It is how a Mac upgrades a headless host to origin/main from any branch (`HeadlessUpgrade`)
#   --uninstall    removes the relay, its link and its source, and the page. KEEPS state/, config.json, zmx and any
#                  running session
#
# What it publishes and unpublishes, and when it refuses, is ADR 0011's note of 2026-10-06 (so is PAGE_PUBLISH_PORT).
#
# Sends `Packages/VarnickPeer` as it is at this checkout's commit (or --commit's), builds it on the host with the Swift
# there (swiftly's, installed once by hand), and installs it under ~/.varnick. Nothing is built or
# installed on this Mac, and nothing keeps running on the host between requests but the page's server, if it has one.
#
# Two halves: a far half (scripts/remote/install-peer.sh) piped into
# `bash -s` that prints KEY=value markers, and this half decides from them (ADR 0009 says why, and when
# to run it again). It ends by sending a hello through the command a Mac sends.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
REMOTE_SCRIPT="$REPO/scripts/remote/install-peer.sh"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15)

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
# Value of KEY from `KEY=value` lines (the last one wins).
marker() { sed -n "s/^$1=//p" | tail -n 1; }
# What the far half said about taking the page's port down (UNPUBLISH), from $OUT.
report_unpublish() {
  case "$(printf '%s\n' "$OUT" | marker UNPUBLISH)" in
    removed) printf '  serve:      port %s unpublished (it pointed at the page)\n' "$PUBLISH_PORT" ;;
    none) printf '  serve:      port %s was not published\n' "$PUBLISH_PORT" ;;
    left) warn "$(printf '%s\n' "$OUT" | marker UNPUBLISHNOTE)" ;;
    failed) warn "port $PUBLISH_PORT couldn't be unpublished: $(printf '%s\n' "$OUT" | marker UNPUBLISHNOTE)" ;;
  esac
}

# The one port published and unpublished (ADR 0011's note). Digits only: it names the mount that is touched.
PUBLISH_PORT=${PAGE_PUBLISH_PORT:-8444}
case "$PUBLISH_PORT" in ''|*[!0-9]*) die "PAGE_PUBLISH_PORT must be a port number (got '$PUBLISH_PORT')" ;; esac

TARGET=""; NAME=""; ACTION=install; PAGE=auto; REV=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) [ $# -ge 2 ] || die "--name needs a value"; NAME=$2; shift 2 ;;
    --commit) [ $# -ge 2 ] && [ -n "$2" ] || die "--commit needs a commit"; REV=$2; shift 2 ;;
    --uninstall) ACTION=uninstall; shift ;;
    --page) [ "$PAGE" != remove ] || die "--page and --no-page together"; PAGE=on; shift ;;
    --no-page) [ "$PAGE" != on ] || die "--page and --no-page together"; PAGE=remove; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$TARGET" ] || die "one target only"; TARGET=$1; shift ;;
  esac
done
[ -n "$TARGET" ] || die "usage: scripts/install-peer.sh <user@host> [--name NAME] [--page | --no-page] [--commit REV] [--uninstall]"
case "$TARGET" in *[!A-Za-z0-9._@-]*) die "the target must be user@host, with letters, digits and . _ - only (got '$TARGET')" ;; esac
# The name goes into a JSON string on the far side and, in single quotes, onto its command line.
case "$NAME" in *[!A-Za-z0-9\ ._-]*) die "--name takes letters, digits, spaces and . _ - only (got '$NAME')" ;; esac

# A revision is a hash or a ref's name, never an option, and names one commit.
case "$REV" in -*|*[!A-Za-z0-9._/~^-]*) die "--commit takes a commit hash or a ref (got '$REV')" ;; esac
[ -z "$REV" ] || [ "$ACTION" = install ] || die "--uninstall takes no --commit"
[ "$ACTION" = install ] || [ "$PAGE" = auto ] || die "--uninstall takes the page away too: leave out --page and --no-page"
if [ "$ACTION" = uninstall ]; then
  log "uninstalling the relay from $TARGET"
  OUT=$("${SSH[@]}" "$TARGET" "env ACTION=uninstall PAGE_PUBLISH_PORT=$PUBLISH_PORT bash -s" <"$REMOTE_SCRIPT" | tee /dev/stderr) || true
  [ -n "$(printf '%s\n' "$OUT" | marker REMOVED)" ] || die "the far half didn't report a removal (see above)"
  echo
  log "relay removed from $TARGET"
  printf '  kept:       %s\n' "$(printf '%s\n' "$OUT" | marker KEPT)"
  report_unpublish
  exit 0
fi

# 1. Local: the package, as committed. REF is what everything shipped and read is taken from: HEAD, or the one commit --commit names,
# whatever the checkout is on and holds. `git archive` and `git show` read the object database, never the working tree.
if [ -n "$REV" ]; then
  REF=$(git -C "$REPO" rev-parse --verify --quiet "$REV^{commit}") || die "--commit $REV isn't a commit in $REPO (fetch first?)"
else
  REF=HEAD
fi
COMMIT=$(git -C "$REPO" rev-parse --short "$REF") || die "$REPO isn't a git checkout"
if [ -n "$REV" ]; then
  # The far half is the commit's too, so the host runs the installer that goes with what it is sent. Without --commit it is this
  # working tree's, as it always was.
  REMOTE_SCRIPT=$(mktemp "${TMPDIR:-/tmp}/varnick-install-far.XXXXXX")
  trap 'rm -f "$REMOTE_SCRIPT"' EXIT
  git -C "$REPO" show "$REF:scripts/remote/install-peer.sh" >"$REMOTE_SCRIPT" || die "$COMMIT has no scripts/remote/install-peer.sh"
else
  DIRTY=$(git -C "$REPO" status --porcelain -- Packages/VarnickPeer)
  if [ -n "$DIRTY" ]; then
    warn "uncommitted changes in Packages/VarnickPeer are left out: the build is HEAD's ($COMMIT)"
    printf '%s\n' "$DIRTY" >&2
  fi
fi
# This run's own name for what it ships, so two Macs installing on one host at once never read each other's tarball (the far half also
# takes a lock for the whole install). A far half from before RUN and the lock, which an older --commit brings, reads the old names. A far
# half says what it does in a `# supports: RUN LOCK` line.
RUN=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
if ! grep -Eq '^# supports:.* RUN( |$)' "$REMOTE_SCRIPT" || ! grep -Eq '^# supports:.* LOCK( |$)' "$REMOTE_SCRIPT"; then
  RUN=""
  warn "$COMMIT's far half predates the # supports: RUN LOCK line: using the shared incoming.tar.gz names, and it may not guard against another install at once"
fi
# The protocol version and the command a Mac sends, both as committed, for the verify at the end.
VERSION=$(git -C "$REPO" show "$REF:Packages/VarnickPeer/Sources/VarnickPeer/PeerProtocol.swift" | sed -n 's/.*static let version = \([0-9][0-9]*\).*/\1/p' | head -n 1)
REMOTE_COMMAND=$(git -C "$REPO" show "$REF:Sources/Varnick/PeerSocket.swift" \
  | sed -n 's/^ *static let remoteCommand = #"\(.*\)"#$/\1/p' | sed 's/\\#(name)/varnick-peer/g')
[ -n "$VERSION" ] || die "couldn't read the protocol version from PeerProtocol.swift"
[ -n "$REMOTE_COMMAND" ] || die "couldn't read PeerLink.remoteCommand from PeerSocket.swift"

# What this ships (the package, the page less its fixtures and tests, the far half) is `RelayFiles.pathspecs` in
# Sources/Varnick/RelayComparison.swift, which decides "relay unchanged": change both together.
log "shipping Packages/VarnickPeer at $COMMIT to $TARGET"
git -C "$REPO" archive --format=tar.gz "$REF" Packages/VarnickPeer \
  | "${SSH[@]}" "$TARGET" "mkdir -p \"\$HOME/.varnick\" && cat > \"\$HOME/.varnick/incoming${RUN:+-$RUN}.tar.gz\""

# The page, as committed, when it is wanted: asked for, or already installed there. The Makefile's copy leaves out the tests and
# fixtures too. A second archive: the package's is unpacked with --strip-components=2.
SHIP_PAGE=no
if [ "$PAGE" = on ]; then
  SHIP_PAGE=yes
elif [ "$PAGE" = auto ]; then
  # Tailscale SSH swallows exit codes: the answer is a word.
  HAS_UNIT=$("${SSH[@]}" "$TARGET" '[ -f "$HOME/.config/systemd/user/varnick-phone-page.service" ] && echo yes || echo no' </dev/null | tail -n 1)
  if [ "$HAS_UNIT" = yes ]; then SHIP_PAGE=yes; fi
fi
if [ "$SHIP_PAGE" = yes ]; then
  DIRTY_PAGE=""
  [ -n "$REV" ] || DIRTY_PAGE=$(git -C "$REPO" status --porcelain -- PhonePage)
  if [ -n "$DIRTY_PAGE" ]; then
    warn "uncommitted changes in PhonePage are left out: the page is HEAD's ($COMMIT)"
    printf '%s\n' "$DIRTY_PAGE" >&2
  fi
  log "shipping PhonePage at $COMMIT to $TARGET"
  git -C "$REPO" archive --format=tar.gz "$REF" PhonePage ':(exclude)PhonePage/fixtures' ':(exclude)*.test.ts' \
    | "${SSH[@]}" "$TARGET" "mkdir -p \"\$HOME/.varnick\" && cat > \"\$HOME/.varnick/incoming-page${RUN:+-$RUN}.tar.gz\""
fi

# 2 to 9, on the host: Swift, libstdc++, build, check, swap, zmx, config, identity, build and the page.
log "building and installing on $TARGET (a first build takes a few minutes)"
OUT=$("${SSH[@]}" "$TARGET" "env ACTION=install COMMIT=$COMMIT RUN=$RUN NAME='$NAME' PAGE=$PAGE PAGE_PUBLISH_PORT=$PUBLISH_PORT bash -s" <"$REMOTE_SCRIPT" | tee /dev/stderr) || true

[ "$(printf '%s\n' "$OUT" | marker SHIPPED)" != missing ] || die "the package didn't arrive on $TARGET (~/.varnick/incoming${RUN:+-$RUN}.tar.gz is missing there)"
[ "$(printf '%s\n' "$OUT" | marker LOCK)" != busy ] || die "another install on $TARGET held the lock for over 15 minutes: nothing was changed"
SWIFT=$(printf '%s\n' "$OUT" | marker SWIFT)
case "$SWIFT" in
  "") die "the far half didn't run (see above)" ;;
  missing) die "Swift isn't on $TARGET: install swiftly and Swift there by hand, from swift.org's Linux install page, then run this again" ;;
  unsupported) die "$TARGET isn't x86_64 Linux (see above)" ;;
esac
[ "$(printf '%s\n' "$OUT" | marker BUILT)" = ok ] || die "the build on $TARGET failed (see above)"
[ "$(printf '%s\n' "$OUT" | marker STATIC)" = ok ] || die "the binary links the Swift toolchain's own libraries (see above); nothing was replaced"
[ "$(printf '%s\n' "$OUT" | marker RUNS)" = ok ] || die "the new binary doesn't answer (see above); nothing was replaced"
[ "$(printf '%s\n' "$OUT" | marker SWAPPED)" = ok ] || die "the new binary couldn't be put in place (see above)"
[ "$(printf '%s\n' "$OUT" | marker ZMX)" = 0.8.1 ] || die "zmx 0.8.1 isn't beside the relay on $TARGET (see above)"
ID=$(printf '%s\n' "$OUT" | marker ID)
[ -n "$ID" ] || die "the relay made no identity on $TARGET (see above)"
[ "$(printf '%s\n' "$OUT" | marker BUILD)" = "$COMMIT" ] || die "the build wasn't recorded on $TARGET (see above)"
[ "$(printf '%s\n' "$OUT" | marker FALLBACK)" != gcc13 ] || warn "the build needed GCC 13's libstdc++ folder (libstdc++-14-dev: $(printf '%s\n' "$OUT" | marker STDCXX))"
if [ "$(printf '%s\n' "$OUT" | marker CONFIG)" = kept ] && [ -n "$NAME" ]; then
  warn "config.json already exists, so --name was ignored: edit ~/.varnick/config.json there"
fi

# 10. The page's markers, judged. Nothing here changes a thing on the host.
PAGE_STATE=$(printf '%s\n' "$OUT" | marker PAGE)
UNIT_PORT=$(printf '%s\n' "$OUT" | marker PAGEPORT)
case "$PAGE_STATE" in
  installed|kept)
    [ "$(printf '%s\n' "$OUT" | marker PUBLISHPORT)" = "$PUBLISH_PORT" ] || die "the far half says it publishes port '$(printf '%s\n' "$OUT" | marker PUBLISHPORT)', not $PUBLISH_PORT (see above)"
    [ "$(printf '%s\n' "$OUT" | marker UNIT)" = active ] || die "the page's unit isn't active on $TARGET (see above): journalctl --user -u varnick-phone-page"
    [ "$(printf '%s\n' "$OUT" | marker ANSWERS)" = yes ] || die "the page's socket on $TARGET doesn't answer (see above): journalctl --user -u varnick-phone-page"
    [ "$(printf '%s\n' "$OUT" | marker KILLMODE)" = process ] || die "the page's unit lacks KillMode=process on $TARGET: stopping it would end every session its relay started"
    [ "$(printf '%s\n' "$OUT" | marker SOCKET)" = 600 ] || die "the page's socket on $TARGET isn't mode 600 (see above)"
    [ "$(printf '%s\n' "$OUT" | marker PHONEDIR)" = 700 ] || die "~/.varnick/phone on $TARGET isn't mode 700 (see above)"
    # Anything but a clean off is a failure: Funnel unread is Funnel unknown.
    [ "$(printf '%s\n' "$OUT" | marker FUNNEL)" = off ] || die "Funnel isn't known to be off for $PUBLISH_PORT on $TARGET ($(printf '%s\n' "$OUT" | marker FUNNEL)): the sessions might be public"
    [ "$(printf '%s\n' "$OUT" | marker LINGER)" = yes ] || warn "linger is off for the user on $TARGET: the page stops when the last login ends. Turn it on: sudo loginctl enable-linger \$USER"
    BUN_FOUND=$(printf '%s\n' "$OUT" | marker BUN)
    BUN_PIN=$(printf '%s\n' "$OUT" | marker BUNPIN)
    [ "$BUN_FOUND" = "$BUN_PIN" ] || warn "Bun $BUN_FOUND is on $TARGET: the page is checked against $BUN_PIN"
    ;;
  removed|off) ;;
  failed)
    FUNNEL_SAID=$(printf '%s\n' "$OUT" | marker FUNNEL)
    report_unpublish
    if [ -n "$FUNNEL_SAID" ]; then die "Funnel isn't known to be off on $TARGET ($FUNNEL_SAID), so the page was not started (a running one was stopped). Turn Funnel off by hand, or fix tailscale there, then run this again"; fi
    die "the page couldn't be installed on $TARGET (see above)" ;;
  *) die "the far half didn't report the page (see above)" ;;
esac

# 11. Local: verify, with the exact command a Mac sends, so it proves what a Mac's request will reach.
log "asking $TARGET for a hello, the way a Mac does"
REQUEST=$(printf '{"op":"hello","v":%s}' "$VERSION" | base64 | tr -d '\n')
REPLY=$("${SSH[@]}" "$TARGET" "$REMOTE_COMMAND --peer '$REQUEST'" </dev/null 2>&1 | grep '^{' | tail -n 1 || true)
for want in '"ok":true' "\"v\":$VERSION}" "\"id\":\"$ID\"" "\"build\":\"$COMMIT\""; do
  case "$REPLY" in
    *"$want"*) ;;
    *) die "the hello from $TARGET lacks $want: $REPLY" ;;
  esac
done
echo "VERIFY=ok"

echo
log "relay on $TARGET"
printf '  build:      %s (protocol %s)\n' "$COMMIT" "$VERSION"
printf '  swift:      %s, libstdc++-14-dev %s, link fix %s\n' "$SWIFT" "$(printf '%s\n' "$OUT" | marker STDCXX)" "$(printf '%s\n' "$OUT" | marker FALLBACK)"
printf '  binary:     %s bytes, static %s, runs %s\n' "$(printf '%s\n' "$OUT" | marker SIZE)" "$(printf '%s\n' "$OUT" | marker STATIC)" "$(printf '%s\n' "$OUT" | marker RUNS)"
printf '  zmx:        %s\n' "$(printf '%s\n' "$OUT" | marker ZMX)"
printf '  id:         %s\n' "$ID"
printf '  config:     %s\n' "$(printf '%s\n' "$OUT" | marker CONFIG)"
echo "Add it on each Mac: Settings > Peers > Add $TARGET"

case "$PAGE_STATE" in
  installed|kept)
    HOSTDNS=$(printf '%s\n' "$OUT" | marker HOSTDNS)
    SERVE=$(printf '%s\n' "$OUT" | marker SERVE)
    echo
    log "Phone page on $TARGET"
    printf '  unit:       %s, MainPID %s, KillMode %s, linger %s\n' "$(printf '%s\n' "$OUT" | marker UNIT)" "$(printf '%s\n' "$OUT" | marker MAINPID)" "$(printf '%s\n' "$OUT" | marker KILLMODE)" "$(printf '%s\n' "$OUT" | marker LINGER)"
    printf '  changed:    %s\n' "$(printf '%s\n' "$OUT" | marker PAGECHANGED)"
    printf '  bun:        %s\n' "$(printf '%s\n' "$OUT" | marker BUN)"
    printf '  socket:     mode %s in a folder of mode %s\n' "$(printf '%s\n' "$OUT" | marker SOCKET)" "$(printf '%s\n' "$OUT" | marker PHONEDIR)"
    printf '  funnel:     %s\n' "$(printf '%s\n' "$OUT" | marker FUNNEL)"
    # The far half published the port or said why not; its own read (SERVE) must agree, and this Mac must be refused (403)
    # or answered (200) through the port.
    PUBLISHED=$(printf '%s\n' "$OUT" | marker PUBLISH)
    PUBLISH_NOTE=$(printf '%s\n' "$OUT" | marker PUBLISHNOTE)
    PUBLISH_PROBLEM=""
    case "$PUBLISHED" in
      published|kept)
        if [ "$SERVE" != socket ]; then
          PUBLISH_PROBLEM="the far half published port $PUBLISH_PORT on $TARGET, but its serve status says '$SERVE', not the page's socket: look at 'tailscale serve status' there"
        else
          # This Mac isn't a device, so the page refuses it (403) or, if it is listed there, answers (200).
          CODE=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 15 "https://$HOSTDNS:$PUBLISH_PORT/" || true)
          # The unit's Host check expects its own port: 421 through another port still shows serve reaching the socket.
          if [ "$CODE" = 200 ] || [ "$CODE" = 403 ] || { [ "$CODE" = 421 ] && [ "$PUBLISH_PORT" != "$UNIT_PORT" ]; }; then
            echo "PAGE_VERIFY=ok"
            printf '  serve:      port %s %s, and reaches the socket (this Mac was answered %s)\n' "$PUBLISH_PORT" "$PUBLISHED" "$CODE"
          else
            PUBLISH_PROBLEM="https://$HOSTDNS:$PUBLISH_PORT/ answered '$CODE' from this Mac, not 403 or 200"
          fi
        fi ;;
      conflict) PUBLISH_PROBLEM="$PUBLISH_NOTE. The page is installed but not published: take that mount down yourself (tailscale serve --https=$PUBLISH_PORT off on $TARGET) if it isn't wanted, then run this again" ;;
      *) PUBLISH_PROBLEM="port $PUBLISH_PORT on $TARGET was not published (${PUBLISHED:-no answer}): ${PUBLISH_NOTE:-see above}" ;;
    esac
    echo "Add the phone: ssh $TARGET '~/.varnick/varnick-peer device add <its tailnet name>'"
    [ -z "$PUBLISH_PROBLEM" ] || die "$PUBLISH_PROBLEM"
    ;;
  removed)
    echo "Phone page removed from $TARGET: the unit, its files and its socket"
    report_unpublish ;;
esac
