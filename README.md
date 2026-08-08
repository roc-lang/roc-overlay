# roc-overlay

A Nix flake for the [Roc new-compiler nightly binaries](https://github.com/roc-lang/nightlies/releases). Inspired by [Mitchell Hashimoto's](https://mitchellh.com/) [zig-overlay](https://github.com/mitchellh/zig-overlay).

This flake just mirrors prebuilt official Roc binaries; it does not build Roc from source. At present, it only provides [nightly](https://github.com/roc-lang/nightlies/releases) releases, as the [new Zig compiler](https://gist.github.com/rtfeldman/f46bcbfe5132d62c4095dfa687bb9aa4) has no stable release yet.

Not using Nix? [`roc-lang/setup-roc`](https://github.com/roc-lang/setup-roc) is the official GitHub Action for installing Roc on CI, and it also covers Windows.

This repo was originally created by @thebrandonlucas, thanks Brandon :heart:

## Usage

### Quickstart from shell

```sh
# To get the latest nightly:

# Create a shell with the compiler.
nix shell github:roc-lang/roc-overlay
roc version

# Run one off commands directly from the flake.
nix run github:roc-lang/roc-overlay -- version

# For a pinned Roc release:
nix shell 'github:roc-lang/roc-overlay#nightly-2026-08-07-8d23662'
```

Release tags up to `nightly-2026-August-05-24f0b47` spell the month out in English; from `nightly-2026-08-06-61bbb59` onwards they use a two-digit month. Both forms are recorded and can be selected as shown above.


### As a package in your own flake.nix

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    roc-overlay.url = "github:roc-lang/roc-overlay";
    roc-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {nixpkgs, roc-overlay, ...}: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    devShells.${system}.default = pkgs.mkShell {
      packages = [
        roc-overlay.packages.${system}.nightly
      ];
    };
  };
}
```

Select a historical package with `roc-overlay.packages.${system}."<release-tag>"`.

### As an overlay

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    roc-overlay.url = "github:roc-lang/roc-overlay";
    roc-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {nixpkgs, roc-overlay, ...}: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
      overlays = [roc-overlay.overlays.default];
    };
  in {
    devShells.${system}.default = pkgs.mkShell {
      packages = [
        pkgs.rocpkgs.nightly
      ];
    };
  };
}
```

### Updating

The consumer's `flake.lock` pins the selected overlay commit, so Roc updates are explicit:

```sh
nix flake update roc-overlay
```

## Supported systems

- `x86_64-linux`
- `aarch64-linux`
- `x86_64-darwin`
- `aarch64-darwin`

Intel macOS packages use the last compatible Nixpkgs Darwin release branch (Nixpkgs 26.05) because current unstable Nixpkgs has dropped that system.

`default` and `nightly` point to the newest release in `sources.json`. Every recorded release also remains available under its complete release tag.


On Linux, `roc` is wrapped with Nix's C toolchain and core utilities so it can locate libc in Nix-managed environments, especially NixOS. Ordinary platform apps and `roc version` alone do not expose that requirement. On macOS, the package installs Roc's bundled minimal Darwin sysroot next to the executable.


## Updating `sources.json`

```sh
./update.sh
./update.sh nightly-2026-08-07-8d23662
./update.sh nightly-2026-July-14-c9147c2
```

The optional argument selects a specific release; otherwise the script uses GitHub's latest-release API. It validates the immutable release, all four expected assets, tag/commit consistency, URLs, and API-provided SHA-256 digests.

Maintainer checks:

```sh
nix fmt -- --check
nix flake check --all-systems --no-build
nix flake check
nix run . -- version
```
