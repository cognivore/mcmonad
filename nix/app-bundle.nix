{ pkgs, mcmonad, mcmonad-core, mcmonad-ghc }:

let
  resourceDir = ../core/Sources/MCMonadCore/Resources;
  launcherScript = ../scripts/mcmonad-launcher;
in

pkgs.stdenv.mkDerivation {
  pname = "MCMonad";
  version = "0.1.0";

  # No source needed — we assemble from built packages
  dontUnpack = true;
  # Prevent Nix's fixup phase from rewriting our carefully set rpaths
  dontFixup = true;

  nativeBuildInputs = [ pkgs.darwin.cctools ];

  buildPhase = ''
    runHook preBuild

    APP="MCMonad.app/Contents"
    mkdir -p "$APP/MacOS" "$APP/Frameworks" "$APP/Resources"

    # --- Binaries ---
    cp ${mcmonad}/bin/mcmonad "$APP/MacOS/mcmonad"
    cp ${mcmonad-core}/bin/mcmonad-core "$APP/MacOS/mcmonad-core"
    cp ${launcherScript} "$APP/MacOS/mcmonad-launcher"
    chmod +x "$APP/MacOS/mcmonad-launcher" "$APP/MacOS/mcmonad" "$APP/MacOS/mcmonad-core"

    # --- Collect all Nix dylib dependencies recursively ---
    # Walk the binary and every discovered dylib, collecting /nix/store refs
    collect_dylibs() {
      local queue=("$@")
      local seen=()
      local result=()

      while [ ''${#queue[@]} -gt 0 ]; do
        local current="''${queue[0]}"
        queue=("''${queue[@]:1}")

        # Extract /nix/store dylib paths
        local deps
        deps=$(otool -L "$current" 2>/dev/null | grep '/nix/store/' | awk '{print $1}' || true)

        for dep in $deps; do
          # Skip if already seen
          local found=0
          for s in "''${seen[@]+"''${seen[@]}"}"; do
            if [ "$s" = "$dep" ]; then found=1; break; fi
          done
          if [ "$found" -eq 1 ]; then continue; fi

          seen+=("$dep")
          if [ -f "$dep" ]; then
            result+=("$dep")
            queue+=("$dep")
          fi
        done
      done

      printf '%s\n' "''${result[@]+"''${result[@]}"}"
    }

    echo "Collecting dylib dependencies..."
    DYLIBS=$(collect_dylibs "$APP/MacOS/mcmonad" "$APP/MacOS/mcmonad-core")

    # Copy all dylibs into Frameworks/
    for dylib in $DYLIBS; do
      base=$(basename "$dylib")
      echo "  Bundling: $base"
      cp "$dylib" "$APP/Frameworks/$base"
      chmod 755 "$APP/Frameworks/$base"
    done

    # --- Rewrite Nix store dylib refs ---
    # $1: binary path
    # $2: @executable_path or @loader_path prefix to Frameworks/
    rewrite_refs() {
      local target="$1"
      local fw_prefix="''${2:-@executable_path/../Frameworks}"
      local refs
      refs=$(otool -L "$target" 2>/dev/null | grep '/nix/store/' | awk '{print $1}' || true)

      for ref in $refs; do
        local base
        base=$(basename "$ref")
        if [ -f "$APP/Frameworks/$base" ]; then
          install_name_tool -change "$ref" "$fw_prefix/$base" "$target" 2>/dev/null || true
        fi
      done
    }

    # Rewrite the main binaries
    echo "Rewriting rpaths in mcmonad..."
    rewrite_refs "$APP/MacOS/mcmonad"
    echo "Rewriting rpaths in mcmonad-core..."
    rewrite_refs "$APP/MacOS/mcmonad-core"

    # Rewrite the dylibs themselves (they reference each other via nix paths)
    for dylib in "$APP/Frameworks/"*.dylib; do
      base=$(basename "$dylib")
      echo "Rewriting rpaths in $base..."
      # Fix the dylib's own install name
      install_name_tool -id "@executable_path/../Frameworks/$base" "$dylib" 2>/dev/null || true
      rewrite_refs "$dylib"
    done

    # ===================================================================
    # Bundle GHC for config recompilation
    # ===================================================================
    echo ""
    echo "=== Bundling GHC for config recompilation ==="

    # Resolve real GHC binary from the ghcWithPackages wrapper script
    REAL_GHC_BIN=$(grep -oE '/nix/store/[a-z0-9]+-ghc-[0-9][^/]*/bin/ghc' ${mcmonad-ghc}/bin/ghc | head -1)
    GHC_VERSION=$($REAL_GHC_BIN --numeric-version)
    GHC_LIBDIR=$($REAL_GHC_BIN --print-libdir)
    echo "  GHC version: $GHC_VERSION"
    echo "  GHC libdir:  $GHC_LIBDIR"

    # GHC_LIBDIR = ghc --print-libdir = .../lib/ghc-VERSION/lib
    # This IS the topdir (contains settings, package.conf.d, etc.)
    # Its parent (.../lib/ghc-VERSION/) has bin/ with support tools.

    # Directory layout in the bundle:
    #   Contents/GHC/bin/ghc                          (real binary)
    #   Contents/GHC/topdir/                          (= GHC libdir, passed via -B)
    #     settings, llvm-targets, llvm-passes
    #     package.conf.d/                             (merged package DB)
    #     <platform>-ghc-VERSION/                     (boot package libs)
    #     packages/                                   (extra package libs)
    #   Contents/GHC/bin/                              (ghc + support tools)
    #     GHC settings references $topdir/../bin/unlit, so support tools
    #     must be alongside the ghc binary under GHC/bin/.

    GHC_BUNDLE="$APP/GHC"
    GHC_TOPDIR="$GHC_BUNDLE/topdir"
    GHC_SUPPORT_SRC="$(dirname "$GHC_LIBDIR")/bin"
    mkdir -p "$GHC_BUNDLE/bin"

    # 1. Copy GHC binary
    cp "$REAL_GHC_BIN" "$GHC_BUNDLE/bin/ghc"
    chmod +x "$GHC_BUNDLE/bin/ghc"

    # 2. Copy GHC libdir (settings, package DBs, boot package libs)
    cp -rL "$GHC_LIBDIR" "$GHC_TOPDIR"
    # Nix store files are read-only; make everything writable for rewriting
    chmod -R u+w "$GHC_BUNDLE"

    # 3a. Copy support tools (unlit, ghc-iserv, etc.) into GHC/bin/
    if [ -d "$GHC_SUPPORT_SRC" ]; then
      for tool in "$GHC_SUPPORT_SRC"/*; do
        [ -f "$tool" ] && cp -L "$tool" "$GHC_BUNDLE/bin/" && chmod +x "$GHC_BUNDLE/bin/$(basename "$tool")"
      done
    fi

    # 3. Rewrite settings to use macOS system tools (Xcode CLT)
    #    GHC settings has lines like: ("C compiler command", "/nix/store/xxx/bin/cc")
    #    Replace /nix/store/.../bin/<tool> with /usr/bin/<tool>
    echo "  Rewriting GHC settings to use system tools..."
    ${pkgs.python3}/bin/python3 -c "
import re, sys
text = open(sys.argv[1]).read()
text = re.sub(r'/nix/store/[^\"]+/bin/([^\"]+)', r'/usr/bin/\1', text)
open(sys.argv[1], 'w').write(text)
" "$GHC_TOPDIR/settings"

    # 4. Merge extra packages from ghcWithPackages into boot package DB
    echo "  Merging extra package configs..."
    GWP_PKGDB="$GHC_TOPDIR_SRC/package.conf.d"
    BUNDLED_PKGDB="$GHC_TOPDIR/lib/package.conf.d"
    mkdir -p "$GHC_TOPDIR/lib/packages"

    for conf in "$GWP_PKGDB"/*.conf; do
      [ -f "$conf" ] || continue
      base=$(basename "$conf")
      if [ ! -f "$BUNDLED_PKGDB/$base" ]; then
        cp "$conf" "$BUNDLED_PKGDB/$base"
      fi
    done

    # 5. Rewrite all package .conf files: replace Nix store paths with
    #    ''${pkgroot} relative paths. Boot package libs are already in the
    #    copied libdir; extra package libs get copied into lib/packages/.
    echo "  Rewriting package configs and copying libraries..."
    BOOT_LIB_PREFIX="$GHC_LIBDIR"
    # Construct the GHC ''${pkgroot} variable as a shell string
    PKGROOT=''$'\x24{pkgroot}'

    for conf in "$BUNDLED_PKGDB"/*.conf; do
      [ -f "$conf" ] || continue

      # Find all Nix store directory paths referenced in this conf
      nix_paths=$(grep -oE '/nix/store/[a-z0-9]+-[^"]+' "$conf" | sort -u || true)

      for nix_path in $nix_paths; do
        # Skip non-directory paths (e.g. file references)
        [ -d "$nix_path" ] || continue

        if [[ "$nix_path" == "$BOOT_LIB_PREFIX/"* ]]; then
          # Boot package: already in the bundle at the same relative position
          rel="''${nix_path#"$BOOT_LIB_PREFIX/"}"
          sed -i '''' "s|$nix_path|$PKGROOT/$rel|g" "$conf"
        else
          # Extra package: copy into lib/packages/<dirname>/ and rewrite
          pkg_leaf=$(basename "$nix_path")
          pkg_dest="$GHC_TOPDIR/lib/packages/$pkg_leaf"
          if [ ! -d "$pkg_dest" ]; then
            mkdir -p "$pkg_dest"
            cp -rL "$nix_path"/* "$pkg_dest/" 2>/dev/null || true
          fi
          sed -i '''' "s|$nix_path|$PKGROOT/packages/$pkg_leaf|g" "$conf"
        fi
      done
    done

    # 6. Recache the package DB
    echo "  Recaching package DB..."
    REAL_GHC_PKG=$(dirname "$REAL_GHC_BIN")/ghc-pkg
    $REAL_GHC_PKG --global-package-db "$BUNDLED_PKGDB" recache 2>/dev/null || \
      echo "  Warning: ghc-pkg recache returned non-zero (may be ok)"

    # 7. Collect dylib dependencies for GHC binary + support tools
    echo "  Collecting GHC dylib dependencies..."
    GHC_EXECUTABLES=()
    for tool in "$GHC_BUNDLE/bin/"*; do
      [ -f "$tool" ] && [ -x "$tool" ] && GHC_EXECUTABLES+=("$tool")
    done

    GHC_DYLIBS=$(collect_dylibs "''${GHC_EXECUTABLES[@]}")
    for dylib in $GHC_DYLIBS; do
      base=$(basename "$dylib")
      if [ ! -f "$APP/Frameworks/$base" ]; then
        echo "    Bundling (GHC): $base"
        cp "$dylib" "$APP/Frameworks/$base"
        chmod 755 "$APP/Frameworks/$base"
      fi
    done

    # 8. Rewrite dylib refs in GHC binary and support tools
    #    GHC/bin/* -> ../../Frameworks/ (up from GHC/bin to Contents)
    echo "  Rewriting rpaths in GHC binaries..."
    for tool in "$GHC_BUNDLE/bin/"*; do
      [ -f "$tool" ] && [ -x "$tool" ] && \
        rewrite_refs "$tool" "@loader_path/../../Frameworks"
    done

    # Also rewrite any new dylibs that were added for GHC
    for dylib in "$APP/Frameworks/"*.dylib; do
      base=$(basename "$dylib")
      install_name_tool -id "@executable_path/../Frameworks/$base" "$dylib" 2>/dev/null || true
      rewrite_refs "$dylib"
    done

    # 9. Create GHC wrapper script
    cat > "$APP/MacOS/mcmonad-ghc" <<GHCWRAPPER
#!/bin/bash
DIR="\$(cd "\$(dirname "\$0")/.." && pwd)"
exec "\$DIR/GHC/bin/ghc" -B"\$DIR/GHC/topdir" "\$@"
GHCWRAPPER
    chmod +x "$APP/MacOS/mcmonad-ghc"

    echo "  GHC bundled successfully"

    # ===================================================================
    # Verify no remaining /nix/store references in load commands
    # ===================================================================
    echo ""
    echo "Verifying no remaining /nix/store references in binaries..."
    REMAINING=0
    ALL_BINARIES=("$APP/MacOS/mcmonad" "$APP/MacOS/mcmonad-core")
    for tool in "$GHC_BUNDLE/bin/"*; do
      [ -f "$tool" ] && [ -x "$tool" ] && ALL_BINARIES+=("$tool")
    done
    for f in "''${ALL_BINARIES[@]}" "$APP/Frameworks/"*.dylib; do
      refs=$(otool -L "$f" 2>/dev/null | grep '/nix/store/' || true)
      if [ -n "$refs" ]; then
        echo "ERROR: $(basename "$f") still has nix store refs:"
        echo "$refs"
        REMAINING=1
      fi
    done
    if [ "$REMAINING" -eq 1 ]; then
      echo "FATAL: Failed to rewrite all nix store references"
      exit 1
    fi
    echo "All clear."

    # --- Info.plist ---
    cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.mcmonad.app</string>
    <key>CFBundleName</key>
    <string>MCMonad</string>
    <key>CFBundleExecutable</key>
    <string>mcmonad-launcher</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSBackgroundOnly</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

    # --- Resources ---
    cp ${resourceDir}/MenuBarIcon.png "$APP/Resources/MenuBarIcon.png"
    cp "${resourceDir}/MenuBarIcon@2x.png" "$APP/Resources/MenuBarIcon@2x.png"

    # --- Ad-hoc codesign ---
    echo "Codesigning..."
    for f in "$APP/Frameworks/"*.dylib; do
      /usr/bin/codesign --force --sign - "$f"
    done
    /usr/bin/codesign --force --sign - "$APP/MacOS/mcmonad"
    /usr/bin/codesign --force --sign - "$APP/MacOS/mcmonad-core"
    for tool in "$GHC_BUNDLE/bin/"*; do
      [ -f "$tool" ] && [ -x "$tool" ] && \
        /usr/bin/codesign --force --sign - "$tool"
    done

    echo "Built MCMonad.app"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/Applications
    cp -r MCMonad.app $out/Applications/
    runHook postInstall
  '';

  __impureHostDeps = [
    "/usr/bin/codesign"
    "/usr/bin/xcrun"
  ];
}
