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
# The text helper (ADR 0029) runs on a plain Bun, pinned like zmx and fetched by `make build`: the same binary builds agent.js and ships
# in Varnick.app. A Bun release is the build tool and the runtime both, so bumping this changes what runs on the user's Mac.
BUN_VERSION := 1.3.14
BUN_SHA256 := d8b96221828ad6f97ac7ac0ab7e95872341af763001e8803e8267652c2652620
BUN_URL := https://github.com/oven-sh/bun/releases/download/bun-v$(BUN_VERSION)/bun-darwin-aarch64.zip
BUN_STAMP := .build/release/bun.$(BUN_SHA256)
BUN_IDENTIFIER := $(LABEL).bun
# The helper's source and its build: TextHelper/ is bundled to one file with `bun build` (no --compile), and the reminders filter of
# @zabaca/agent is copied beside it as real files, since `claude` can't read a path inside a compiled binary.
TEXT_HELPER_DIR := TextHelper
AGENT_JS := .build/release/agent.js
AGENT_MODS := .build/release/mods

# What the build signs with: a certificate's SHA-1, or - for ad hoc. `build` resolves it once and hands it to the sub-makes.
SIGN_ID ?= -
# Which signature the zmx in place carries, so a new identity (or the first one) re-signs it without fetching again.
# Named by the first 8 characters of the SHA-1, never the whole of it: make prints a failed target's name in its "*** [target] Error" line.
SIGN_SHORT = $(if $(filter -,$(SIGN_ID)),adhoc,$(shell printf '%.8s' '$(SIGN_ID)'))
ZMX_SIGNER_STAMP = .build/release/zmx.signer.$(SIGN_SHORT)
# The secure timestamp is left out: only notarization needs it, and it calls Apple on every build.
ZMX_CODESIGN = $(if $(filter -,$(SIGN_ID)),codesign -f -s -,codesign -f -s "$(SIGN_ID)" -o runtime --timestamp=none)
# bun carries Bun.entitlements: allow-jit and nothing else. Ad hoc, it keeps the signature it was fetched with, as zmx does.
BUN_SIGNER_STAMP = .build/release/bun.signer.$(SIGN_SHORT)
BUN_CODESIGN = $(if $(filter -,$(SIGN_ID)),codesign -f -s -,codesign -f -s "$(SIGN_ID)" -o runtime --timestamp=none --entitlements Bun.entitlements -i $(BUN_IDENTIFIER))
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

# The catalog (option 01 of custom-apps-must-be-written-first): apps/, copied next to the binary as the Phone page is, and into
# the bundle's Resources by app-bundle, both through scripts/copy-catalog.sh: tracked files only, so a release carries committed
# files, and never node_modules or .DS_Store. Settings > Apps reads it from the resource folder, so the app and a checkout build
# share one path.
APPS_CATALOG_DIR := .build/release/apps

# The line `BuildStamp` reads, written as the last step of `make build` (where-it-breaks, Peers, has the rules).
BUILD_STAMP := .build/release/build-stamp
# The last good binary, kept while a build runs so a failed one can put it back.
GOOD_COPY := .build/release/Varnick.good

.PHONY: build build-steps cutover-check check-apps check-mcp apps-catalog cutover-confirm run stop install uninstall skill-link skill-unlink clean phone-page build-stamp sign-varnick sign-zmx sign-bun text-helper

# The metallib goes beside the binary in .build/release (the resource folder, which a bundle's Contents/Resources replaces; see
# ResourceFolder). After swift build, which creates .build/release. Signing Varnick binds the Info.plist the linker embeds (Package.swift):
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
	  $(MAKE) --no-print-directory sign-varnick sign-zmx sign-bun SIGN_ID="$$id"
	@$(MAKE) --no-print-directory text-helper
	@$(MAKE) --no-print-directory phone-page
	@$(MAKE) --no-print-directory apps-catalog
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

sign-bun:
ifneq ($(SIGN_ID),-)
	@if [ ! -f $(BUN_SIGNER_STAMP) ] && [ -f .build/release/bun.signer.$(SIGN_ID) ]; then mv -f .build/release/bun.signer.$(SIGN_ID) $(BUN_SIGNER_STAMP); fi
