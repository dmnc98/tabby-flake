{
  lib,
  stdenv,
  fetchurl,
  runCommandLocal,
  dpkg,
  file,
  glibc,
  patchelf,
  autoPatchelfHook,
  makeShellWrapper,
  wrapGAppsHook3,
  gsettings-desktop-schemas,
  dconf,
  glib,

  # Needed by the bundled Electron runtime and by Tabby's own native modules
  # (node-pty, russh, keytar, fontmanager-redux, @serialport/bindings-cpp).
  # autoPatchelfHook resolves these.
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  fontconfig,
  gtk3,
  libgbm,
  libGL,
  libsecret,
  libxkbcommon,
  nspr,
  nss,
  pango,
  systemdLibs,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxrandr,

  # Source selection. By default everything is taken from ./sources.json, which
  # is what the update bot rewrites. Override any of these to pin a build by
  # hand (e.g. an older release, or a .deb you already have on disk).
  # `deb*` rather than the bare names `url`/`hash`/`src`, because callPackage
  # fills any argument that matches a top-level nixpkgs attribute — and
  # `pkgs.src` exists.
  sources ? lib.importJSON ./sources.json,
  version ? sources.version,
  debUrl ? null,
  debHash ? null,
  debFile ? null,

  # Pass `--no-sandbox` to Electron. The .deb ships a `chrome-sandbox` helper
  # that has to be setuid root, which a Nix store path can never be; without
  # this flag Electron refuses to start. Upstream's own .desktop file passes
  # the same flag. Set to false if you instead enable
  # `security.chromiumSuidSandbox.enable` and wire up the helper yourself.
  disableSandbox ? true,
}:

let
  inherit (stdenv.hostPlatform) system;

  platform =
    sources.platforms.${system}
      or (throw "tabby-terminal: unsupported system '${system}'; sources.json pins ${lib.concatStringsSep ", " (lib.attrNames sources.platforms)}");

  # electron-builder's .deb arch slug and the arch slug Node prebuilds use
  # happen to be the same string ("x64" / "arm64"), so one field covers both
  # the download URL and the prebuild pruning below.
  arch = platform.arch;

  resolvedUrl =
    if debUrl != null then
      debUrl
    else
      builtins.replaceStrings [ "@version@" "@arch@" ] [ version arch ] sources.urlTemplate;

  resolvedSrc =
    if debFile != null then
      debFile
    else
      fetchurl {
        url = resolvedUrl;
        hash = if debHash != null then debHash else platform.hash;
      };
