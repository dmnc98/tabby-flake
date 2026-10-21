# tabby-flake

A Nix flake that packages [Tabby](https://tabby.sh) — the Electron terminal
emulator with built-in SSH, Telnet and serial clients (formerly Terminus) — from
upstream's official `.deb` releases, and exposes it as a package, an overlay, a
NixOS module and a Home Manager module.

```nix
programs.tabby.enable = true;   # that's it
```

A bot watches [upstream's releases](https://github.com/Eugeny/tabby/releases)
and republishes this flake whenever Tabby ships a new version, so
`nix flake update` is all you need to upgrade.

## Why this exists

Tabby is not in nixpkgs. The `tabby` attribute there is
[TabbyML](https://github.com/TabbyML/tabby)'s self-hosted coding assistant — an
unrelated project that happens to share the name — and there is no
`programs.tabby` module in nixpkgs or Home Manager either.

Upstream ships `.deb`, `.rpm`, `.pacman`, `.AppImage` and `.tar.gz` builds. This
flake takes the `.deb`, which is the only one of those that is both a plain
archive *and* carries the `.desktop` file and icon set, and turns it into a
normal store path:

- the Electron tree moves to `$out/lib/tabby`, with a wrapper at `$out/bin/tabby`
- every bundled ELF — Electron itself plus ~15 native Node modules
  (`node-pty`, `russh`, `keytar`, `fontmanager-redux`,
  `@serialport/bindings-cpp`) — is patchelf'd against nixpkgs libraries
- prebuilt native modules for *other* platforms (Windows, macOS, Android, musl,
  other architectures) are deleted; nothing on this system can load them, and
  their foreign ELF headers break `autoPatchelfHook`
- `--no-sandbox` is passed, because Electron's sandbox helper needs to be setuid
  root and a store path can never be (upstream's own `.desktop` file does the
  same)
- on Wayland, `--ozone-platform-hint=auto` and friends are added when
  `NIXOS_OZONE_WL` is set

> The attribute is called **`tabby-terminal`** (upstream's own Debian package
> name), so an overlay from this flake never shadows nixpkgs' unrelated
> `tabby`. The module option, the binary and the desktop entry are all plain
> `tabby`.

## Install

Add the input:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    tabby.url = "github:dmnc98/tabby-flake";
    tabby.inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

### NixOS

```nix
# configuration.nix
{ inputs, ... }:
{
  imports = [ inputs.tabby.nixosModules.default ];

  programs.tabby.enable = true;
}
```

### Home Manager

```nix
# home.nix
{ inputs, ... }:
{
  imports = [ inputs.tabby.homeManagerModules.default ];

  programs.tabby.enable = true;
}
```

### Without the modules

```nix
environment.systemPackages = [ inputs.tabby.packages.${pkgs.system}.default ];
```

or via the overlay, which adds `pkgs.tabby-terminal`:

```nix
nixpkgs.overlays = [ inputs.tabby.overlays.default ];
```

### Try it first

```sh
nix run github:dmnc98/tabby-flake
```

## Options

Everything below `programs.tabby` is identical in the NixOS and Home Manager
modules; only the destination (`environment.systemPackages` vs
`home.packages`) differs.

| Option | Default | What it does |
|---|---|---|
| `enable` | `false` | Install Tabby |
| `version` | the pinned version | Install a different release — needs `hash` too |
| `hash` | `null` | SRI hash of the `.deb` for `version` |
| `url` | `null` | Fetch the `.deb` from a mirror instead of GitHub — needs `hash` |
| `src` | `null` | Use a `.deb` already on disk; wins over `url`/`version` |
| `disableSandbox` | `true` | Pass `--no-sandbox --disable-gpu-sandbox` |
| `package` | built from the above | Override the package outright |

Pinning an older release:

```nix
programs.tabby = {
  enable = true;
  version = "1.0.237";
  hash = "sha256-...";          # nix run github:dmnc98/tabby-flake#hash -- 1.0.237
};
```

A bad combination is an evaluation error, not a silent fallback: `url` without
`hash`, or a `version` this flake has no hash for, fails an assertion.

## Keeping it current

```sh
nix run .#update              # bump sources.json to the newest stable release
nix run .#update -- --pre     # consider upstream pre-releases as well
nix run .#update -- --version 1.0.237
nix run .#update -- --dry-run # report only
nix run .#hash -- 1.0.237     # SRI hashes for an arbitrary version
```

`.github/workflows/update.yml` runs the first of those every six hours. It only
commits, tags and releases after a full build on **both** pinned systems has
succeeded, so a version that does not build never reaches `main`.

## Verifying a build

```sh
nix build .#checks.x86_64-linux.tabby          # the package
nix build .#checks.x86_64-linux.tabby-startup  # the invariants below
```

`tabby-startup` asserts the things that would otherwise only surface as a blank
window or a terminal that refuses to open a tab:

- every bundled ELF resolves all of its libraries (`ldd`, no `not found`)
- `libEGL.so.1` is reachable from the runpath — it is `dlopen`'d by ANGLE, so no
  DT_NEEDED entry records it and `autoPatchelfHook` cannot catch it
- `bin/tabby` is executable, and the `.desktop` file's `Exec`/`Icon` point at
  the wrapper and the installed icons
- `bin/tabby` is a *shell* wrapper, so the conditional Wayland flags expand at
  launch — `wrapGAppsHook3` propagates `makeBinaryWrapper`, whose `makeWrapper`
  would shadow the shell one and hand Electron `${NIXOS_OZONE_WL:+...}` as
  literal text
- the Electron bundle still has `resources.pak`, `icudtl.dat`,
  `snapshot_blob.bin` and `resources/app.asar`
- `node-pty`, `russh`, `keytar` and `fontmanager-redux` survived the prune —
  without them Tabby has no local shell and no SSH
- no Windows/macOS/Android/musl prebuild is left behind

## Supported systems

`x86_64-linux` and `aarch64-linux`. Upstream also publishes an `armv7l` `.deb`;
it is deliberately unpinned, because no GitHub-hosted runner can build and
verify it. Adding it means one entry in `ARCHES` in `scripts/update.sh` and a
pin in `pkgs/tabby/sources.json`.

Requires nixpkgs 26.11 or newer (it uses the flattened `libx11`-style X11
attribute names).

## Notes

- **Tabby's own updater.** The build keeps `resources/app-update.yml`, so Tabby
  will notice new upstream releases and offer to install them. It cannot — the
  store is read-only. Upgrade with `nix flake update` instead, and turn the
  notification off under *Settings → Application → Automatic updates*.
- **SSH profiles.** On first launch Tabby imports the hosts from
  `~/.ssh/config` into its own `~/.config/tabby/config.yaml`.
- **Electron reads the home directory from `/etc/passwd`,** not from `$HOME`,
  so overriding `HOME` does not relocate `~/.config/tabby`. Use
  `--user-data-dir` if you need a throwaway profile.
- **Not a sandboxed build.** This repackages upstream's prebuilt binary; it is
  `sourceProvenance = binaryNativeCode`, not built from source. Tabby itself is
  MIT.

## Layout

```
flake.nix                      # packages, overlay, modules, apps, checks
pkgs/tabby/package.nix         # the derivation + the startup invariants
pkgs/tabby/sources.json        # the pin the update bot rewrites
modules/common.nix             # the shared option set
modules/{nixos,home-manager}.nix
scripts/update.sh              # release discovery + prefetch
.github/workflows/ci.yml       # build & module eval on every push
.github/workflows/update.yml   # discover -> build -> commit, tag, release
```