endif
	@test -f $(BUN_STAMP) || $(MAKE) --no-print-directory $(BUN_STAMP)
	@test -f $(BUN_SIGNER_STAMP) || $(MAKE) --no-print-directory $(BUN_SIGNER_STAMP)

# agent.js and the reminders filter next to it. The packages install from the committed lockfile (frozen), without the Agent SDK's
# optional native Claude Code packages, which the helper never uses (it drives the user's own claude). Each file is written by rename,
# so a request during a build never reads half a file.
text-helper: $(AGENT_JS) $(AGENT_MODS)/reminders

$(AGENT_JS): $(TEXT_HELPER_DIR)/agent.ts $(TEXT_HELPER_DIR)/package.json $(TEXT_HELPER_DIR)/bun.lock $(BUN_STAMP)
	.build/release/bun install --cwd $(TEXT_HELPER_DIR) --frozen-lockfile --omit optional
	.build/release/bun build $(TEXT_HELPER_DIR)/agent.ts --target=bun --outfile=$@.tmp
	mv -f $@.tmp $@

# Only the filter's own files: its tests and tsconfig stay behind.
$(AGENT_MODS)/reminders: $(AGENT_JS)
	mkdir -p $(AGENT_MODS)/reminders
	rsync -a --delete --exclude 'tests/' --exclude 'tsconfig.json' $(TEXT_HELPER_DIR)/node_modules/@zabaca/agent/mods/reminders/ $(AGENT_MODS)/reminders/
	@touch $@

phone-page:
	mkdir -p $(PHONE_PAGE_DIR)
	rsync -a --delete --exclude '.DS_Store' --exclude '*.test.ts' --exclude 'fixtures/' PhonePage/ $(PHONE_PAGE_DIR)/

apps-catalog:
	scripts/copy-catalog.sh $(CURDIR)/$(APPS_CATALOG_DIR)

# Offline checks of every catalog entry (scripts/check-apps.sh; the rules are in CONTRIBUTING). `app-guard` runs it, so a release
# never ships a broken entry. `make check-apps APPS=<folder>` checks another folder.
APPS ?= apps
check-apps:
	@scripts/check-apps.sh $(APPS)

# What `Varnick --mcp` lists for each set of tools, with no running Varnick (scripts/check-mcp.sh). After `make build`;
# `make check-mcp BIN=<binary>` checks another build.
BIN ?= .build/release/Varnick
check-mcp:
	@scripts/check-mcp.sh $(BIN)

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

# bun is fetched, checked against its pinned hash and signed in the fetch folder, then moved into place by rename, as zmx is. Without an
# identity it keeps the signature Oven gave it.
$(BUN_STAMP):
	rm -rf .build/bun-fetch && mkdir -p .build/bun-fetch
	curl -sfL -o .build/bun-fetch/bun.zip $(BUN_URL)
	echo "$(BUN_SHA256)  .build/bun-fetch/bun.zip" | shasum -a 256 -c -
	unzip -q -j .build/bun-fetch/bun.zip bun-darwin-aarch64/bun -d .build/bun-fetch
	chmod +x .build/bun-fetch/bun
	@if [ "$(SIGN_ID)" != - ]; then $(BUN_CODESIGN) .build/bun-fetch/bun && codesign --verify --strict .build/bun-fetch/bun; fi
	mv -f .build/bun-fetch/bun .build/release/bun
	rm -rf .build/bun-fetch .build/release/bun.*
	@touch $@ $(BUN_SIGNER_STAMP)

# The same release signed by another identity (or by the first one): nothing is fetched again.
$(BUN_SIGNER_STAMP):
	@if [ "$(SIGN_ID)" = - ] && ! ls .build/release/bun.signer.* >/dev/null 2>&1; then \
	  echo "bun: keeps the signature it was fetched with"; \
	else \
	  rm -rf .build/bun-fetch && mkdir -p .build/bun-fetch && cp .build/release/bun .build/bun-fetch/bun && \
	  $(BUN_CODESIGN) .build/bun-fetch/bun && codesign --verify --strict .build/bun-fetch/bun && \
	  mv -f .build/bun-fetch/bun .build/release/bun && rm -rf .build/bun-fetch; \
	fi
	rm -f .build/release/bun.signer.*
	@touch $@

