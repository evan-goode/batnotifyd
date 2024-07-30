{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, utils }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in {
        packages = {
          batnotifyd = pkgs.stdenv.mkDerivation {
            pname = "batnotifyd";
            version = "1.0";
            src = ./.;
            nativeBuildInputs = with pkgs; [ pkg-config libnotify udev zig ];
            buildPhase = ''
              XDG_CACHE_HOME=xdg_cache zig build
            '';
            installPhase = ''
              mkdir -p $out/bin/
              cp zig-out/bin/batnotifyd $out/bin/
            '';
          };
        };

       devShell = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            pkg-config
            libnotify
            udev
            zig
            gdb
          ];
        };

        defaultPackage = self.packages.${system}.batnotifyd;
      });
}
