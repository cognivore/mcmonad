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
        # Rust for the core, the FFI and the guard. Swift is the system
        # Xcode's, called outside this shell by build.sh.
        devShells.default = pkgs.mkShell {
          packages = [ pkgs.cargo pkgs.rustc pkgs.clippy pkgs.rustfmt ];
        };
        packages = {
          default = awake;
          awake = awake;
        };
      });
}