# Short-lived, removed at the rename's Cleanup (docs/problems/name-taken-by-another-launcher/options/01-rename-on-one-branch-and-let-varnick-move-its-own-data.md):
# run, install and uninstall touch the Mac's running Launchy and its LaunchAgent, so while our Launchy's support folder exists (an unrelated
# launcher is also called Launchy: scripts/old-launchy-folder.sh tests the folder's contents) and Varnick's doesn't they work only in the
# checkout Launchy ran from, which holds db/launchy.sqlite. A worktree's build passes the build guard.
cutover-check:
	@support="$(HOME)/Library/Application Support"; \
	if scripts/old-launchy-folder.sh "$$support/Launchy" && [ ! -e "$$support/Varnick" ] && [ ! -f db/launchy.sqlite ]; then \
	  echo "error: this Mac still runs Launchy and this isn't the checkout it ran from (no db/launchy.sqlite). Nothing was changed. $(CUTOVER_NOTE)" >&2; exit 1; fi

# The opposite case: in the checkout Launchy ran from, `make clean` removes the binary that holds the build guard, and `make install` would
# then install Varnick's LaunchAgent for the next login without the cutover. Both refuse there until the user passes CUTOVER=1 from Terminal.app.
cutover-confirm:
	@support="$(HOME)/Library/Application Support"; \
	if scripts/old-launchy-folder.sh "$$support/Launchy" && [ ! -e "$$support/Varnick" ] && [ -f db/launchy.sqlite ] && [ "$(CUTOVER)" != 1 ]; then \
	  echo "error: this Mac still runs Launchy from this checkout, and this would lift its build guard or install Varnick before the cutover. Nothing was changed. $(CUTOVER_NOTE)" >&2; exit 1; fi

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
install: cutover-check cutover-confirm build stop
	mkdir -p $(dir $(PLIST)) $(dir $(LOG))
	scripts/varnick-plist.sh $(LABEL) $(CURDIR) $(LOG) > $(PLIST)
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
clean: cutover-confirm
	rm -rf .build

# `make app` (the maintainer's, on the Mac that holds the signing identity and the notary credentials): Varnick.app, signed inside
# out, notarized, stapled and zipped as .build/app/Varnick.zip, then the disk image Varnick.dmg made from that same app (`app-image`);
# the user attaches both to a GitHub release by hand (docs/releasing.md; ADR 0025, ADR 0026). Nothing is uploaded but to the notary service.
# The notary credential is one of two, on the command line or else in the git-ignored Makefile.local, and like the identity stays out of
# every tracked file: NOTARY_PROFILE names the keychain profile `notarytool` reads (which can't be read while the screen is locked), or
# NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER give an App Store Connect API key file (which can). A key set wins over a profile.
# CHECK_BUILD=1 lets a build off main run every step but the zip. `app-bundle` stops before anything is sent, so the signed bundle can be checked first.
export NOTARY_PROFILE NOTARY_KEY NOTARY_KEY_ID NOTARY_ISSUER
# The one place that turns the credential into notarytool arguments, for every submit and log. The values stay in the environment, and
# every recipe line that uses this starts with @, so make never prints them.
NOTARY_AUTH = $(if $(NOTARY_KEY),--key "$$NOTARY_KEY" --key-id "$$NOTARY_KEY_ID" --issuer "$$NOTARY_ISSUER",--keychain-profile "$$NOTARY_PROFILE")
APP_DIR := .build/app
APP := $(APP_DIR)/Varnick.app
APP_ZIP := $(APP_DIR)/Varnick.zip
APP_DMG := $(APP_DIR)/Varnick.dmg
# A check build's image has another name, so it never looks publishable.
APP_DMG_CHECK := $(APP_DIR)/Varnick-check.dmg
# What dmgbuild writes: a published image is moved to Varnick.dmg only once it has passed every step.
DMG_BUILD = $(if $(filter 1,$(CHECK_BUILD)),$(APP_DMG_CHECK),$(APP_DIR)/Varnick-building.dmg)
# dmgbuild writes the image window's layout (the .DS_Store) itself, with no Finder window, so it runs with the screen locked. Nothing of
# it ships. Pinned with its two libraries, all pure Python and MIT; uvx runs it (the badge-icon extra, which needs PyObjC, is not used).
DMGBUILD := uvx --from dmgbuild==1.6.7 --with ds_store==1.3.3 --with mac_alias==2.2.3 dmgbuild
# Both numbers come from the commit's time in UTC: 2026.10.9 and 20261009.1954. The short one has no leading zeros.
APP_COMMIT_TIME = $(shell git show -s --format=%ct HEAD)
APP_SHORT_VERSION = $(shell date -u -r $(APP_COMMIT_TIME) +%Y.%m.%d | sed 's/\.0*\([0-9]\)/.\1/g')
APP_BUILD_VERSION = $(shell date -u -r $(APP_COMMIT_TIME) +%Y%m%d.%H%M)

