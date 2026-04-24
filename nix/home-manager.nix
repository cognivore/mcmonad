flake: { config, lib, pkgs, ... }:

let
  cfg = config.services.mcmonad;
  flakePkgs = flake.packages.${pkgs.stdenv.hostPlatform.system};
  pkg = flakePkgs.default;
  homeDir = config.home.homeDirectory;
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
    # Declarative mcmonad.hs (when configFile is set)
    home.file.".config/mcmonad/mcmonad.hs" = lib.mkIf (cfg.configFile != null) {
      text = cfg.configFile;
    };
    # Single launchd agent that manages both processes via the launcher script.
    # The launcher starts mcmonad-core and mcmonad, monitors both, and restarts
    # whichever dies. The Haskell side also retries connecting to core on its own.
    launchd.agents.mcmonad = {
      enable = true;
      config = {
        ProgramArguments = [
          "${../scripts/mcmonad-launcher}"
          "--daemon"
        ];
        EnvironmentVariables = {
          MCMONAD_CORE_BIN = "${pkg}/bin/mcmonad-core";
          MCMONAD_HASKELL_BIN = "${pkg}/bin/mcmonad";
          MCMONAD_GHC = "${flakePkgs.mcmonad-ghc}/bin/ghc";
        };
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "${homeDir}/Library/Logs/mcmonad-launcher.log";
        StandardErrorPath = "${homeDir}/Library/Logs/mcmonad-launcher.log";
      };
    };
  };
}
