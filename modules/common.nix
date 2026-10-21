# Shared option set for the NixOS and Home Manager modules. `install` says
# where the package ends up, which is the only thing that differs between them.
{ self, install }:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.tabby;
  sources = lib.importJSON ../pkgs/tabby/sources.json;
in
{
  options.programs.tabby = {
    enable = lib.mkEnableOption "Tabby, a terminal emulator with built-in SSH and serial clients";

    version = lib.mkOption {
      type = lib.types.str;
      default = sources.version;
      defaultText = lib.literalExpression "the version pinned in this flake";
      example = "1.0.237";
      description = ''
        Tabby version to install. Any version still published at
        <https://github.com/Eugeny/tabby/releases> works, but anything other
        than the pinned default also needs {option}`programs.tabby.hash`.
      '';
    };

    hash = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "sha256-XqK5qoTytc3LmMt+lL09kt5IyWJUqYtSvy0fMKUtHRw=";
      description = ''
        SRI hash of the `.deb` for {option}`programs.tabby.version`. Only
        needed when overriding the pinned version. Get it with
        `nix run github:dmnc98/tabby-flake#hash -- <version>`.
      '';
    };

    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://mirror.example/tabby-1.0.238-linux-x64.deb";
      description = ''
        Fetch the `.deb` from somewhere other than GitHub releases (a mirror, a
        build of your own). Requires {option}`programs.tabby.hash`.
      '';
    };

    src = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./tabby-1.0.238-linux-x64.deb";
      description = ''
        Use a `.deb` already on disk instead of downloading one. Takes
        precedence over {option}`programs.tabby.url` and
        {option}`programs.tabby.version`.
      '';
    };

    disableSandbox = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Launch Tabby with `--no-sandbox --disable-gpu-sandbox`. Electron's
        setuid sandbox helper cannot work from a read-only store path, so
        without this Tabby refuses to start. Upstream's own `.desktop` file
        passes the same flag.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      description = "The Tabby package to install.";
      default = pkgs.callPackage "${self}/pkgs/tabby/package.nix" {
        inherit (cfg) version disableSandbox;
        debUrl = cfg.url;
        debHash = cfg.hash;
        debFile = cfg.src;
      };
      defaultText = lib.literalExpression "tabby built from the options above";
    };
  };

  config = lib.mkIf cfg.enable (
    {
      assertions = [
        {
          assertion = cfg.url == null || cfg.hash != null;
          message = "programs.tabby.url requires programs.tabby.hash.";
        }
        {
          assertion = cfg.version == sources.version || cfg.hash != null || cfg.src != null;
          message = ''
            programs.tabby.version is pinned to "${cfg.version}" but this flake
            only knows the hash for "${sources.version}". Set
            programs.tabby.hash as well, or update the flake input.
          '';
        }
      ];
    }
    // install cfg
  );
}
