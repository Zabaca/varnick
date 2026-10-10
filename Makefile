# SIGN_IDENTITY (optional): what to sign with, set here or in the git-ignored Makefile.local; scripts/signing-identity.sh has the rules.
-include Makefile.local
export SIGN_IDENTITY

LABEL := com.zabaca.varnick
PLIST := $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG := $(HOME)/Library/Logs/Varnick.log
DOMAIN = gui/$(shell id -u)

# MLX's Metal shaders, prebuilt: `swift build` can't compile them without Xcode. Taken from the
# mlx-metal wheel matching the MLX core inside mlx-swift (pinned in Package.swift); update together.
MLX_METAL_WHEEL := https://files.pythonhosted.org/packages/f7/ab/ba1952908c5d2a5070cf1cfbfea0161c4751ea62299e2776819810917483/mlx_metal-0.32.2-py3-none-macosx_14_0_arm64.whl
MLX_METAL_SHA256 := 3825fff379dbc107dd3413e564a06caeaa24819910ec49c0439e454c06a1b9b8
METALLIB := .build/release/mlx.metallib
# Named after the wheel, so a new pin fetches again instead of keeping a mismatched metallib.
METAL_STAMP := .build/release/mlx.metallib.$(MLX_METAL_SHA256)

# zmx keeps pane processes alive across Varnick restarts (ADR 0004). Pinned to one release: a
# release that changes its IPC protocol can't talk to daemons the previous one started, so bumping
# this ends running sessions once. Varnick only ever uses the copy next to its binary.
ZMX_VERSION := 0.8.1
ZMX_SHA256 := 1d86b1c9fba47fa707a6f0e976b20510b07c1c26d0ed010b9414b2a2c5e6beef
ZMX_URL := https://github.com/neurosnap/zmx/releases/download/v$(ZMX_VERSION)/zmx-$(ZMX_VERSION)-macos-aarch64.tar.gz
ZMX_STAMP := .build/release/zmx.$(ZMX_SHA256)
# What the build signs with: a certificate's SHA-1, or - for ad hoc. `build` resolves it once and hands it to the sub-makes.
SIGN_ID ?= -
# Which signature the zmx in place carries, so a new identity (or the first one) re-signs it without fetching again.
# Named by the first 8 characters of the SHA-1, never the whole of it: make prints a failed target's name in its "*** [target] Error" line.
SIGN_SHORT = $(if $(filter -,$(SIGN_ID)),adhoc,$(shell printf '%.8s' '$(SIGN_ID)'))
ZMX_SIGNER_STAMP = .build/release/zmx.signer.$(SIGN_SHORT)
# The secure timestamp is left out: only notarization needs it, and it calls Apple on every build.
ZMX_CODESIGN = $(if $(filter -,$(SIGN_ID)),codesign -f -s -,codesign -f -s "$(SIGN_ID)" -o runtime --timestamp=none)
# Matches Varnick's binary by its path only, as scripts/restart.sh does: an unanchored pattern also
# matches any process whose arguments mention the path, such as a pane started with a prompt that
# names it, which would kill a session that should survive.
VARNICK_PROCESS := ^($(shell pwd -P)/)?\.build/release/Varnick$$

# Short-lived, removed at the rename's Cleanup (docs/problems/name-taken-by-another-launcher/options/01-rename-on-one-branch-and-let-varnick-move-its-own-data.md): a Mac still on
# Launchy crosses by hand, from a terminal outside the app. Its binary is matched by this checkout's absolute path only (the LaunchAgent's
# form): a Launchy started by `make run` has the relative form `.build/release/Launchy`, which would match from any checkout, so a Varnick
# worktree's stop or restart would end the Mac's Launchy. The old LaunchAgent is booted out and its plist removed by install and
# uninstall, and `cutover-check` keeps them, and `make run`, to the checkout Launchy ran from.
LAUNCHY_PROCESS := ^$(shell pwd -P)/\.build/release/Launchy$$
# Ends every guard's `error:` line: the cutover is the user's, and an agent that reads one must not act on it.
CUTOVER_NOTE := The cutover is the user's step, done from Terminal.app (docs/problems/name-taken-by-another-launcher/options/01-rename-on-one-branch-and-let-varnick-move-its-own-data.md, \"Cutover: each Mac\"). An agent must stop here and report this to the user.
OLD_LABEL := com.zabaca.launchy
OLD_PLIST := $(HOME)/Library/LaunchAgents/$(OLD_LABEL).plist

