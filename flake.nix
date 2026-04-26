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
        packages = rec {
          mcmonad = hsPkgs.callCabal2nix "mcmonad" ./haskell { };

          # GHC with the mcmonad library available — used by recompile
          # so users can compile ~/.config/mcmonad/mcmonad.hs
          mcmonad-ghc = hsPkgs.ghcWithPackages (hp: [
            mcmonad
            hp.xmonad
            hp.xmonad-contrib
          ]);

          mcmonad-core = pkgs.stdenv.mkDerivation {
            pname = "mcmonad-core";
            version = "0.1.0";
            src = pkgs.lib.cleanSource ./core;

            # Swift must use the system Xcode/CommandLineTools SDK, not the
            # Nix-provided apple-sdk.  We clear the Nix cc-wrapper env that
            # injects the wrong SDK via VFS overlays.
            dontFixup = true;
            buildPhase = ''
              runHook preBuild

              # Clear Nix cc-wrapper environment
              unset NIX_CFLAGS_COMPILE NIX_LDFLAGS CC CXX

              export DEVELOPER_DIR=/Library/Developer/CommandLineTools
              export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
              export PATH="/usr/bin:$PATH"

              # Give SPM a writable cache/config directory
              export HOME="$TMPDIR"

              /usr/bin/swift build -c release \
                --package-path . \
                --scratch-path .build \
                --disable-sandbox

              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin $out/Resources
              cp .build/release/mcmonad-core $out/bin/
              cp Sources/MCMonadCore/Resources/MenuBarIcon.png $out/Resources/
              cp Sources/MCMonadCore/Resources/MenuBarIcon@2x.png $out/Resources/
              runHook postInstall
            '';
            __impureHostDeps = [
              "/usr/bin"
              "/Library/Developer/CommandLineTools"
              "/Applications/Xcode.app"
            ];
          };

          default = if pkgs.stdenv.isDarwin then
            pkgs.symlinkJoin {
              name = "mcmonad";
              paths = [
                self.packages.${system}.mcmonad
                self.packages.${system}.mcmonad-core
              ];
            }
          else
            self.packages.${system}.mcmonad;

          mcmonad-app = import ./nix/app-bundle.nix {
            inherit pkgs;
            inherit mcmonad mcmonad-core mcmonad-ghc;
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [
            (hsPkgs.ghcWithPackages (hp: [
              hp.xmonad
              hp.xmonad-contrib
              hp.X11
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
            pkgs.socat
            pkgs.gh
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
