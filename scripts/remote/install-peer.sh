#!/usr/bin/env bash
# Runs ON the headless host, piped into `bash -s` by scripts/install-peer.sh. Do not run by hand.
#
# Builds Varnick's relay (`varnick-peer`, from Packages/VarnickPeer) and installs it under ~/.varnick,
# whose layout, and why this prints KEY=value markers, ADR 0009 holds.
#
# Inputs (env): ACTION=install|uninstall, COMMIT (short), RUN (the near half's name for this run's files), NAME (the host's name,
# optional), PROBLEMS=on|off|auto (the work-link hooks of ADR 0020 in the sessions this host starts: `on` writes ~/.varnick/problems, which the
# relay looks for when it builds a session's hook settings, `off` removes it, `auto` keeps what is there; prints PROBLEMS=on|off), AUTOMATIONS=on|off|auto
# (the automations' timer, option 01 of `prompts-cant-run-on-a-schedule`: `on` writes a systemd user timer that starts a `oneshot` service running
# `varnick-peer tick` once a minute, `off` removes both units, `auto` rewrites them only where they exist; prints AUTOMATIONS=on|off), PAGE=on|auto|remove
# (the Phone page, ADR 0011: `on` installs its server and unit, `auto` updates them only where the unit already
# exists, `remove` takes them away; default auto). The package arrives as ~/.varnick/incoming-$RUN.tar.gz (`git archive
# <commit> Packages/VarnickPeer`), and the page, when PAGE is on or auto and the unit exists, as ~/.varnick/incoming-page-$RUN.tar.gz
# (`git archive <commit> PhonePage`); without RUN the names have no suffix; a run's own are gone at its end, and another run's older than a day (left when its far half never ran) are removed once the lock is held. One install runs at a time per host: a lock on
# ~/.varnick/install.lock is held from the start (LOCK=ok, waited, none where there is no flock, or busy after 15 minutes, which stops). It publishes the page's port with `tailscale serve` and takes it down; the rules and
# PAGE_PUBLISH_PORT are ADR 0011's note of 2026-10-06.
#
# What this far half supports, which the near half reads rather than guessing from a function name: RUN (per-run tarball names), LOCK
# (the install lock), PROBLEMS (the problems file), AUTOMATIONS (the timer). Add a word when a feature the near half adapts to arrives; never remove one.
# supports: RUN LOCK PROBLEMS AUTOMATIONS
#
# Everything that runs is called from `main`, with stdin on /dev/null: this script is read from stdin, and a command
# that read stdin would take the rest of it. The functions above `main` only define what it calls.

# The Phone page's Bun, pinned: the page is checked against one Bun, and a download is only installed when it matches
# the release's published SHA-256 (SHASUMS256.txt, bun-linux-x64.zip; the AVX2 build, which the host's CPU must have). A Bun
# that is already there is kept whatever its version. The far half reports the pin (BUNPIN) and the version found (BUN), so
# no other script holds the number.
BUN_VERSION=1.3.14
BUN_SHA256=951ee2aee855f08595aeec6225226a298d3fea83a3dcd6465c09cbccdf7e848f
BUN_URL="https://github.com/oven-sh/bun/releases/download/bun-v$BUN_VERSION/bun-linux-x64.zip"
PAGE_UNIT=varnick-phone-page.service
# The automations' timer and the service it starts (ADR 0009's amendment, ADR 0040): the service runs `varnick-peer tick`, the host's firing step.
TICK_SERVICE=varnick-automations.service
TICK_TIMER=varnick-automations.timer
# The port the unit's Host check expects, and the one this script publishes (the only mount it touches; ADR 0011's note).
PAGE_PORT=8444
PUBLISH_PORT=${PAGE_PUBLISH_PORT:-8444}

# A `bash -s` over ssh has no user manager to talk to unless it adopts the one that is running.
adopt_runtime_dir() {
  command -v systemctl >/dev/null 2>&1 || return 0
  if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$(id -u)" ]; then export XDG_RUNTIME_DIR="/run/user/$(id -u)"; fi
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "${XDG_RUNTIME_DIR:-/nonexistent}/bus" ]; then export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"; fi
}

# Bun at the path given (default ~/.bun/bin/bun): installed from the pinned release only when missing. Prints BUN=<version> or
# missing, and BUNFETCH=installed only when the release was fetched, matched its digest and was put in place.
ensure_bun() {
  local bin="${1:-$HOME/.bun/bin/bun}" work found fetched=no
  if [ ! -x "$bin" ]; then
    if [ "$(uname -m)" != x86_64 ]; then
      echo "only x86_64 Linux is supported (Bun's release here); this machine is $(uname -m)"
    elif ! command -v unzip >/dev/null 2>&1; then
      echo "unzip isn't installed here, and unpacking Bun's release needs it (apt install unzip)"
    else
      work=$(mktemp -d "${TMPDIR:-/tmp}/varnick-bun.XXXXXX")
      if curl -fsSL --retry 2 -o "$work/bun.zip" "$BUN_URL" \
         && [ "$(sha256sum "$work/bun.zip" | awk '{print $1}')" = "$BUN_SHA256" ] \
         && (cd "$work" && unzip -q bun.zip) && [ -f "$work/bun-linux-x64/bun" ] \
         && mkdir -p "$(dirname "$bin")" \
         && install -m 755 "$work/bun-linux-x64/bun" "$bin.new" && mv -f "$bin.new" "$bin"; then
        fetched=yes
      else
        echo "Bun $BUN_VERSION couldn't be fetched and checked against its pinned SHA-256"
      fi
      rm -rf "$work"
    fi
  fi
  if [ "$fetched" = yes ]; then echo "BUNFETCH=installed"; fi
  found=$("$bin" --version 2>/dev/null | head -n 1)
  echo "BUN=${found:-missing}"
}

