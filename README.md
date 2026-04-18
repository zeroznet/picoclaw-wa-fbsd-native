# picoclaw-wa-fbsd-native

FreeBSD-oriented PicoClaw builder for native WhatsApp support.

## What it does

- clones or updates upstream PicoClaw from GitHub
- runs `go mod download` and `go mod verify`
- runs `go generate ./...`
- builds a FreeBSD amd64 binary with native WhatsApp support
- smoke-tests the binary
- verifies that `whatsmeow` is linked into the build

## One-line install

Generic:

```sh
curl -fsSL https://raw.githubusercontent.com/zeroznet/picoclaw-wa-fbsd-native/main/picoclaw-wa-fbsd-native.sh | sh
```

FreeBSD without `curl`:

```sh
fetch -q -o - https://raw.githubusercontent.com/zeroznet/picoclaw-wa-fbsd-native/main/picoclaw-wa-fbsd-native.sh | sh
```

With auto-install of missing deps:

```sh
fetch -q -o - https://raw.githubusercontent.com/zeroznet/picoclaw-wa-fbsd-native/main/picoclaw-wa-fbsd-native.sh | sh -s -- --install-deps
```

With `goolm` disabled (not recommended on current upstream):

```sh
fetch -q -o - https://raw.githubusercontent.com/zeroznet/picoclaw-wa-fbsd-native/main/picoclaw-wa-fbsd-native.sh | sh -s -- --without-goolm
```

## Local usage

Run with default options:

```sh
./picoclaw-wa-fbsd-native.sh
```

Install missing deps and build:

```sh
./picoclaw-wa-fbsd-native.sh --install-deps
```

Apply the local silent_processing patch (forward-port of upstream PR #2127) on top of latest upstream and build:

```sh
./picoclaw-wa-fbsd-native.sh --apply-pr-2127
```

Build a specific upstream ref into a custom directory:

```sh
./picoclaw-wa-fbsd-native.sh --dir ~/src/picoclaw --ref main
```

## Options

- `--dir PATH` - clone/update upstream PicoClaw into PATH (default: `~/src/picoclaw`)
- `--ref NAME` - upstream ref (branch, tag, or commit) to build from (default: `main`)
- `--branch NAME` - legacy alias for `--ref`
- `--apply-pr-2127` - apply a local forward-port of PR #2127 (silent_processing) on top of latest upstream
- `--without-goolm` - build with tags `stdjson,whatsapp_native` (omit `goolm`); not recommended on current upstream
- `--install-deps` - try to install missing deps with `pkg` (`git`, `go`, `ca_root_nss`)
- `-h`, `--help` - show usage

## Files

- `picoclaw-wa-fbsd-native.sh` - FreeBSD-native PicoClaw build helper

## License

Licensed under the BSD-2-Clause license. See LICENSE.
