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