# This host's MagicDNS name (lowercase, no final dot), or nothing when `tailscale status --json` can't say.
tailnet_name() {
  timeout 8 tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print((((json.load(sys.stdin) or {}).get("Self") or {}).get("DNSName") or "").rstrip(".").lower())' 2>/dev/null
}

# Whether Funnel is on for the page's port: off, on or unknown. It fails closed: only a clean read of both `serve status
# --json` (its AllowFunnel, as the Mac's Settings reads it) and `funnel status` that finds nothing is off, and anything that
# can't be read is unknown. Read only: see where-it-breaks.md > Phone page for what the installer never runs.
funnel_state() {
  local dns json text rc
  command -v tailscale >/dev/null 2>&1 || { echo unknown; return 0; }
  command -v python3 >/dev/null 2>&1 || { echo unknown; return 0; }
  dns=$(tailnet_name)
  [ -n "$dns" ] || { echo unknown; return 0; }
  json=$(timeout 8 tailscale serve status --json 2>/dev/null) || { echo unknown; return 0; }
  text=$(timeout 8 tailscale funnel status 2>/dev/null) || { echo unknown; return 0; }
  printf '%s' "$json" | python3 -c '
import json, sys
try:
    allowed = (json.load(sys.stdin) or {}).get("AllowFunnel") or {}
    key = (sys.argv[1] + ":" + sys.argv[2]).lower()
    on = any(k.lower() == key and v is True for k, v in allowed.items())
except Exception:
    sys.exit(2)
sys.exit(0 if on else 1)
' "$dns" "$PUBLISH_PORT" 2>/dev/null
  rc=$?
  case "$rc" in 0) echo on; return 0 ;; 1) ;; *) echo unknown; return 0 ;; esac
  # A header line for the port that isn't "(tailnet only)".
  if [ -n "$(printf '%s\n' "$text" | awk -v port="$PUBLISH_PORT" '/^https:\/\// { inblock = ($0 ~ "^https://[^ ]*:" port "([^0-9]|$)") } inblock && /^https:\/\// && !/\(tailnet only\)/ { print }')" ]; then
    echo on
  else
    echo off
  fi
}

# Funnel isn't known to be off ($1: unknown or on; $2: when). The unit is disabled as well as stopped: a stop alone would let
# a reboot bring the page back while Funnel is on. A clean run enables it again (`enable --now`).
funnel_refuse() {
  echo "PAGE=failed"
  echo "FUNNEL=$1"
  echo "Funnel isn't known to be off for $PUBLISH_PORT here ($1) $2: the page is disabled and stopped, and is not started"
  systemctl --user disable --now "$PAGE_UNIT" >/dev/null 2>&1
  rm -f "$INCOMING_PAGE"
}

# Where the port points, read only: none, ours (only "/" proxying to unix:$1), other:<where> or unknown:<why>.
serve_mount_state() {
  local sock=$1 json
  command -v tailscale >/dev/null 2>&1 || { echo "unknown:tailscale isn't installed here"; return 0; }
  command -v python3 >/dev/null 2>&1 || { echo "unknown:python3 isn't installed here"; return 0; }
  json=$(timeout 8 tailscale serve status --json 2>/dev/null) || { echo "unknown:tailscale serve status failed"; return 0; }
  printf '%s' "$json" | python3 -c '
import json, sys
want, port = sys.argv[1], sys.argv[2]
try:
    config = json.load(sys.stdin) or {}
    web = config.get("Web") or {}
    hits = [v for k, v in web.items() if k.rsplit(":", 1)[-1] == port]
    tcp = (config.get("TCP") or {}).get(port)
    if not hits:
        if tcp is None:
            print("none")
        else:
            print("other:" + (("TCP " + tcp["TCPForward"]) if tcp.get("TCPForward") else "something that is not the page"))
        sys.exit()
    handlers = {}
    for v in hits:
        handlers.update((v or {}).get("Handlers") or {})
    if len(hits) > 1 or set(handlers) != {"/"}:
        print("other:other paths too (" + ", ".join(sorted(handlers)) + ")")
        sys.exit()
    proxy = (handlers["/"] or {}).get("Proxy")
    print("ours" if proxy == want else "other:" + (proxy or "not a proxy"))
except SystemExit:
    raise
except Exception:
    print("unknown:serve status is not readable")
' "unix:$sock" "$PUBLISH_PORT" 2>/dev/null || echo "unknown:serve status is not readable"
}