.PHONY: app app-bundle app-guard app-image

# Every refusal is one `error:` line, and none reaches the build. The identity's script says its own reasons.
app-guard:
	@$(MAKE) --no-print-directory check-apps
	@if ! git diff --quiet HEAD --; then echo "error: app: the checkout has changes to tracked files; a published build matches a commit" >&2; exit 1; fi
	@scripts/signing-identity.sh --developer-id >/dev/null || { echo "error: app: no Developer ID Application identity to sign with (an app is never ad hoc); fix SIGN_IDENTITY in Makefile.local" >&2; exit 1; }
	@command -v uvx >/dev/null || { echo "error: app: no uvx on the PATH; the disk image is built with dmgbuild, which uvx runs (uv: https://docs.astral.sh/uv/)" >&2; exit 1; }
	@if [ -n "$$NOTARY_KEY$$NOTARY_KEY_ID$$NOTARY_ISSUER" ]; then \
	  if [ -z "$$NOTARY_KEY" ] || [ -z "$$NOTARY_KEY_ID" ] || [ -z "$$NOTARY_ISSUER" ]; then echo "error: app: the notary API key is incomplete; NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER go together (Makefile.local.example)" >&2; exit 1; fi; \
	  if [ ! -f "$$NOTARY_KEY" ] || [ ! -r "$$NOTARY_KEY" ]; then echo "error: app: NOTARY_KEY isn't a readable file" >&2; exit 1; fi; \
	elif [ -z "$$NOTARY_PROFILE" ]; then echo "error: app: no notary credential; set NOTARY_PROFILE, or NOTARY_KEY with NOTARY_KEY_ID and NOTARY_ISSUER, in Makefile.local or on the command line (Makefile.local.example)" >&2; exit 1; fi
	@if [ "$(CHECK_BUILD)" != 1 ]; then \
	  if [ "$$(git branch --show-current)" != main ] || ! git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then \
	    echo "error: app: a published build comes from main, with HEAD in origin/main as last fetched; CHECK_BUILD=1 builds anything else, without the zip" >&2; exit 1; fi; fi

