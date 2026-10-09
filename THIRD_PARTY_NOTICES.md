# Third-party notices

Launchy's own code is under the Apache License 2.0 (see `LICENSE`). This file lists the other
software and models it contains, builds with, downloads or is derived from, with the licence of each
as read from its source. Every entry says what it was read from, on 2026-10-07; an entry marked
"not verified" names what could not be read.

Contents:

1. [Code in this repository](#code-in-this-repository)
2. [What the build downloads](#what-the-build-downloads)
3. [What the Linux installer downloads](#what-the-linux-installer-downloads)
4. [What Launchy downloads at runtime](#what-launchy-downloads-at-runtime)
5. [Swift packages](#swift-packages)
6. [Licence texts](#licence-texts)

## Code in this repository

### Laya and laya-mlx (Apache-2.0)

`Sources/Launchy/LayaModel.swift` is a translation to Swift and MLX of the decision model in Laya and
of laya-mlx's `model.py`, as its header says. Launchy ships no Laya or laya-mlx weights: the relevance
checkpoint it can load is one the user imports (see the README).

| Project | Source | Licence | NOTICE file |
|---|---|---|---|
| Laya, by Convai Innovations and contributors | `NandhaKishorM/laya` on GitHub | Apache-2.0 (its `LICENSE`) | None at the repository root (checked: the root listing has none, and `NOTICE` answers 404) |
| laya-mlx, an independent MLX port (not an official Convai Innovations release) | `mizorewww/laya-mlx` on GitHub; its weights are at `aac6fef/laya-mlx` on Hugging Face | Apache-2.0 (its `LICENSE`) | Yes, reproduced below |

laya-mlx's `NOTICE`, verbatim:

```
laya-mlx
Copyright 2026 laya-mlx contributors

This product includes software derived from Laya:
https://github.com/NandhaKishorM/laya
Copyright Convai Innovations and Laya contributors. Licensed under Apache-2.0.
Original upstream source revision: 573e5b62696ba441230cd6be71d593331b5d23af

The token sequence construction, question rendering, confidence calculation,
presets, email utilities and language router are adapted from Laya.
The neural network is reimplemented using Apple's MLX, following Laya's
DecisionModel and the ModernBERT architecture in Hugging Face Transformers.
Model weights are downloaded separately from Convai Innovations on Hugging Face;
they are not included in this repository.

Selected inference, input validation, routing, language and email fixes adapted
from upstream revision 4aa6761 (v0.3.23 source tree). This is a selective sync,
not an implementation of every upstream API. The neural architecture parity
reference remains 573e5b62696ba441230cd6be71d593331b5d23af.
```

Launchy's translation covers one question type (the `noul` question) and changes the code's shape
(Swift, MLX, a fixed row format). It is a derivative of that work under the Apache License 2.0.
Which of the two projects each part of `LayaModel.swift` follows was not checked line by line.

### xterm.js and its fit addon (MIT)

`PhonePage/vendor/` holds `@xterm/xterm` 6.0.0 and `@xterm/addon-fit` 0.11.0, unmodified, with their
licence files beside them (`LICENSE-xterm`, `LICENSE-addon-fit`). `PhonePage/vendor/VERSIONS` records
their provenance and digests.

| File | Copyright lines in the licence file |
|---|---|
| `LICENSE-xterm` | The xterm.js authors (2017-2019); SourceLair Private Company (2014-2016); Christopher Jeffrey (2012-2013) |
| `LICENSE-addon-fit` | The xterm.js authors (2019) |

## What the build downloads

`make build` fetches two prebuilt files, each checked against a pinned SHA-256 in the `Makefile`. They
are not stored in this repository.

| Component | Where from | Licence | Read from |
|---|---|---|---|
| `mlx.metallib`, MLX's compiled Metal shaders, from the `mlx-metal` 0.32.2 wheel (`MLX_METAL_WHEEL`) | The wheel on PyPI | MIT, Copyright 2023 Apple Inc. | The wheel's `METADATA` (`License: MIT`) and its `licenses/LICENSE`, after checking the wheel's SHA-256 against the Makefile's |
| zmx 0.8.1, macOS arm64 (`ZMX_URL`) | `neurosnap/zmx` release `v0.8.1` | MIT, Copyright 2025 Eric Bower | `LICENSE` at the `v0.8.1` tag; the tarball's SHA-256 matches the Makefile's |

The same wheel carries Apple's metal-cpp headers (Apache-2.0, `mlx/include/metal_cpp/LICENSE.txt`). They are
headers, not part of `mlx.metallib`.

zmx 0.8.1 builds on libghostty from `ghostty-org/ghostty` (named in its `build.zig.zon`), whose
`LICENSE` at that revision is MIT, Copyright 2024 Mitchell Hashimoto and Ghostty contributors. The
licences of the other code libghostty and zmx are built with were not verified.

## What the Linux installer downloads

`scripts/install-peer.sh` builds the headless relay on the headless host from this repository's
`Packages/LaunchyPeer`, which depends on nothing outside Foundation and POSIX. It also downloads, each
checked against a pinned SHA-256 in `scripts/remote/install-peer.sh`:

| Component | Licence | Read from |
|---|---|---|
| zmx 0.8.1, Linux x86_64 | MIT, Copyright 2025 Eric Bower | `LICENSE` at the `v0.8.1` tag; the tarball's SHA-256 matches the installer's |
| Bun 1.3.14, Linux x64, only with `--page` and only when the host has none | MIT for Bun itself, with statically linked libraries under their own licences, JavaScriptCore among them under the LGPL | `LICENSE.md` at the `bun-v1.3.14` tag; the libraries and their terms are listed there |

The Swift toolchain the installer builds with is installed by the user, and the relay is linked with
the Swift standard library statically. That library's licence was not read from its source and is not
listed here (not verified).

## What Launchy downloads at runtime

Launchy downloads these models from Hugging Face on the user's request (Settings), at the pinned revisions
in `Sources/Launchy/Embedder.swift` and `Sources/Launchy/TextGenerator.swift`. They are not stored in this
repository. The terms are those of each model card at the pinned revision.

| Model | Used for | Pinned revision | Licence on the card at that revision |
|---|---|---|---|
| `mlx-community/Qwen3-Embedding-0.6B-8bit`, an MLX conversion of `Qwen/Qwen3-Embedding-0.6B` | Semantic search | `407ad2329cd30702720aafe83f74a1ba30fdfbca` | `license: apache-2.0` |
| `mlx-community/gemma-4-e2b-it-4bit`, an MLX conversion of `google/gemma-4-E2B-it` | Hey Launchy's answers | `238767527555cb75a05732a84dff5d6ba0dd6809` | `license: gemma` |

Notes on the two:

- The Qwen base model, `Qwen/Qwen3-Embedding-0.6B`, is also tagged `apache-2.0` on Hugging Face (read at
  the repository's current revision, not a pinned one).
- For Gemma, the converted repository's card says `license: gemma`, and its repository holds no licence
  file. Google's `google/gemma-4-E2B-it` card (read at its current revision) says `apache-2.0` and links to
  Google's Gemma 4 licence page, which presents the Apache License 2.0. The two differ, and which terms
  bind a download of the converted copy was not settled. Read both before relying on either.

## Swift packages

Resolved versions are those of `Package.resolved`, whose licences were read from the checked-out
sources under `.build/checkouts/` after `make build`. `Packages/LaunchyPeer` is Launchy's own package and
has no dependencies. Whether each resolved package reaches the linked binary was not checked; the direct
dependencies, from `Package.swift`, are marked.

| Package | Version | Licence | Copyright line in its licence file | Direct |
|---|---|---|---|---|
| SwiftTerm | 1.20.0 | MIT | Miguel de Icaza (2019-2026); the xterm.js authors (2017-2019); SourceLair Private Company (2014-2016); Christopher Jeffrey (2012-2013) | yes |
| mlx-swift | 0.32.3 | MIT | ml-explore (2023) | yes |
| mlx-swift-lm | 3.32.3 | MIT | ml-explore (2024) | yes |
| swift-transformers | 1.3.4 | Apache-2.0 | Hugging Face SAS (2022) | yes |
| swift-huggingface | 0.12.0 | Apache-2.0 | Hugging Face SAS (2025) | |
| swift-jinja | 2.5.1 | Apache-2.0 | Hugging Face SAS (2022) | |
| EventSource | 1.5.1 | MIT | Mattt (2025) | |
| yyjson | 0.12.0 | MIT | YaoYuan (2020) | |
| swift-argument-parser | 1.8.2 | Apache-2.0 with the Runtime Library Exception | none in the file | |
| swift-asn1 | 1.7.3 | Apache-2.0; has a NOTICE file | none in the file | |
| swift-collections | 1.7.1 | Apache-2.0 | none in the file | |
| swift-crypto | 4.5.2 | Apache-2.0; has a NOTICE file | none in the file | |
| swift-numerics | 1.1.1 | Apache-2.0 | none in the file | |
| swift-syntax | 603.0.2 | Apache-2.0 | none in the file | |

Of these, swift-syntax comes from mlx-swift-lm's macros (`#huggingFaceTokenizerLoader`) and runs at build
time; it is not linked into Launchy (inferred from mlx-swift-lm's `Package.swift`, where it is the macro target's dependency).

mlx-swift compiles these projects into its `Cmlx` target, from `Source/Cmlx/` in its checkout:

| Project | Licence | Copyright line |
|---|---|---|
| MLX (`mlx`) | MIT | Apple Inc. (2023) |
| mlx-c | MIT | ml-explore (2023) |
| {fmt} 12.1.0 | MIT, with an optional exception for embedded object form | Victor Zverovich and {fmt} contributors (2012-present) |
| nlohmann/json 3.11.3 | MIT | Niels Lohmann (2013-2022) |
| metal-cpp (Apple) | Apache-2.0 | Apple Inc. (2024) |

### NOTICE files

The Apache-licensed packages that carry a `NOTICE` file are swift-asn1 and swift-crypto. Their notices say:

- swift-asn1: "Copyright 2022 The SwiftASN1 Project", licensed under the Apache License 2.0
  (https://www.apache.org/licenses/LICENSE-2.0). It contains derivations of scripts from SwiftNIO
  (https://github.com/apple/swift-nio) and Swift OpenAPI Generator
  (https://github.com/apple/swift-openapi-generator), both Apache-2.0.
- swift-crypto: "Copyright 2019 The SwiftCrypto Project", licensed under the Apache License 2.0. It
  contains test vectors from Google's wycheproof project (Apache-2.0, https://github.com/google/wycheproof)
  and a derivation of files from SwiftNIO (Apache-2.0).

The full `NOTICE` files are in those packages' sources and are not reproduced here.

## Licence texts

The Apache License 2.0 is in `LICENSE`. The MIT licence, which the components above share apart from their
copyright lines, reads:

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

Each component's own licence file, with its exact wording, is in its source or release.