# Publishes the port to the socket $1 (ADR 0011's note has the rules). Prints PUBLISH=published|kept|conflict|refused|failed
# and, unless the first two, PUBLISHNOTE=<why>.
page_publish() {
  local sock=$1 funnel mount out rc
  command -v tailscale >/dev/null 2>&1 || { echo "PUBLISH=failed"; echo "PUBLISHNOTE=tailscale isn't installed here"; return 0; }
  funnel=$(funnel_state)
  if [ "$funnel" != off ]; then echo "PUBLISH=refused"; echo "PUBLISHNOTE=Funnel isn't known to be off for $PUBLISH_PORT ($funnel)"; return 0; fi
  mount=$(serve_mount_state "$sock")
  case "$mount" in
    ours) echo "PUBLISH=kept"; return 0 ;;
    none) ;;
    other:*) echo "PUBLISH=conflict"; echo "PUBLISHNOTE=port $PUBLISH_PORT already points at ${mount#other:}: left alone"; return 0 ;;
    *) echo "PUBLISH=failed"; echo "PUBLISHNOTE=${mount#unknown:}"; return 0 ;;
  esac
  out=$(timeout 25 tailscale serve --bg --https="$PUBLISH_PORT" "unix:$sock" 2>&1 </dev/null); rc=$?
  if [ "$rc" != 0 ]; then
    echo "PUBLISH=failed"
    if [ "$rc" = 124 ]; then echo "PUBLISHNOTE=tailscale serve didn't finish in 25 s (is serve enabled for this tailnet?)"
    else echo "PUBLISHNOTE=tailscale serve failed: $(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | head -n 1 | cut -c1-200)"; fi
    return 0
  fi
  # serve answering is not the port pointing at the socket.
  if [ "$(serve_mount_state "$sock")" = ours ]; then echo "PUBLISH=published"; else echo "PUBLISH=failed"; echo "PUBLISHNOTE=serve ran, but port $PUBLISH_PORT doesn't point at the page's socket"; fi
}

# Takes the port down where it points at the socket $1; $2=fresh also does so with Funnel not known off, for a mount this run
# just made. Prints UNPUBLISH=removed|none|left|failed and, for the last two, UNPUBLISHNOTE=<why>.
page_unpublish() {
  local sock=$1 fresh=${2:-} mount funnel out
  command -v tailscale >/dev/null 2>&1 || { echo "UNPUBLISH=none"; return 0; }
  mount=$(serve_mount_state "$sock")
  case "$mount" in
    none) echo "UNPUBLISH=none"; return 0 ;;
    other:*) echo "UNPUBLISH=left"; echo "UNPUBLISHNOTE=port $PUBLISH_PORT points at ${mount#other:}, not the page: left alone"; return 0 ;;
    unknown:*) echo "UNPUBLISH=failed"; echo "UNPUBLISHNOTE=${mount#unknown:}"; return 0 ;;
  esac
  funnel=$(funnel_state)
  if [ "$funnel" != off ] && [ "$fresh" != fresh ]; then echo "UNPUBLISH=left"; echo "UNPUBLISHNOTE=Funnel isn't known to be off for $PUBLISH_PORT ($funnel), so serve is not touched: tailscale serve --https=$PUBLISH_PORT off, once Funnel is off"; return 0; fi
  out=$(timeout 25 tailscale serve --https="$PUBLISH_PORT" off 2>&1 </dev/null) || { echo "UNPUBLISH=failed"; echo "UNPUBLISHNOTE=tailscale serve off failed: $(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | head -n 1 | cut -c1-200)"; return 0; }
  if [ "$(serve_mount_state "$sock")" = none ]; then echo "UNPUBLISH=removed"; else echo "UNPUBLISH=failed"; echo "UNPUBLISHNOTE=serve ran, but port $PUBLISH_PORT is still published"; fi
}

# Takes the page away: its port unpublished, the unit stopped and removed, then its files and socket. Never state/ or a session.
page_remove() {
  local unit_dir="$HOME/.config/systemd/user"
  adopt_runtime_dir
  page_unpublish "$HOME/.varnick/phone/page.sock"
  if [ -f "$unit_dir/$PAGE_UNIT" ]; then
    systemctl --user disable --now "$PAGE_UNIT" >/dev/null 2>&1
    rm -f "$unit_dir/$PAGE_UNIT"
    systemctl --user daemon-reload >/dev/null 2>&1
    echo "PAGE=removed"
  else
    echo "PAGE=off"
  fi
  rm -rf "$HOME/.varnick/PhonePage" "$HOME/.varnick/PhonePage.new" "$HOME/.varnick/PhonePage.old" "$HOME/.varnick/phone" "$INCOMING_PAGE"
}

