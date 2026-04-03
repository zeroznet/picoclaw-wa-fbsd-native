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

With `goolm` enabled:

```sh
fetch -q -o - https://raw.githubusercontent.com/zeroznet/picoclaw-wa-fbsd-native/main/picoclaw-wa-fbsd-native.sh | sh -s -- --with-goolm
```

## Local usage

```sh
./picoclaw-wa-fbsd-native.sh
```

Install missing deps and build:

```sh
./picoclaw-wa-fbsd-native.sh --install-deps
```

Build with upstream-like tags:

```sh
./picoclaw-wa-fbsd-native.sh --with-goolm
```

## Files

- `picoclaw-wa-fbsd-native.sh` - FreeBSD-native PicoClaw build helper

## License

Licensed under the BSD-2-Clause license. See LICENSE.