# Signing is inside out, never --deep: zmx and bun first (bun with its own identifier and entitlements), then the bundle with its
# entitlements and identifier. All carry the secure timestamp that only notarization needs. Lines that name the identity start with @.
app-bundle: app-guard
	@$(MAKE) --no-print-directory build
	rm -rf $(APP) $(APP_DIR)/Varnick.iconset
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp -c .build/release/Varnick $(APP)/Contents/MacOS/Varnick
	cp -c .build/release/zmx $(APP)/Contents/MacOS/zmx
	mkdir -p $(APP)/Contents/Helpers
	cp -c .build/release/bun $(APP)/Contents/Helpers/bun
	cp -c .build/release/agent.js $(APP)/Contents/Resources/agent.js
	rsync -a .build/release/mods/ $(APP)/Contents/Resources/mods/ --exclude '.DS_Store'
	cp -c .build/release/mlx.metallib $(APP)/Contents/Resources/mlx.metallib
	rsync -a PhonePage/ $(APP)/Contents/Resources/PhonePage/ --exclude '.DS_Store' --exclude '*.test.ts' --exclude 'fixtures/'
	scripts/copy-catalog.sh $(CURDIR)/$(APP)/Contents/Resources/apps
	cp .build/release/build-stamp $(APP)/Contents/Resources/build-stamp
	mkdir -p $(APP)/Contents/Resources/skills
	cp -RL .claude/skills/custom-apps $(APP)/Contents/Resources/skills/custom-apps
	find $(APP) -name .DS_Store -delete
	cp LICENSE THIRD_PARTY_NOTICES.md $(APP)/Contents/Resources/
	cp -R LICENSES $(APP)/Contents/Resources/LICENSES
	swiftc -O -parse-as-library scripts/make-icon.swift Sources/Varnick/FoldMark.swift -o $(APP_DIR)/make-icon
	$(APP_DIR)/make-icon $(APP_DIR)/Varnick.iconset
	iconutil -c icns -o $(APP)/Contents/Resources/Varnick.icns $(APP_DIR)/Varnick.iconset
	cp Info.plist $(APP)/Contents/Info.plist
	plutil -insert CFBundleExecutable -string Varnick $(APP)/Contents/Info.plist
	plutil -insert CFBundlePackageType -string APPL $(APP)/Contents/Info.plist
	plutil -insert CFBundleIconFile -string Varnick $(APP)/Contents/Info.plist
	plutil -insert CFBundleShortVersionString -string $(APP_SHORT_VERSION) $(APP)/Contents/Info.plist
	plutil -insert CFBundleVersion -string $(APP_BUILD_VERSION) $(APP)/Contents/Info.plist
	plutil -insert LSMinimumSystemVersion -string 14.0 $(APP)/Contents/Info.plist
	plutil -insert LSUIElement -bool YES $(APP)/Contents/Info.plist
	plutil -insert VarnickCommit -string "$$(git rev-parse HEAD)" $(APP)/Contents/Info.plist
	plutil -lint $(APP)/Contents/Info.plist
	@id=$$(scripts/signing-identity.sh --developer-id 2>/dev/null) || { echo "error: app: no Developer ID Application identity" >&2; exit 1; }; \
	  codesign -f -s "$$id" -o runtime --timestamp $(APP)/Contents/MacOS/zmx || exit 1; \
	  codesign -f -s "$$id" -o runtime --timestamp --entitlements Bun.entitlements -i $(BUN_IDENTIFIER) $(APP)/Contents/Helpers/bun || exit 1; \
	  codesign -f -s "$$id" -o runtime --timestamp --entitlements Varnick.entitlements -i $(LABEL) $(APP) || exit 1
	codesign --verify --deep --strict --verbose=2 $(APP)

# The notary service answers in minutes, the first time perhaps longer. Anything but Accepted prints its log and fails.
app: app-bundle
	@rm -f $(APP_DIR)/notarize.zip
	ditto -c -k --keepParent $(APP) $(APP_DIR)/notarize.zip
	@echo "submitting to the notary service, and waiting for its answer"
	@xcrun notarytool submit $(APP_DIR)/notarize.zip $(NOTARY_AUTH) --wait > $(APP_DIR)/notary.out 2>&1; \
	  rm -f $(APP_DIR)/notarize.zip; cat $(APP_DIR)/notary.out; \
	  id=$$(sed -n 's/^ *id: *//p' $(APP_DIR)/notary.out | head -1); status=$$(sed -n 's/^ *status: *//p' $(APP_DIR)/notary.out | tail -1); \
	  if [ "$$status" != Accepted ]; then \
	    echo "error: app: the notary service didn't accept the app (status: $${status:-none}); what notarytool said is above" >&2; \
	    if [ -n "$$id" ]; then xcrun notarytool log "$$id" $(NOTARY_AUTH); fi; exit 1; fi
	xcrun stapler staple $(APP)
	xcrun stapler validate $(APP)
	@spctl -a -vv -t exec $(APP) 2>&1 | tee $(APP_DIR)/spctl.out; grep -q 'source=Notarized Developer ID' $(APP_DIR)/spctl.out || { echo "error: app: Gatekeeper doesn't accept the app as notarized" >&2; exit 1; }
	@if [ "$(CHECK_BUILD)" = 1 ]; then echo "CHECK_BUILD=1: no zip written"; else \
	  rm -f $(APP_ZIP) $(APP_ZIP).sha256 && ditto -c -k --keepParent $(APP) $(APP_ZIP) && \
	  (cd $(APP_DIR) && shasum -a 256 Varnick.zip > Varnick.zip.sha256 && cat Varnick.zip.sha256); fi
	@$(MAKE) --no-print-directory app-image FROM_APP=1
	@if [ "$(CHECK_BUILD)" != 1 ]; then \
	  echo "version $$(plutil -extract CFBundleShortVersionString raw $(APP)/Contents/Info.plist) ($$(plutil -extract CFBundleVersion raw $(APP)/Contents/Info.plist)), commit $$(plutil -extract VarnickCommit raw $(APP)/Contents/Info.plist)" && \
	  echo "the published build: $(APP_DMG) and $(APP_ZIP)"; fi

