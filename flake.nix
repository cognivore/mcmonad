{
  description = "awake — bounded macOS lid-closed-awake mode that cleanly puts the machine back to sleep";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        awake = pkgs.stdenvNoCC.mkDerivation {
          pname = "awake";
          version = "0.1.0";
          src = ./.;
          dontBuild = true;
          installPhase = ''
            install -Dm755 bin/awake $out/bin/awake
          '';
          meta = with pkgs.lib; {
            description = "Bounded macOS lid-closed-awake mode that cleanly puts the machine back to sleep";
            platforms = platforms.darwin;
            mainProgram = "awake";
            license = licenses.mit;
          };
        };
      in {
        packages = {
          default = awake;
          awake = awake;
        };
      });
}