# The Phone page: Bun, Funnel, the files, the unit, and the markers the near half judges. Needs the relay installed.
page_install() {
  local unit_dir="$HOME/.config/systemd/user" unit_file new_dir old_dir phone sock changed_tree=no changed_unit=no state funnel code answers=no published=
  unit_file="$unit_dir/$PAGE_UNIT"; new_dir="$ROOT/PhonePage.new"; old_dir="$ROOT/PhonePage.old"; phone="$ROOT/phone"; sock="$phone/page.sock"
  adopt_runtime_dir
  command -v systemctl >/dev/null 2>&1 || { echo "PAGE=failed"; echo "no systemd here"; return 0; }
  [ -f "$INCOMING_PAGE" ] || { echo "PAGE=failed"; echo "the page didn't arrive ($INCOMING_PAGE is missing)"; return 0; }
  echo "PAGEPORT=$PAGE_PORT"
  echo "PUBLISHPORT=$PUBLISH_PORT"
  echo "SOCKPATH=$sock"
  echo "BUNPIN=$BUN_VERSION"
  BUNOUT=$(ensure_bun); printf '%s\n' "$BUNOUT"
  [ "$(printf '%s\n' "$BUNOUT" | sed -n 's/^BUN=//p')" != missing ] || { echo "PAGE=failed"; return 0; }

  # Before anything is enabled, restarted or started: a page that may be on the public internet must not run, and one that
  # already runs is disabled and stopped.
  funnel=$(funnel_state)
  if [ "$funnel" != off ]; then funnel_refuse "$funnel" "before the start"; return 0; fi

  rm -rf "$new_dir"; mkdir -p "$new_dir"
  if ! tar -xzmf "$INCOMING_PAGE" -C "$new_dir" --strip-components=1; then echo "PAGE=failed"; echo "the page didn't unpack"; rm -rf "$new_dir"; return 0; fi
  rm -f "$INCOMING_PAGE"
  tree_hash() { (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}'); }
  if [ ! -d "$ROOT/PhonePage" ] || [ "$(tree_hash "$new_dir")" != "$(tree_hash "$ROOT/PhonePage")" ]; then changed_tree=yes; fi

  # 0700: Bun can't set a socket's mode, so the folder is what keeps others out (the server chmods the socket 0600 once bound).
  mkdir -p "$phone" "$unit_dir"; chmod 700 "$phone"
  # KillMode=process matters most: a session the page starts is created by the relay the server spawned, so its zmx
  # daemon is in this unit's cgroup, and any other mode would end every session when the unit stops or restarts.
  # RestartSec and no start limit: at boot tailscaled may be late, and the server exits until it answers.
  cat >"$unit_file.new" <<UNIT
[Unit]
Description=Varnick's phone page, behind tailscale serve on $PAGE_PORT
StartLimitIntervalSec=0

[Service]
WorkingDirectory=%h/.varnick/PhonePage
ExecStart=%h/.bun/bin/bun server.ts
Environment=VARNICK_PAGE_SOCKET=%h/.varnick/phone/page.sock
Environment=VARNICK_PAGE_PORT=$PAGE_PORT
Environment=VARNICK_PROXY_FOLDER=%h/.varnick/phone
Environment=VARNICK_PROXY_STATUS=%h/.varnick/state/proxy-status.json
Environment=VARNICK_RELAY=%h/.varnick/varnick-peer
Environment=VARNICK_DEVICES=%h/.varnick/state/devices.json
Environment=VARNICK_PUSH_FOLDER=%h/.varnick/phone
Environment=VARNICK_PANES_FOLDER=%h/.varnick/state/panes
Environment=VARNICK_PRESENCE_FOLDER=%h/.varnick/state/presence
Environment=VARNICK_TAILSCALE=/usr/bin/tailscale
KillMode=process
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
  if [ -f "$unit_file" ] && cmp -s "$unit_file.new" "$unit_file"; then rm -f "$unit_file.new"; else mv -f "$unit_file.new" "$unit_file"; changed_unit=yes; fi
  if [ "$changed_unit" = yes ]; then systemctl --user daemon-reload; fi

  if [ "$changed_tree" = yes ]; then
    rm -rf "$old_dir"
    if [ -d "$ROOT/PhonePage" ]; then mv "$ROOT/PhonePage" "$old_dir"; fi
    mv "$new_dir" "$ROOT/PhonePage"
  else
    rm -rf "$new_dir"
  fi

  if ! systemctl --user is-enabled "$PAGE_UNIT" >/dev/null 2>&1; then
    systemctl --user enable --now "$PAGE_UNIT" >/dev/null 2>&1
  elif [ "$changed_tree" = yes ] || [ "$changed_unit" = yes ]; then
    systemctl --user restart "$PAGE_UNIT" >/dev/null 2>&1
  elif ! systemctl --user is-active "$PAGE_UNIT" >/dev/null 2>&1; then
    systemctl --user start "$PAGE_UNIT" >/dev/null 2>&1
  fi
  rm -rf "$old_dir"
  # The socket answering, not only existing: any HTTP status will do, since the server refuses what it doesn't know.
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 --unix-socket "$sock" http://x/ 2>/dev/null)
    if [ -n "$code" ] && [ "$code" != 000 ]; then answers=yes; break; fi
    sleep 1
  done

  # Publish the port once the page answers: kept where it already points at the socket, put back where nothing is published,
  # never over somebody's own mount. Funnel is read first inside (page_publish), and again below.
  if [ "$answers" = yes ] && [ "$(systemctl --user is-active "$PAGE_UNIT" 2>/dev/null)" = active ]; then
    published=$(page_publish "$sock"); printf '%s\n' "$published"
  else
    echo "PUBLISH=skipped"; echo "PUBLISHNOTE=the page isn't answering on its socket"
  fi

  # Read again now that it runs: Funnel turned on in between stops it.
  funnel=$(funnel_state)
  if [ "$funnel" != off ]; then
    # A mount made in this run goes too: it was Varnick's to make, and Funnel just made it public.
    if [ "$(printf '%s\n' "$published" | sed -n 's/^PUBLISH=//p')" = published ]; then page_unpublish "$sock" fresh; fi
    funnel_refuse "$funnel" "after the start"; return 0
  fi
  echo "FUNNEL=$funnel"
  if [ "${PAGE:-auto}" = on ]; then echo "PAGE=installed"; else echo "PAGE=kept"; fi
  echo "PAGECHANGED=files:$changed_tree,unit:$changed_unit"
  state=$(systemctl --user is-active "$PAGE_UNIT" 2>/dev/null)
  if [ "$state" = active ]; then echo "UNIT=active"; else echo "UNIT=failed"; journalctl --user -u "$PAGE_UNIT" -n 8 --no-pager 2>/dev/null | cut -c1-200; fi
  echo "ANSWERS=$answers"
  echo "MAINPID=$(systemctl --user show -p MainPID --value "$PAGE_UNIT" 2>/dev/null)"
  echo "KILLMODE=$(systemctl --user show -p KillMode --value "$PAGE_UNIT" 2>/dev/null)"
  echo "LINGER=$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null | sed 's/^$/no/')"
  echo "OPERATOR=$(operator_state)"
  echo "SOCKET=$(stat -c %a "$sock" 2>/dev/null || echo missing)"
  echo "PHONEDIR=$(stat -c %a "$phone" 2>/dev/null || echo missing)"
  command -v tailscale >/dev/null 2>&1 && page_serve_markers "$sock"
  return 0
}

# The automations' timer: a user `.timer` that starts a `oneshot` `.service` running `varnick-peer tick` at the start of every minute, so nothing stays
# running between ticks. Not persistent: the slot function catches up by itself. KillMode=process is the line that matters, as the page's unit has it: a
# run's zmx daemon is created by the relay this service runs, so it lives in the service's cgroup, and any other mode would end every run when the
# tick exits (what was measured, and what it does not show, is in docs/agents/where-it-breaks.md, Automations). Prints AUTOMATIONS=on and the markers
# the near half judges, or AUTOMATIONS=failed.
automations_install() {
  local unit_dir="$HOME/.config/systemd/user" changed=no state
  adopt_runtime_dir
  command -v systemctl >/dev/null 2>&1 || { echo "AUTOMATIONS=failed"; echo "no systemd here"; return 0; }
  mkdir -p "$unit_dir"
  cat >"$unit_dir/$TICK_SERVICE.new" <<UNIT
[Unit]
Description=Varnick's automations: fires what is due on this host

[Service]
Type=oneshot
ExecStart=%h/.varnick/varnick-peer tick
KillMode=process
UNIT
  cat >"$unit_dir/$TICK_TIMER.new" <<UNIT
[Unit]
Description=Varnick's automations, once a minute

[Timer]
OnCalendar=*-*-* *:*:00
AccuracySec=1s
Persistent=false
Unit=$TICK_SERVICE

[Install]
WantedBy=timers.target
UNIT
  for unit in "$TICK_SERVICE" "$TICK_TIMER"; do
    if [ -f "$unit_dir/$unit" ] && cmp -s "$unit_dir/$unit.new" "$unit_dir/$unit"; then rm -f "$unit_dir/$unit.new"; else mv -f "$unit_dir/$unit.new" "$unit_dir/$unit"; changed=yes; fi
  done
  if [ "$changed" = yes ]; then systemctl --user daemon-reload; fi
  if ! systemctl --user is-enabled "$TICK_TIMER" >/dev/null 2>&1; then
    systemctl --user enable --now "$TICK_TIMER" >/dev/null 2>&1
  elif [ "$changed" = yes ]; then
    systemctl --user restart "$TICK_TIMER" >/dev/null 2>&1
  elif ! systemctl --user is-active "$TICK_TIMER" >/dev/null 2>&1; then
    systemctl --user start "$TICK_TIMER" >/dev/null 2>&1
  fi
  state=$(systemctl --user is-active "$TICK_TIMER" 2>/dev/null)
  if [ "$state" = active ]; then echo "AUTOMATIONS=on"; else echo "AUTOMATIONS=failed"; journalctl --user -u "$TICK_TIMER" -n 8 --no-pager 2>/dev/null | cut -c1-200; fi
  echo "TICKCHANGED=$changed"
  echo "TICKTIMER=${state:-unknown}"
  echo "TICKKILLMODE=$(systemctl --user show -p KillMode --value "$TICK_SERVICE" 2>/dev/null)"
  echo "TICKTYPE=$(systemctl --user show -p Type --value "$TICK_SERVICE" 2>/dev/null)"
  echo "TICKNEXT=$(systemctl --user show -p NextElapseUSecRealtime --value "$TICK_TIMER" 2>/dev/null)"
  echo "LINGER=$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null | sed 's/^$/no/')"
}

# Takes the timer away: stopped and removed, with its service. Never state/ (the automations and their Runs) or a session a tick started, which the
# service's KillMode=process leaves running.
automations_remove() {
  local unit_dir="$HOME/.config/systemd/user"
  adopt_runtime_dir
  if [ -f "$unit_dir/$TICK_TIMER" ] || [ -f "$unit_dir/$TICK_SERVICE" ]; then
    systemctl --user disable --now "$TICK_TIMER" >/dev/null 2>&1
    rm -f "$unit_dir/$TICK_TIMER" "$unit_dir/$TICK_SERVICE"
    systemctl --user daemon-reload >/dev/null 2>&1
  fi
  echo "AUTOMATIONS=off"
}

# Whether the user is Tailscale's operator, which `tailscale cert` (the port proxy's certificate, ADR 0035) needs: yes, no, or unknown when it
# can't be read. tailscaled run with TS_PERMIT_CERT_UID is another way and is not visible from here, so no is a warning, not a failure.
operator_state() {
  command -v tailscale >/dev/null 2>&1 || { echo unknown; return; }
  timeout 8 tailscale debug prefs 2>/dev/null | python3 -c '
import json, sys
try:
    print("yes" if (json.load(sys.stdin) or {}).get("OperatorUser") == sys.argv[1] else "no")
except Exception:
    print("unknown")
' "$(id -un)" 2>/dev/null || echo unknown
}

# Where the tailnet's 8444 points and this host's name, read only.
page_serve_markers() {
  local sock=$1
  echo "HOSTDNS=$(tailnet_name)"
  echo "SERVE=$(timeout 8 tailscale serve status --json 2>/dev/null | python3 -c '
import json, sys
want, port = sys.argv[1], sys.argv[2]
hit = None
try:
    for k, v in ((json.load(sys.stdin) or {}).get("Web") or {}).items():
        if k.endswith(":" + port):
            for h in (v.get("Handlers") or {}).values():
                hit = h.get("Proxy", "") or "other"
except Exception:
    print("missing"); sys.exit()
print("missing" if hit is None else "socket" if hit == want else "elsewhere")
' "unix:$sock" "$PUBLISH_PORT" 2>/dev/null || echo missing)"
}

# Holds ~/.varnick/install.lock on descriptor 9 until this script ends, so two installs on one host (two Macs, say) never unpack into the
# same source folder or swap the same binary. Nothing started here outlives the script holding the descriptor: the page's unit is
# started by systemd. Prints LOCK=ok (free), waited, or none (no flock, as on a Mac); returns 1 with LOCK=busy after 15 minutes.
acquire_lock() {
  if [ "$(uname -s)" != Linux ] || ! command -v flock >/dev/null 2>&1; then echo "LOCK=none"; return 0; fi
  mkdir -p "$ROOT"
  exec 9>"$ROOT/install.lock"
  if flock -n 9; then echo "LOCK=ok"
  elif flock -w 900 9; then echo "LOCK=waited"
  else echo "LOCK=busy"; return 1
  fi
}

main() {
  ROOT="$HOME/.varnick"
  SRC="$ROOT/src"
  SWIFT="$HOME/.local/share/swiftly/bin/swift"
  LINK="$HOME/.local/bin/varnick-peer"
  # Pinned like the Makefile's macOS one: a release that changes zmx's protocol can't talk to daemons the
  # previous one started. The hash is the release's published .sha256 for the Linux x86_64 tarball.
  ZMX_VERSION=0.8.1
  ZMX_SHA256=dfd75720b942466f28870731cc86dbc07afa72fb8f3bd5eeb4ff707e4eecebe8
  ZMX_ASSET="zmx-$ZMX_VERSION-linux-x86_64.tar.gz"
  ZMX_URL="https://github.com/neurosnap/zmx/releases/download/v$ZMX_VERSION/$ZMX_ASSET"

  # A port that isn't digits would be a different mount than the one meant: stop before anything is done.
  case "$PUBLISH_PORT" in ''|*[!0-9]*) echo "PAGE=failed"; echo "PAGE_PUBLISH_PORT must be a port number (got '$PUBLISH_PORT')"; return 0 ;; esac

  # This run's own tarballs (no suffix without RUN), which are gone at exit however it ends.
  case "${RUN:-}" in *[!A-Za-z0-9]*) echo "RUN takes letters and digits only (got '$RUN')"; return 0 ;; esac
  INCOMING="$ROOT/incoming${RUN:+-$RUN}.tar.gz"
  INCOMING_PAGE="$ROOT/incoming-page${RUN:+-$RUN}.tar.gz"
  if [ -n "${RUN:-}" ]; then trap 'rm -f "$INCOMING" "$INCOMING_PAGE"' EXIT; fi
  # Short-lived, removed at the rename's Cleanup (docs/problems/name-taken-by-another-launcher/options/01-rename-on-one-branch-and-let-varnick-move-its-own-data.md): a host whose install root still has the old name is moved by
  # hand first (the headless host's cutover in the same option). An install here would put a second
  # relay, with a new id, beside the old one. Nothing is changed: what the near half shipped is removed, and ~/.varnick goes again
  # if shipping made it and it holds nothing. The lock isn't taken, since taking it makes ~/.varnick.
  if [ "${ACTION:-install}" = install ] && [ -e "$HOME/.launchy" ]; then
    rm -f "$INCOMING" "$INCOMING_PAGE"
    rmdir "$ROOT" 2>/dev/null || true
    echo "OLDROOT=present"
    echo "$HOME/.launchy exists: this host still runs Launchy's relay. Moving it to ~/.varnick is the user's step, the headless host's cutover (docs/problems/name-taken-by-another-launcher/options/01-rename-on-one-branch-and-let-varnick-move-its-own-data.md). Nothing was changed. An agent must stop here and report this to the user"
    return 0
  fi
  acquire_lock || return 0
  # Tarballs a run left when its far half never ran (the ssh failed after shipping, the session was killed). Another run's that is a day
  # old is nobody's: a live run's is newer, and holds the lock before it reads it.
  find "$ROOT" -maxdepth 1 -name 'incoming*-*.tar.gz' ! -name "$(basename "$INCOMING")" ! -name "$(basename "$INCOMING_PAGE")" -mmin +1440 -exec rm -f {} + 2>/dev/null || true

  if [ "${ACTION:-install}" = uninstall ]; then
    automations_remove >/dev/null
    page_remove
    # Only a link that points at this install's binary is ours to remove.
    if [ "$(readlink "$LINK" 2>/dev/null)" = "$ROOT/varnick-peer" ]; then rm -f "$LINK"; fi
    rm -f "$ROOT/varnick-peer" "$ROOT/varnick-peer.new" "$ROOT/build" "$ROOT/problems"
    rm -f "$INCOMING" "$INCOMING_PAGE"
    rm -rf "$SRC"
    echo "REMOVED=$ROOT/varnick-peer, $LINK, $ROOT/build, $ROOT/problems, the automations' timer and its service, and $SRC"
    echo "KEPT=$ROOT/state, $ROOT/config.json, $ROOT/zmx, Bun and any running session"
    return 0
  fi

  : "${COMMIT:?}"
  mkdir -p "$ROOT"
  if [ "$(uname -m)" != x86_64 ]; then echo "SWIFT=unsupported"; echo "only x86_64 Linux is supported (zmx's release here); this machine is $(uname -m)"; return 0; fi
  [ -f "$INCOMING" ] || { echo "SHIPPED=missing"; return 0; }

  # 2. Swift. Installed once by hand: swiftly's own system packages need sudo.
  if [ ! -x "$SWIFT" ]; then
    echo "SWIFT=missing"
    echo "Swift isn't at $SWIFT: install swiftly and Swift by hand, from swift.org's Linux install page, then run this again."
    return 0
  fi
  echo "SWIFT=$("$SWIFT" --version 2>&1 | sed -n 's/^Swift version \([^ ]*\).*/\1/p' | head -n 1)"

  # 3. libstdc++-14-dev: clang picks GCC 14, and a static Swift stdlib links -lstdc++ from its folder.
  if dpkg -s libstdc++-14-dev >/dev/null 2>&1; then
    echo "STDCXX=ok"
  else
    if ! sudo -n apt-get install -y libstdc++-14-dev >"$ROOT/apt.log" 2>&1; then
      sudo -n apt-get update >>"$ROOT/apt.log" 2>&1
      sudo -n apt-get install -y libstdc++-14-dev >>"$ROOT/apt.log" 2>&1
    fi
    if dpkg -s libstdc++-14-dev >/dev/null 2>&1; then
      echo "STDCXX=ok"
    else
      echo "STDCXX=failed"
      tail -n 5 "$ROOT/apt.log"
    fi
    rm -f "$ROOT/apt.log"
  fi

  # 4. Build. The package replaces Package.swift and Sources. Files take the time of the unpacking (-m),
  # not the commit's, so an older commit still rebuilds: every install builds the whole package.
  mkdir -p "$SRC"
  rm -rf "$SRC/Sources" "$SRC/Package.swift"
  if ! tar -xzmf "$INCOMING" -C "$SRC" --strip-components=2; then echo "BUILT=failed"; echo "the package didn't unpack"; return 0; fi
  rm -f "$INCOMING"
  LOG=$(mktemp "${TMPDIR:-/tmp}/varnick-peer-build.XXXXXX")
  # --build-system native: Swift Build, the default, leaves Foundation's static libraries out of a static
  # stdlib link (the spike); native is one flag, where naming each library with -Xlinker -l shifts between
  # Swift releases.
  build() { (cd "$SRC" && PATH="$(dirname "$SWIFT"):$PATH" "$SWIFT" build -c release --static-swift-stdlib --build-system native "$@") >"$LOG" 2>&1; }
  BIN="$SRC/.build/release/varnick-peer"
  # Gone first, so a build that fails can't leave an older one to be taken for the new.
  rm -f "$BIN"
  FALLBACK=none
  build; BUILD_STATUS=$?
  if [ "$BUILD_STATUS" != 0 ]; then
    # The spike's verified fix when the 14 dev package isn't enough: GCC 13's folder holds a libstdc++.
    FALLBACK=gcc13
    build -Xlinker -L/usr/lib/gcc/x86_64-linux-gnu/13; BUILD_STATUS=$?
  fi
  if [ "$BUILD_STATUS" != 0 ] || [ ! -x "$BIN" ]; then
    echo "BUILT=failed"
    tail -n 25 "$LOG"
    rm -f "$LOG"
    return 0
  fi
  rm -f "$LOG"
  echo "BUILT=ok"
  echo "FALLBACK=$FALLBACK"
  echo "SIZE=$(wc -c <"$BIN" | tr -d ' ')"

  # 5. Check what it links and that it runs, before it replaces the working one.
  LINKED=$(ldd "$BIN" 2>&1 | grep -c "$HOME/.local/share/swiftly")
  if [ "$LINKED" = 0 ]; then echo "STATIC=ok"; else echo "STATIC=failed"; ldd "$BIN" | grep "$HOME/.local/share/swiftly" | head -n 5; fi
  if "$BIN" --peer x 2>&1 | grep -q '"ok":false'; then RUNS=ok; else RUNS=failed; fi
  echo "RUNS=$RUNS"

  # 6. Swap. Beside the running binary and renamed over it, so a running relay keeps its file. Only a
  # binary that is static and runs replaces the working one.
  if [ "$LINKED" != 0 ] || [ "$RUNS" != ok ]; then echo "SWAPPED=skipped"; return 0; fi
  cp -f "$BIN" "$ROOT/varnick-peer.new" && chmod 755 "$ROOT/varnick-peer.new" && mv -f "$ROOT/varnick-peer.new" "$ROOT/varnick-peer" || { echo "SWAPPED=failed"; return 0; }
  mkdir -p "$(dirname "$LINK")"
  ln -sfn "$ROOT/varnick-peer" "$LINK"
  echo "SWAPPED=ok"

  # 7. zmx, the relay's own, renamed into place.
  HAVE=$("$ROOT/zmx" version 2>/dev/null | head -n 1 | awk '{print $NF}')
  if [ "$HAVE" != "$ZMX_VERSION" ]; then
    FETCH=$(mktemp -d "$ROOT/.zmx-fetch.XXXXXX")
    if curl -fsSL --retry 2 -o "$FETCH/$ZMX_ASSET" "$ZMX_URL" \
       && [ "$(sha256sum "$FETCH/$ZMX_ASSET" | awk '{print $1}')" = "$ZMX_SHA256" ] \
       && tar -xzf "$FETCH/$ZMX_ASSET" -C "$FETCH" zmx; then
      chmod 755 "$FETCH/zmx" && mv -f "$FETCH/zmx" "$ROOT/zmx"
    else
      echo "zmx $ZMX_VERSION couldn't be fetched and checked against its pinned SHA-256"
    fi
    rm -rf "$FETCH"
    HAVE=$("$ROOT/zmx" version 2>/dev/null | head -n 1 | awk '{print $NF}')
  fi
  echo "ZMX=${HAVE:-missing}"

  # 8. Config (only if missing), identity (only if missing, by `init`) and the build.
  if [ -f "$ROOT/config.json" ]; then
    echo "CONFIG=kept"
  else
    if [ -n "${NAME:-}" ]; then printf '{"name": "%s"}\n' "$NAME" >"$ROOT/config.json"; else printf '{}\n' >"$ROOT/config.json"; fi
    echo "CONFIG=written"
  fi
  echo "ID=$("$ROOT/varnick-peer" init)"
  printf '%s\n' "$COMMIT" >"$ROOT/build.new" && mv -f "$ROOT/build.new" "$ROOT/build"
  echo "BUILD=$COMMIT"
  # The problems file (ADR 0020): its existence is the switch the relay reads. Written by rename, so a relay never reads half a write.
  case "${PROBLEMS:-auto}" in
    on) printf 'on\n' >"$ROOT/problems.new" && mv -f "$ROOT/problems.new" "$ROOT/problems" ;;
    off) rm -f "$ROOT/problems" ;;
  esac
  if [ -e "$ROOT/problems" ]; then echo "PROBLEMS=on"; else echo "PROBLEMS=off"; fi
  # The automations' timer, after the relay it runs: installed, kept up to date where it is installed, or removed.
  case "${AUTOMATIONS:-auto}" in
    off) automations_remove ;;
    on) automations_install ;;
    *)
      if [ -f "$HOME/.config/systemd/user/$TICK_TIMER" ]; then automations_install; else echo "AUTOMATIONS=off"; fi ;;
  esac

  # 9. The Phone page (ADR 0011), after the relay it runs on: installed, kept up to date where it is installed, or removed.
  case "${PAGE:-auto}" in
    remove) page_remove ;;
    on) page_install ;;
    *)
      if [ -f "$HOME/.config/systemd/user/$PAGE_UNIT" ]; then page_install; else rm -f "$INCOMING_PAGE"; echo "PAGE=off"; fi ;;
  esac
}

main </dev/null
