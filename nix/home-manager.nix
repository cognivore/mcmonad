flake: { config, lib, pkgs, ... }:

let
  cfg = config.services.mcmonad;
  flakePkgs = flake.packages.${pkgs.stdenv.hostPlatform.system};
  app = flakePkgs.mcmonad-app;
  homeDir = config.home.homeDirectory;
  # macOS TCC keys Accessibility entries by binary path + cdhash. Launching
  # directly from /nix/store/<hash>/... accumulates orphan rows in System
  # Settings → Privacy & Security on every home-manager rebuild because the
  # store path changes. We rsync the self-contained .app bundle to a stable
  # user path and point launchd at that path so a single TCC entry per
  # binary is reused across rebuilds.
  bundlePath = "${homeDir}/Applications/MCMonad.app";
  # mcmonad-core ships as a SEPARATE top-level app so TCC gives it its own
  # identity (com.mcmonad.core) — required for the Microphone/Speech prompt to
  # render. Nested inside MCMonad.app it was attributed to com.mcmonad.app (the
  # bash launcher → kTCCErrorDomain Code=5, no prompt). The launcher `open`s it.
  coreBundlePath = "${homeDir}/Applications/MCMonadCore.app";
in
{
  options.services.mcmonad = {
    enable = lib.mkEnableOption "mcmonad tiling window manager";

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = ''
        Contents of ~/.config/mcmonad/mcmonad.hs — the Haskell configuration
        file compiled by Mod-q. When set, home-manager manages this file
        declaratively. When null, the file is unmanaged (user edits directly).
      '';
      example = lib.literalExpression ''
        '''
        import MCMonad
        main = mcmonad defaultConfig
        '''
      '';
    };

    signingIdentity = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Code-signing identity used to re-sign the bundled binaries on every
        activation (a name or SHA-1 hash, as shown by
        `security find-identity -v -p codesigning`). Signing with a stable
        identity — e.g. your Apple Development or Developer ID certificate —
        gives mcmonad-core a fixed code identity, so TCC grants (Accessibility,
        Microphone, Speech Recognition) persist across rebuilds instead of
        resetting each time the ad-hoc signature's cdhash changes. When null,
        falls back to a self-signed `MCMonad` certificate if one is present,
        otherwise the ad-hoc signature from the build is kept.
      '';
      example = "Apple Development: you@example.com (TEAMID)";
    };
  };

  config = lib.mkIf cfg.enable {
    home.file.".config/mcmonad/mcmonad.hs" = lib.mkIf (cfg.configFile != null) {
      text = cfg.configFile;
    };

    home.activation.installMcmonadApp =
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run mkdir -p ${lib.escapeShellArg "${homeDir}/Applications"}
        run ${pkgs.rsync}/bin/rsync \
          --archive --checksum --copy-unsafe-links --delete --chmod=u+w \
          ${app}/Applications/MCMonad.app/ \
          ${lib.escapeShellArg bundlePath}/
        # mcmonad-core is a SEPARATE top-level app (own TCC identity).
        run ${pkgs.rsync}/bin/rsync \
          --archive --checksum --copy-unsafe-links --delete --chmod=u+w \
          ${app}/Applications/MCMonadCore.app/ \
          ${lib.escapeShellArg coreBundlePath}/

        # Re-sign the bundle with a stable code identity so TCC grants
        # (Accessibility, Microphone, Speech Recognition) survive rebuilds.
        # Every Nix rebuild produces an adhoc binary whose Identifier embeds a
        # fresh content hash; TCC treats it as a brand-new client at the same
        # path, so the grant doesn't carry over and windows stop placing /
        # the mic stops working until you re-grant. A stable signature fixes
        # the identity. Prefer an explicitly configured identity
        # (services.mcmonad.signingIdentity — e.g. an Apple Development /
        # Developer ID cert, by name or SHA-1); otherwise fall back to a
        # self-signed `MCMonad` cert if present. Dylibs are signed first, then
        # the executables, with the SAME identity, so library validation
        # passes for the now-team-signed mcmonad-core. If neither is
        # available the bundle keeps its adhoc signature.
        mcmonad_sign_id=${lib.escapeShellArg (if cfg.signingIdentity != null then cfg.signingIdentity else "")}
        if [ -z "$mcmonad_sign_id" ] && /usr/bin/security find-certificate -c MCMonad >/dev/null 2>&1; then
            mcmonad_sign_id=MCMonad
        fi
        mcmonad_app_contents=${lib.escapeShellArg "${bundlePath}/Contents"}

        # Re-sign with a stable identity so TCC grants (Accessibility,
        # Microphone, Speech Recognition) survive rebuilds. Sign dylibs and the
        # haskell binary first, then mcmonad-core LAST — with the microphone
        # entitlement, after its dylib deps are signed. Core's stable identity
        # as a SEPARATE TOP-LEVEL bundle (com.mcmonad.core, launched via `open`
        # by the launcher) is what lets the Spotlight voice input reach the
        # microphone.
        if [ -n "$mcmonad_sign_id" ]; then
            for f in \
                "$mcmonad_app_contents/Frameworks/"*.dylib \
                "$mcmonad_app_contents/MacOS/mcmonad"; do
                [ -e "$f" ] || continue
                /usr/bin/codesign --force --sign "$mcmonad_sign_id" "$f" 2>/dev/null || \
                    echo "mcmonad: codesign $f with '$mcmonad_sign_id' failed; leaving adhoc" >&2
            done
            # Sign core's SEPARATE TOP-LEVEL bundle (MCMonadCore.app) — sealing
            # the bundle is what gives com.mcmonad.core a stable, computable
            # designated code requirement, so TCC can present and persist the
            # mic/speech grant across rebuilds. (Top-level placement is what lets
            # TCC attribute the request to com.mcmonad.core at all; nested inside
            # MCMonad.app it resolved to com.mcmonad.app → Code=5, no prompt.)
            /usr/bin/codesign --force --sign "$mcmonad_sign_id" \
                --entitlements "$mcmonad_app_contents/Resources/mcmonad-core.entitlements" \
                ${lib.escapeShellArg coreBundlePath} 2>/dev/null || \
                echo "mcmonad: codesign MCMonadCore.app with '$mcmonad_sign_id' failed; leaving adhoc" >&2
        fi

        # Register the top-level core app with LaunchServices so TCC resolves
        # its identity to com.mcmonad.core on first launch (belt-and-suspenders;
        # `open` also registers it, but doing it here makes the first prime's
        # mic/speech request attribute correctly without a race).
        lsreg=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
        [ -x "$lsreg" ] && "$lsreg" -f ${lib.escapeShellArg coreBundlePath} 2>/dev/null || true

        # Recompile the user's mcmonad.hs against the freshly installed
        # mcmonad library, so the Mod-q-compiled custom binary stays in
        # lock-step with the bundled IPC protocol. Without this step, an
        # additive IPC change in mcmonad would silently brick anyone who
        # has ever pressed Mod-q: the launcher prefers the custom binary,
        # the custom binary speaks the old protocol, and the Haskell
        # process crash-loops on every new event the bundled core sends.
        # On compile failure we delete the stale binary + sidecar so the
        # launcher falls back to the bundled binary; activation does not
        # abort — the user will see the failure on next login.
        #
        # -fforce-recomp is load-bearing: when only the mcmonad *library*
        # store path changes (mcmonad.hs itself byte-identical, as with a
        # bindings or layout change that lives in the library, not the
        # user config), ghc --make's recompilation checker sees an
        # unchanged source + cached .hi/.o and SKIPS the rebuild. The
        # custom binary then keeps the OLD library's behaviour — old
        # keybindings, old defaults — while still reporting the matching
        # protocol version, so the launcher happily runs it and the new
        # behaviour never reaches the user. Forcing recompilation every
        # activation guarantees the running config tracks the deployed
        # library (e.g. a generated palinchron config picks up new
        # defaultKeys bindings on switch instead of only on a manual
        # Mod-q after the .hi/.o cache is busted).
        mcmonad_hs=${lib.escapeShellArg "${homeDir}/.config/mcmonad/mcmonad.hs"}
        mcmonad_ghc=${lib.escapeShellArg "${bundlePath}/Contents/MacOS/mcmonad-ghc"}
        case "$(uname -m)" in
            arm64) mcmonad_arch=aarch64 ;;
            *)     mcmonad_arch=$(uname -m) ;;
        esac
        mcmonad_bin=${lib.escapeShellArg "${homeDir}/.config/mcmonad"}/mcmonad-''${mcmonad_arch}-darwin
        if [ -f "$mcmonad_hs" ] && [ -x "$mcmonad_ghc" ]; then
            # Bundled GHC's settings file points at /usr/bin/clang (the
            # macOS clang stub), which delegates to whatever DEVELOPER_DIR
            # points at. If the activation inherits DEVELOPER_DIR from a
            # nix dev shell or similar, clang lookup blows up with "tool
            # 'clang' not found". Unset DEVELOPER_DIR (and SDKROOT) so the
            # stub falls back to /Library/Developer/CommandLineTools and
            # finds the real Xcode CLT clang. CLT is a hard dependency
            # for the bundled GHC anyway, since GHC was rewritten to use
            # /usr/bin tools at bundle time.
            if env -u DEVELOPER_DIR -u SDKROOT \
                    "$mcmonad_ghc" --make "$mcmonad_hs" -o "$mcmonad_bin" -fforce-recomp -v0 \
                && "$mcmonad_bin" --protocol-version > "$mcmonad_bin.proto"; then
                :
            else
                echo "mcmonad: recompile failed during home-manager activation; removing stale custom binary so the launcher falls back to bundled" >&2
                rm -f "$mcmonad_bin" "$mcmonad_bin.proto"
            fi
        fi

        # The launchd plist references stable user paths, so home-manager
        # won't reload the agent when only the bundle contents change.
        # Kickstart so the running process picks up the new binaries.
        run launchctl kickstart -k "gui/$(id -u)/org.nix-community.home.mcmonad" 2>/dev/null || true
      '';

    launchd.agents.mcmonad = {
      enable = true;
      config = {
        ProgramArguments = [
          "${bundlePath}/Contents/MacOS/mcmonad-launcher"
          "--daemon"
        ];
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "${homeDir}/Library/Logs/mcmonad-launcher.log";
        StandardErrorPath = "${homeDir}/Library/Logs/mcmonad-launcher.log";
      };
    };
  };
}