SKILL_LINK := $(HOME)/.claude/skills/custom-apps
SKILL_TARGET := $(CURDIR)/.claude/skills/custom-apps

# The Phone page's server (ADR 0011): Varnick clones this copy next to its binary, as it does zmx, at each launch (the
# launch snapshot), so edits in a checkout reach a running server only through a build and a restart. The tests and
# their fixtures stay behind, and a file left unchanged is left alone, so building twice changes nothing.
PHONE_PAGE_DIR := .build/release/PhonePage

# The line `BuildStamp` reads, written as the last step of `make build` (where-it-breaks, Peers, has the rules).
BUILD_STAMP := .build/release/build-stamp
# The last good binary, kept while a build runs so a failed one can put it back.
GOOD_COPY := .build/release/Varnick.good

.PHONY: build build-steps cutover-check run stop install uninstall skill-link skill-unlink clean phone-page build-stamp sign-varnick sign-zmx

# The metallib goes next to the binary, where MLX looks for it. After swift build, which
# creates .build/release. Signing Varnick binds the Info.plist the linker embeds (Package.swift):
# the linker's own ad-hoc signature leaves it unbound, and macOS needs it bound to find the
# microphone and system audio usage strings. SwiftPM doesn't relink when only Info.plist
# changed, so a newer Info.plist removes the binary first. Varnick and zmx are signed with the identity
# scripts/signing-identity.sh chooses; a build that can't choose or sign fails rather than signing ad hoc.
#
# A build that fails leaves the last good binary where it was, so a restart never starts a relinked, unsigned one: when the
# build stamp is no older than the binary (a good build), a clone of the binary is put back if any step fails. A build that was
# interrupted (^C, a kill) left its clone behind: the next build puts it back first, before it takes a new one.
#
# Short-lived, removed at the rename's Cleanup (docs/problems/name-taken-by-another-launcher/options/01-rename-on-one-branch-and-let-varnick-move-its-own-data.md): it fails first when this checkout still holds Launchy's binary or its good copy,
# which stops Upgrade, Upgrade all and `make run` on a Mac that hasn't been cut over. A worktree's build folder starts empty.
build:
	@if [ -e .build/release/Launchy ] || [ -e .build/release/Launchy.good ]; then \
	  echo "error: this checkout still has Launchy's binary in .build/release, so this Mac hasn't been cut over to Varnick. $(CUTOVER_NOTE)" >&2; exit 1; fi
	@if [ -f $(GOOD_COPY) ]; then mv -f $(GOOD_COPY) .build/release/Varnick; echo "restored the build an interrupted one left"; fi; if [ -f .build/release/Varnick ] && [ -f $(BUILD_STAMP) ] && [ ! .build/release/Varnick -nt $(BUILD_STAMP) ]; then cp -c .build/release/Varnick $(GOOD_COPY); fi
	@[ ! Info.plist -nt .build/release/Varnick ] || rm -f .build/release/Varnick
	@$(MAKE) --no-print-directory build-steps || { \
	  if [ -f $(GOOD_COPY) ]; then mv -f $(GOOD_COPY) .build/release/Varnick; echo "restored the previous build"; fi; \
	  exit 1; }
	@rm -f $(GOOD_COPY)

build-steps:
	swift build -c release
	@test -f $(METAL_STAMP) || $(MAKE) $(METAL_STAMP)
	@id=$$(scripts/signing-identity.sh) || exit 1; \
	  if [ "$$id" = - ] && [ "$$SIGN_IDENTITY" != - ] && ls .build/release/zmx.signer.* 2>/dev/null | grep -qv 'zmx\.signer\.adhoc$$'; then \
	    echo "error: signing: this checkout has been signed with an identity, and none is usable now. Fix the keychain, or set SIGN_IDENTITY=- to sign ad hoc on purpose." >&2; exit 1; fi; \
	  $(MAKE) --no-print-directory sign-varnick sign-zmx SIGN_ID="$$id"
	@$(MAKE) --no-print-directory phone-page
	@$(MAKE) --no-print-directory build-stamp