# The disk image, made from the app already in $(APP_DIR) (stapled, when `app` runs it): Varnick, an arrow and a shortcut to Applications
# on a background drawn from the Fold, laid out by scripts/dmg-settings.json (its paths are relative to the checkout, where make runs).
# Signed with the Developer ID and the secure timestamp, no hardened runtime (that is for code), then notarized, stapled and assessed as
# a disk image. CHECK_BUILD=1 stops before the notary service and writes Varnick-check.dmg, never Varnick.dmg: the first image
# notarization is the first real `make app`. Publishing runs only from `app` (FROM_APP=1, internal) or after app-guard's checks, and
# only on an app with a stapled ticket, so it never notarizes whatever .build/app happens to hold.
app-image: $(if $(filter 1,$(FROM_APP)),,$(if $(filter 1,$(CHECK_BUILD)),,app-guard))
	@test -d $(APP) || { echo "error: app-image: no $(APP); make app-bundle builds it" >&2; exit 1; }
	@if [ "$(CHECK_BUILD)" != 1 ]; then xcrun stapler validate $(APP) >/dev/null 2>&1 || { echo "error: app-image: $(APP) has no stapled notarization ticket; make app makes the published image" >&2; exit 1; }; fi
	rm -rf $(APP_DIR)/dmg-background
	swiftc -O -parse-as-library scripts/make-dmg-background.swift Sources/Varnick/FoldMark.swift -o $(APP_DIR)/make-dmg-background
	$(APP_DIR)/make-dmg-background $(APP_DIR)/dmg-background
	rm -f $(DMG_BUILD) $(DMG_BUILD).sha256
	@if [ "$(CHECK_BUILD)" != 1 ]; then rm -f $(APP_DMG) $(APP_DMG).sha256; fi
	$(DMGBUILD) -s scripts/dmg-settings.json Varnick $(DMG_BUILD)
	@id=$$(scripts/signing-identity.sh --developer-id 2>/dev/null) || { echo "error: app-image: no Developer ID Application identity" >&2; exit 1; }; \
	  codesign -f -s "$$id" --timestamp $(DMG_BUILD) || exit 1
	codesign --verify --verbose=2 $(DMG_BUILD)
	hdiutil verify $(DMG_BUILD)
	@if [ "$(CHECK_BUILD)" = 1 ]; then echo "CHECK_BUILD=1: $(DMG_BUILD) is signed and verified, not sent to the notary service; no Varnick.dmg written"; else \
	  echo "submitting the disk image to the notary service, and waiting for its answer"; \
	  xcrun notarytool submit $(DMG_BUILD) $(NOTARY_AUTH) --wait > $(APP_DIR)/notary-dmg.out 2>&1; \
	  cat $(APP_DIR)/notary-dmg.out; \
	  id=$$(sed -n 's/^ *id: *//p' $(APP_DIR)/notary-dmg.out | head -1); status=$$(sed -n 's/^ *status: *//p' $(APP_DIR)/notary-dmg.out | tail -1); \
	  if [ "$$status" != Accepted ]; then \
	    echo "error: app-image: the notary service didn't accept the disk image (status: $${status:-none}); what notarytool said is above" >&2; \
	    if [ -n "$$id" ]; then xcrun notarytool log "$$id" $(NOTARY_AUTH); fi; exit 1; fi; \
	  xcrun stapler staple $(DMG_BUILD) && xcrun stapler validate $(DMG_BUILD) || exit 1; \
	  spctl -a -vv -t open --context context:primary-signature $(DMG_BUILD) 2>&1 | tee $(APP_DIR)/spctl-dmg.out; \
	  grep -q 'source=Notarized Developer ID' $(APP_DIR)/spctl-dmg.out || { echo "error: app-image: Gatekeeper doesn't accept the disk image as notarized" >&2; exit 1; }; \
	  mv -f $(DMG_BUILD) $(APP_DMG) && (cd $(APP_DIR) && shasum -a 256 Varnick.dmg > Varnick.dmg.sha256 && cat Varnick.dmg.sha256); fi
