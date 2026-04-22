{
  description = "mcmonad — mac-native tiling window manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        hsPkgs = pkgs.haskellPackages;
      in
      {
        packages = {
          mcmonad = hsPkgs.callCabal2nix "mcmonad" ./haskell { };

          mcmonad-core = pkgs.stdenv.mkDerivation {
            pname = "mcmonad-core";
            version = "0.1.0";
            src = pkgs.lib.cleanSource ./core;
            buildPhase = ''
              swift build -c release --package-path . --scratch-path .build
            '';
            installPhase = ''
              mkdir -p $out/bin
              cp .build/release/mcmonad-core $out/bin/
            '';
            __impureHostDeps = [
              "/usr/bin/xcrun"
              "/usr/bin/swift"
              "/usr/bin/swiftc"
              "/Library/Developer/CommandLineTools"
              "/Applications/Xcode.app"
            ];
          };

          default = pkgs.symlinkJoin {
            name = "mcmonad";
            paths = [
              self.packages.${system}.mcmonad
              self.packages.${system}.mcmonad-core
            ];
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [
            (hsPkgs.ghcWithPackages (hp: [
              hp.xmonad
              hp.aeson
              hp.network
              hp.QuickCheck
              hp.mtl
              hp.containers
              hp.bytestring
              hp.text
            ]))
            hsPkgs.cabal-install
            hsPkgs.haskell-language-server
            pkgs.jq
          ];
          shellHook = ''
            echo "mcmonad dev shell"
            echo "  Swift: $(swift --version 2>/dev/null | head -1 || echo 'not found')"
            echo "  GHC:   $(ghc --version)"
            echo "  cabal: $(cabal --version | head -1)"
          '';
        };
      }
    ) // {
      homeManagerModules.default = import ./nix/home-manager.nix self;
    };
}
