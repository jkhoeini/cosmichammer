{
  description = "Hammerspoon — macOS desktop automation with Lua";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};

      version = "0.1.0";
      src = pkgs.fetchurl {
        url = "https://github.com/jkhoeini/hammerspoon/releases/download/v${version}/Hammerspoon-${version}-macos-arm64.dmg";
        hash = "sha256-+t0MoS/s2tfICGVZNQphsL65CprLuwFPncjeiBrMWbg=";
      };

      hammerspoon = pkgs.stdenvNoCC.mkDerivation {
        pname = "hammerspoon";
        inherit version src;
        nativeBuildInputs = [ pkgs.undmg ];
        sourceRoot = ".";
        installPhase = ''
          runHook preInstall
          mkdir -p $out/Applications
          cp -r Hammerspoon.app $out/Applications/
          runHook postInstall
        '';
        meta = {
          description = "macOS desktop automation with Lua";
          homepage = "https://github.com/jkhoeini/hammerspoon";
          platforms = [ "aarch64-darwin" ];
        };
      };
    in
    {
      packages.${system} = {
        default = hammerspoon;
        inherit hammerspoon;
      };
    };
}
