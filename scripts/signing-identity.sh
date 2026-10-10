#!/bin/sh
# Chooses what `make build` signs Varnick and zmx with. Prints a certificate's SHA-1 on stdout, or "-" for an ad-hoc
# signature; the reasons go to stderr, and a choice it can't make fails (exit 1) so the build never signs under another
# identity than the user meant.
#
# The identity is $SIGN_IDENTITY when set (`make` takes it from the git-ignored Makefile.local): a certificate's SHA-1, any
# part of its name, or "-" to sign ad hoc on purpose. Unset, it is the only "Developer ID Application" identity in the
# keychain; with none, "-", unless the keychain lists one that has gone invalid, which fails. A named identity that isn't in the keychain fails rather than falling back, and so do two or
# more matches. Nothing here or in the Makefile names an identity: this stays fit to publish.
#
# $SIGNING_IDENTITIES_FROM and $SIGNING_ALL_IDENTITIES_FROM (files of `security find-identity -p codesigning` output, with
# and without -v) stand in for the keychain.
list() {
  if [ -n "$SIGNING_IDENTITIES_FROM" ]; then cat "$SIGNING_IDENTITIES_FROM"; else security find-identity -v -p codesigning; fi
}
list_all() {
  if [ -n "$SIGNING_ALL_IDENTITIES_FROM" ]; then cat "$SIGNING_ALL_IDENTITIES_FROM"; else security find-identity -p codesigning; fi
}
found=$(list) || { echo "error: signing: can't read the keychain's identities" >&2; exit 1; }
# "<sha1> <name>", once per certificate (one in two keychains is listed twice).
identities=$(printf '%s\n' "$found" | sed -n 's/^ *[0-9]*) \([0-9A-Fa-f]\{40\}\) "\(.*\)".*$/\1 \2/p' | sort -u -k1,1)

# The name is shown only to a person at a terminal; a build run unattended logs the start of the hash.
say() {
  if [ -t 2 ]; then echo "signing with: $2" >&2; else echo "signing with identity $(printf '%.8s' "$1")" >&2; fi
}

wanted=$SIGN_IDENTITY
if [ "$wanted" = "-" ]; then
  echo "signing ad hoc: SIGN_IDENTITY is -" >&2
  echo "-"
  exit 0
fi
if [ -n "$wanted" ]; then
  matches=$(printf '%s\n' "$identities" | grep -i -F -- "$wanted" | grep -v '^$')
  what="named in SIGN_IDENTITY"
else
  matches=$(printf '%s\n' "$identities" | grep -E '^[0-9A-Fa-f]{40} Developer ID Application' | grep -v '^$')
  what="a Developer ID Application identity"
  if [ -z "$matches" ]; then
    # None valid. One that is there but invalid (expired, revoked, its intermediate missing) must not turn into an ad-hoc
    # build behind the user's back, which would void every privacy grant.
    everything=$(list_all) || { echo "error: signing: can't read the keychain's identities" >&2; exit 1; }
    if printf '%s\n' "$everything" | grep -q -E '^ *[0-9]+\) [0-9A-Fa-f]{40} "Developer ID Application'; then
      echo "error: signing: the keychain has a Developer ID Application identity that isn't valid (expired, revoked, or its intermediate certificate is missing; see security find-identity -p codesigning). Fix it, or set SIGN_IDENTITY=- to sign ad hoc on purpose." >&2
      exit 1
    fi
    echo "signing ad hoc: no Developer ID Application identity in the keychain" >&2
    echo "-"
    exit 0
  fi
fi
count=$(printf '%s\n' "$matches" | grep -c .)
if [ "$count" -eq 0 ]; then
  echo "error: signing: no valid identity $what in the keychain. Fix SIGN_IDENTITY (Makefile.local), or set it to - to sign ad hoc." >&2
  exit 1
fi
if [ "$count" -gt 1 ]; then
  echo "error: signing: $count identities match, and signing must not guess. Name one in SIGN_IDENTITY (Makefile.local) by its SHA-1:" >&2
  printf '%s\n' "$matches" | cut -d' ' -f1 | sed 's/^/  /' >&2
  exit 1
fi
hash=${matches%% *}
say "$hash" "${matches#* }"
echo "$hash"
