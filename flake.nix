{
  description = "Tabby (the terminal emulator) packaged for NixOS from upstream's official .deb releases.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      sources = builtins.fromJSON (builtins.readFile ./pkgs/tabby/sources.json);

      # Systems Tabby itself ships a .deb for and this flake pins a hash for.
      tabbySystems = builtins.attrNames sources.platforms;
      # Systems this flake's dev shell / scripts are available on. No
      # x86_64-darwin: nixpkgs 26.11 dropped it.
      devSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      forSystems =
        systems: f: nixpkgs.lib.genAttrs systems (system: f system (import nixpkgs { inherit system; }));

      updateDeps = pkgs: [
        pkgs.bash
        pkgs.coreutils
        pkgs.curl
        pkgs.git
        pkgs.gnugrep
        pkgs.gnused
        pkgs.jq
      ];
    in
    {
      lib.mkTabby = pkgs: args: pkgs.callPackage ./pkgs/tabby/package.nix args;

      # `tabby-terminal`, not `tabby`: nixpkgs' `tabby` is TabbyML's coding
      # assistant, and an overlay should not shadow it.
      overlays.default = final: _prev: {
        tabby-terminal = final.callPackage ./pkgs/tabby/package.nix { };
      };

      nixosModules.default = import ./modules/nixos.nix self;
      nixosModules.tabby = self.nixosModules.default;

      homeManagerModules.default = import ./modules/home-manager.nix self;
      homeManagerModules.tabby = self.homeManagerModules.default;

      packages = forSystems tabbySystems (
        _system: pkgs: rec {
          tabby-terminal = pkgs.callPackage ./pkgs/tabby/package.nix { };
          default = tabby-terminal;
        }
      );

      checks = forSystems tabbySystems (
        system: _pkgs: {
          tabby = self.packages.${system}.tabby-terminal;
          tabby-startup = self.packages.${system}.tabby-terminal.tests.startup;
        }
      );

      apps = forSystems devSystems (
        system: pkgs: {
          # `nix run .#update` — bump pkgs/tabby/sources.json to the newest
          # upstream release. This is what CI runs.
          update = {
            type = "app";
            meta.description = "Bump pkgs/tabby/sources.json to the latest Tabby release";
            program = toString (
              pkgs.writeShellScript "tabby-update" ''
                export PATH=${nixpkgs.lib.makeBinPath (updateDeps pkgs)}:$PATH
                exec ${./scripts/update.sh} "$@"
              ''
            );
          };

          # `nix run .#hash -- 1.0.237` — SRI hashes for an arbitrary version,
          # for pinning a build other than the one this flake tracks.
          hash = {
            type = "app";
            meta.description = "Print SRI hashes of a given Tabby version's .deb files";
            program = toString (
              pkgs.writeShellScript "tabby-hash" ''
                set -eu
                export PATH=${nixpkgs.lib.makeBinPath (updateDeps pkgs)}:$PATH
                if [ $# -ne 1 ]; then
                  echo "usage: nix run .#hash -- <version>   (e.g. 1.0.238)" >&2
                  exit 64
                fi
                for pair in x86_64-linux:x64 aarch64-linux:arm64; do
                  system=''${pair%%:*}
                  arch=''${pair##*:}
                  url="https://github.com/Eugeny/tabby/releases/download/v$1/tabby-$1-linux-$arch.deb"
                  if ! curl -fsIL "$url" >/dev/null 2>&1; then
                    echo "$system	(no $arch build for $1)"
                    continue
                  fi
                  printf '%s\t%s\n' "$system" \
                    "$(nix store prefetch-file --json --hash-type sha256 "$url" | jq -r .hash)"
                done
              ''
            );
          };

          default = self.apps.${system}.update;
        }
      );

      devShells = forSystems devSystems (
        _system: pkgs: {
          default = pkgs.mkShellNoCC {
            packages = updateDeps pkgs ++ [
              pkgs.nixfmt
              pkgs.shellcheck
            ];
          };
        }
      );

      formatter = forSystems devSystems (_system: pkgs: pkgs.nixfmt);
    };
}