# Without an identity, ad hoc and nothing else, as before. With one: the hardened runtime and the one entitlement in
# Varnick.entitlements. Either way the signature is verified strictly. The certificate's SHA-1 stays out of the log (@).
sign-varnick:
ifeq ($(SIGN_ID),-)
	codesign -f -s - -i $(LABEL) .build/release/Varnick
else
	@codesign -f -s "$(SIGN_ID)" -o runtime --timestamp=none --entitlements Varnick.entitlements -i $(LABEL) .build/release/Varnick
endif
	@codesign --verify --strict .build/release/Varnick

sign-zmx:
ifneq ($(SIGN_ID),-)
	@if [ ! -f $(ZMX_SIGNER_STAMP) ] && [ -f .build/release/zmx.signer.$(SIGN_ID) ]; then mv -f .build/release/zmx.signer.$(SIGN_ID) $(ZMX_SIGNER_STAMP); fi
endif
	@test -f $(ZMX_STAMP) || $(MAKE) --no-print-directory $(ZMX_STAMP)
	@test -f $(ZMX_SIGNER_STAMP) || $(MAKE) --no-print-directory $(ZMX_SIGNER_STAMP)

phone-page:
	mkdir -p $(PHONE_PAGE_DIR)
	rsync -a --delete --exclude '.DS_Store' --exclude '*.test.ts' --exclude 'fixtures/' PhonePage/ $(PHONE_PAGE_DIR)/

# Moved into place by rename, so a reader never sees half a line. `git diff HEAD` looks at tracked files only:
# untracked ones don't make a build dirty. Outside a git checkout there is no commit to name, so there is no stamp.
build-stamp:
	@if commit=$$(git rev-parse HEAD 2>/dev/null); then \
	  dirty=0; git diff --quiet HEAD -- || dirty=1; \
	  branch=$$(git branch --show-current); \
	  line="commit=$$commit dirty=$$dirty$${branch:+ branch=$$branch} time=$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
	  echo "$$line" > $(BUILD_STAMP).tmp && mv -f $(BUILD_STAMP).tmp $(BUILD_STAMP) && echo "stamp: $$line"; \
	else \
	  rm -f $(BUILD_STAMP); echo "not a git checkout: no build stamp"; \
	fi

$(METAL_STAMP):
	curl -sfL -o .build/mlx-metal.whl $(MLX_METAL_WHEEL)
	echo "$(MLX_METAL_SHA256)  .build/mlx-metal.whl" | shasum -a 256 -c -
	unzip -o -j -q .build/mlx-metal.whl mlx/lib/mlx.metallib -d $(dir $@)
	rm -f .build/mlx-metal.whl .build/release/mlx.metallib.*
	@touch $@

# Signed in the fetch folder and moved into place by rename, so daemons still running the old zmx keep their file
# (signing it in place would change pages under them). Without an identity it keeps the linker's own signature.
$(ZMX_STAMP):
	rm -rf .build/zmx-fetch && mkdir -p .build/zmx-fetch
	curl -sfL -o .build/zmx-fetch/zmx.tar.gz $(ZMX_URL)
	echo "$(ZMX_SHA256)  .build/zmx-fetch/zmx.tar.gz" | shasum -a 256 -c -
	tar -xzf .build/zmx-fetch/zmx.tar.gz -C .build/zmx-fetch zmx
	@if [ "$(SIGN_ID)" != - ]; then $(ZMX_CODESIGN) .build/zmx-fetch/zmx && codesign --verify --strict .build/zmx-fetch/zmx; fi
	mv -f .build/zmx-fetch/zmx .build/release/zmx
	rm -rf .build/zmx-fetch .build/release/zmx.*
	@touch $@ $(ZMX_SIGNER_STAMP)

# The same release signed by another identity (or by the first one): its protocol is unchanged, so running sessions
# survive, unlike a pin bump (ADR 0004). A Mac that has never signed zmx and still has no identity has nothing to do.
$(ZMX_SIGNER_STAMP):
	@if [ "$(SIGN_ID)" = - ] && ! ls .build/release/zmx.signer.* >/dev/null 2>&1; then \
	  echo "zmx: keeps the signature it was fetched with"; \
	else \
	  rm -rf .build/zmx-fetch && mkdir -p .build/zmx-fetch && cp .build/release/zmx .build/zmx-fetch/zmx && \
	  $(ZMX_CODESIGN) .build/zmx-fetch/zmx && codesign --verify --strict .build/zmx-fetch/zmx && \
	  mv -f .build/zmx-fetch/zmx .build/release/zmx && rm -rf .build/zmx-fetch; \
	fi
	rm -f .build/release/zmx.signer.*
	@touch $@

