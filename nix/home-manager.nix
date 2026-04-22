flake: { config, lib, pkgs, ... }:

let
  cfg = config.services.mcmonad;
  pkg = flake.packages.${pkgs.stdenv.hostPlatform.system}.default;
  homeDir = config.home.homeDirectory;
in
{
  options.services.mcmonad = {
    enable = lib.mkEnableOption "mcmonad tiling window manager";
  };

  config = lib.mkIf cfg.enable {
    launchd.agents.mcmonad-core = {
      enable = true;
      config = {
        ProgramArguments = [ "${pkg}/bin/mcmonad-core" ];
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "${homeDir}/Library/Logs/mcmonad-core.log";
        StandardErrorPath = "${homeDir}/Library/Logs/mcmonad-core.log";
      };
    };

    launchd.agents.mcmonad = {
      enable = true;
      config = {
        ProgramArguments = [ "${pkg}/bin/mcmonad" ];
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "${homeDir}/Library/Logs/mcmonad.log";
        StandardErrorPath = "${homeDir}/Library/Logs/mcmonad.log";
      };
    };
  };
}
