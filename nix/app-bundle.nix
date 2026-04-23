{ pkgs, mcmonad, mcmonad-core }:

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

    # --- Rewrite rpaths in all binaries and dylibs ---
    rewrite_refs() {
      local target="$1"
      local refs
      refs=$(otool -L "$target" 2>/dev/null | grep '/nix/store/' | awk '{print $1}' || true)

      for ref in $refs; do
        local base
        base=$(basename "$ref")
        if [ -f "$APP/Frameworks/$base" ]; then
          install_name_tool -change "$ref" "@executable_path/../Frameworks/$base" "$target" 2>/dev/null || true
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

    # --- Verify no remaining /nix/store references in load commands ---
    echo ""
    echo "Verifying no remaining /nix/store references..."
    REMAINING=0
    for f in "$APP/MacOS/mcmonad" "$APP/MacOS/mcmonad-core" "$APP/Frameworks/"*.dylib; do
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

    # --- Ad-hoc /usr/bin/codesign ---
    echo "Codesigning..."
    for f in "$APP/Frameworks/"*.dylib; do
      /usr/bin/codesign --force --sign - "$f"
    done
    /usr/bin/codesign --force --sign - "$APP/MacOS/mcmonad"
    /usr/bin/codesign --force --sign - "$APP/MacOS/mcmonad-core"

    echo "Built MCMonad.app"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/Applications
    cp -r MCMonad.app $out/Applications/
    runHook postInstall
  '';

  # The mcmonad-core build needs Xcode
  __impureHostDeps = [
    "/usr/bin//usr/bin/codesign"
    "/usr/bin/xcrun"
  ];
}