# Short-lived, removed at the rename's Cleanup (docs/problems/name-taken-by-another-launcher/options/01-rename-on-one-branch-and-let-varnick-move-its-own-data.md):
# run, install and uninstall touch the Mac's running Launchy and its LaunchAgent, so while Launchy's support folder exists and Varnick's
# doesn't they work only in the checkout Launchy ran from, which holds db/launchy.sqlite. A worktree's build passes the build guard.
cutover-check:
	@support="$(HOME)/Library/Application Support"; \
	if [ -e "$$support/Launchy" ] && [ ! -e "$$support/Varnick" ] && [ ! -f db/launchy.sqlite ]; then \
	  echo "error: this Mac still runs Launchy and this isn't the checkout it ran from (no db/launchy.sqlite). Nothing was changed. $(CUTOVER_NOTE)" >&2; exit 1; fi

# The restart runs in its own session so it outlives a Varnick session that ran `make run`.
run: cutover-check build
	nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' scripts/restart.sh >/dev/null 2>&1 &

stop:
	-@pkill -a -f '$(VARNICK_PROCESS)' || true
	-@pkill -a -f '$(LAUNCHY_PROCESS)' || true

# Start at login via a LaunchAgent that runs this repo's release build (so `make build`
# updates what the next login starts). Also starts it now, and links the custom-apps skill into
# the user's skills so agents in any project find it (linked, not copied: one source). The link is
# made only when the path is free or already ours; anything else there is left alone.
install: cutover-check build stop
	mkdir -p $(dir $(PLIST)) $(dir $(LOG))
	sed -e 's|@LABEL@|$(LABEL)|g' -e 's|@ROOT@|$(CURDIR)|g' -e 's|@LOG@|$(LOG)|g' \
	    scripts/varnick.plist.in > $(PLIST)
	plutil -lint $(PLIST)
	-@launchctl bootout $(DOMAIN)/$(OLD_LABEL) 2>/dev/null || true
	rm -f $(OLD_PLIST)
	-@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	launchctl bootstrap $(DOMAIN) $(PLIST)
	@$(MAKE) --no-print-directory skill-link

uninstall: cutover-check
	-@launchctl bootout $(DOMAIN)/$(OLD_LABEL) 2>/dev/null || true
	rm -f $(OLD_PLIST)
	-@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	rm -f $(PLIST)
	@$(MAKE) --no-print-directory skill-unlink

# "Ours" is a link whose target is the path `skill-link` writes. A dangling link or a file or folder
# of the user's own is not ours. Neither target fails when it leaves the entry alone.
skill-link:
	@if [ ! -e "$(SKILL_LINK)" ] && [ ! -L "$(SKILL_LINK)" ]; then \
	  mkdir -p "$(dir $(SKILL_LINK))" && ln -sfn "$(SKILL_TARGET)" "$(SKILL_LINK)" && echo "linked $(SKILL_LINK)"; \
	elif [ "$$(readlink "$(SKILL_LINK)")" = "$(SKILL_TARGET)" ]; then \
	  echo "$(SKILL_LINK) already links here"; \
	else \
	  echo "left $(SKILL_LINK) alone: it is not a link to $(SKILL_TARGET)"; \
	fi

skill-unlink:
	@if [ -L "$(SKILL_LINK)" ] && [ "$$(readlink "$(SKILL_LINK)")" = "$(SKILL_TARGET)" ]; then \
	  rm -f "$(SKILL_LINK)" && echo "removed $(SKILL_LINK)"; \
	elif [ -e "$(SKILL_LINK)" ] || [ -L "$(SKILL_LINK)" ]; then \
	  echo "left $(SKILL_LINK) alone: it is not a link to $(SKILL_TARGET)"; \
	fi

# Leaves db/: it holds history Chrome may have already dropped.
clean:
	rm -rf .build