in
stdenv.mkDerivation (finalAttrs: {
  # `tabby` in nixpkgs is TabbyML's coding assistant, an unrelated project that
  # happens to share the name. This is the terminal, and `tabby-terminal` is
  # also what upstream calls its Debian package — so the attribute never
  # shadows nixpkgs', while the binary stays `tabby`.
  pname = "tabby-terminal";
  inherit version;
  src = resolvedSrc;

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    # Deliberately the *shell* wrapper, and invoked by its unambiguous name
    # below: wrapGAppsHook3 propagates makeBinaryWrapper, whose `makeWrapper`
    # shadows the shell one and would pass the conditional Wayland flags
    # through as literal text, since a C wrapper does no shell expansion.
    makeShellWrapper
    wrapGAppsHook3
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    fontconfig
    glib
    gtk3
    libgbm
    libsecret
    libxkbcommon
    nspr
    nss
    pango
    systemdLibs # libudev.so.1, for @serialport/bindings-cpp
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxrandr
  ];

  # `appendRunpaths` applies to every ELF including shared libraries;
  # `runtimeDependencies` only rewrites dynamic executables, which is not
  # enough for libraries that dlopen each other.
  appendRunpaths = lib.makeLibraryPath [
    libGL # libEGL.so.1 is dlopen'd at runtime, so it is never a DT_NEEDED entry
  ];

  # A 225 MB unstripped Electron binary plus ~40 native modules; stripping them
  # costs minutes and buys nothing for a prebuilt vendor tree.
  dontStrip = true;

  # wrapGAppsHook3 is only here for its GDK_PIXBUF/GSettings setup; let it
  # collect the environment but do the actual wrapping ourselves below so the
  # binary is not wrapped twice.
  dontWrapGApps = true;

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb --fsys-tarfile "$src" | tar --extract
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/lib $out/share
    cp -r opt/Tabby $out/lib/tabby
    cp -r usr/share/* $out/share/

    chmod +x $out/lib/tabby/tabby

    # electron-builder ships every platform's prebuilt native modules in the
    # same tree. On this system all but the linux-${arch} set are dead weight,
    # and their foreign ELF headers (android, musl, other architectures) are
    # exactly what autoPatchelfHook would fail the build over.
    nodeModules=$out/lib/tabby/resources/app.asar.unpacked/node_modules

    find "$nodeModules" -type d \
      \( -name 'win32-*' -o -name 'darwin-*' -o -name 'android-*' \
         -o \( -name 'linux-*' -a ! -name 'linux-${arch}*' \) \) \
      -prune -exec rm -rf {} +

    # russh publishes one flat .node per target triple instead of a directory.
    find "$nodeModules/russh" -name 'russh.*.node' \
      ! -name 'russh.linux-${arch}-gnu.node' -delete

    # @serialport keeps its glibc and musl builds side by side in the directory
    # we just kept.
    rm -f "$nodeModules/@serialport/bindings-cpp/prebuilds/linux-${arch}/node.napi.musl.node"

    # Upstream's Exec is an absolute /opt path with the sandbox flag baked in;
    # both of those are our wrapper's job.
    substituteInPlace $out/share/applications/tabby.desktop \
      --replace-fail 'Exec=/opt/Tabby/tabby --no-sandbox %U' 'Exec=tabby %U'

    # Built as an array rather than an inline `lib.optionalString`, so that
    # disabling it leaves no stray blank continuation line behind.
    sandboxArgs=()
    ${lib.optionalString disableSandbox ''
      sandboxArgs+=(--add-flags "--no-sandbox --disable-gpu-sandbox")
    ''}

    makeShellWrapper $out/lib/tabby/tabby $out/bin/tabby \
      "''${gappsWrapperArgs[@]}" \
      "''${sandboxArgs[@]}" \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}" \
      --prefix XDG_DATA_DIRS : "${gsettings-desktop-schemas}/share/gsettings-schemas/${gsettings-desktop-schemas.name}" \
      --prefix XDG_DATA_DIRS : "${gtk3}/share/gsettings-schemas/${gtk3.name}" \
      --prefix GIO_EXTRA_MODULES : "${dconf.lib}/lib/gio/modules"

    runHook postInstall
  '';

  postFixup = ''
    # Tolerate absence: cosmetic, and a future .deb may drop them.
    rm -rf $out/share/doc $out/share/lintian
  '';

  passthru = {
    inherit sources;
    url = resolvedUrl;

    # `nix build .#checks.<system>.tabby-startup` — the invariants that would
    # otherwise only show up as a blank window, a crash on first launch, or a
    # terminal that refuses to open a tab.
    tests.startup =
      runCommandLocal "tabby-${version}-startup-test"
        {
          nativeBuildInputs = [
            glibc.bin # ldd
            file
            patchelf
          ];
          tabby = finalAttrs.finalPackage;
        }
        ''
          set -euo pipefail
          fail=0

          echo "== every bundled ELF links completely =="
          while read -r elf; do
            if ldd "$elf" 2>/dev/null | grep -q 'not found'; then
              echo "FAIL: unresolved libraries in $elf" >&2
              ldd "$elf" | grep 'not found' >&2
              fail=1
            fi
          done < <(
            find "$tabby/lib/tabby" -type f -exec \
              sh -c 'file -b "$1" | grep -q "^ELF" && echo "$1"' _ {} \;
          )

          echo "== libEGL.so.1 is reachable from Tabby's runpath =="
          # Not caught by autoPatchelfHook: ANGLE dlopen()s libEGL, so nothing
          # records it as a DT_NEEDED entry. appendRunpaths is what supplies it.
          egl_dir=
          for dir in $(patchelf --print-rpath "$tabby/lib/tabby/tabby" | tr ':' ' '); do
            if [ -e "$dir/libEGL.so.1" ]; then
              egl_dir=$dir
              break
            fi
          done
          if [ -n "$egl_dir" ]; then
            echo "   libEGL.so.1 <- $egl_dir"
          else
            echo "FAIL: libEGL.so.1 is not in Tabby's runpath (lost appendRunpaths?)" >&2
            fail=1
          fi

          echo "== the installed tree is usable =="
          test -x "$tabby/bin/tabby"                                    || { echo "FAIL: no executable bin/tabby" >&2; fail=1; }
          test -f "$tabby/share/applications/tabby.desktop"             || { echo "FAIL: no desktop file" >&2; fail=1; }
          test -f "$tabby/share/icons/hicolor/256x256/apps/tabby.png"   || { echo "FAIL: no hicolor icon" >&2; fail=1; }
          grep -qx 'Exec=tabby %U' "$tabby/share/applications/tabby.desktop" \
            || { echo "FAIL: desktop Exec does not point at the wrapper" >&2; fail=1; }
          grep -qx 'Icon=tabby' "$tabby/share/applications/tabby.desktop" \
            || { echo "FAIL: desktop Icon does not match the installed icons" >&2; fail=1; }

          echo "== bin/tabby is a shell wrapper, so the ozone flags expand =="
          # makeBinaryWrapper, which wrapGAppsHook3 propagates, compiles the
          # wrapper to C and performs no shell expansion: the conditional
          # ''${NIXOS_OZONE_WL:+...} would reach Electron as literal text and
          # Tabby would silently never get the Wayland flags.
          if head -n1 "$tabby/bin/tabby" | grep -q '^#!'; then
            grep -q 'NIXOS_OZONE_WL:+' "$tabby/bin/tabby" \
              || { echo "FAIL: the wrapper lost the NIXOS_OZONE_WL conditional" >&2; fail=1; }
          else
            echo "FAIL: bin/tabby is not a shell wrapper (makeShellWrapper shadowed again?)" >&2
            fail=1
          fi

          echo "== the Electron bundle is intact =="
          # Tabby has no --version that exits, so the binary is never run here.
          # These are the files Electron cannot start without.
          for f in resources.pak icudtl.dat snapshot_blob.bin resources/app.asar; do
            test -s "$tabby/lib/tabby/$f" \
              || { echo "FAIL: missing or empty lib/tabby/$f" >&2; fail=1; }
          done

          echo "== the terminal's own native modules survived the prune =="
          # A pruning rule that is too greedy takes node-pty or russh with it,
          # which costs Tabby every local shell and every SSH connection.
          modules=$tabby/lib/tabby/resources/app.asar.unpacked/node_modules
          for f in \
            node-pty/build/Release/pty.node \
            russh/russh.linux-${arch}-gnu.node \
            keytar/build/Release/keytar.node \
            fontmanager-redux/build/Release/fontmanager.node
          do
            test -s "$modules/$f" || { echo "FAIL: missing native module $f" >&2; fail=1; }
          done

          echo "== no foreign-platform binaries are left behind =="
          foreign=$(
            find "$modules" \
              \( -ipath '*win32*' -o -ipath '*darwin*' -o -ipath '*android*' \
                 -o -ipath '*msvc*' -o -name '*.musl.node' \) \
              -name '*.node' -print
          )
          if [ -n "$foreign" ]; then
            echo "FAIL: foreign prebuilds still present:" >&2
            echo "$foreign" >&2
            fail=1
          fi

          [ "$fail" -eq 0 ] || exit 1
          echo OK | tee "$out"
        '';
  };

  meta = {
    description = "Terminal emulator, SSH and serial client for a modern age";
    longDescription = ''
      Tabby (formerly Terminus) is an Electron-based terminal emulator with
      built-in SSH, Telnet and serial clients, split panes, tab persistence and
      a plugin system.

      Upstream publishes no Nix package, so this repackages the official .deb
      release: the Electron tree is relocated into the store, its prebuilt
      native modules are pruned to this system's architecture, and everything
      is patchelf'd against nixpkgs libraries.
    '';
    homepage = "https://tabby.sh";
    downloadPage = "https://github.com/Eugeny/tabby/releases";
    changelog = "https://github.com/Eugeny/tabby/releases/tag/v${version}";
    license = lib.licenses.mit;
    mainProgram = "tabby";
    platforms = lib.attrNames sources.platforms;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
