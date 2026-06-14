{
  description = "Cosmic Hammer — macOS desktop automation with Lua";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};

      version = "0.7.0";
      src = pkgs.fetchurl {
        url = "https://github.com/jkhoeini/cosmichammer/releases/download/v${version}/Cosmic-Hammer-${version}.dmg";
        hash = "sha256-oW9yE4kjmf7i5nzt1Dkq5JXUmy1UuP+Wdd97lY2vmOc=";
      };

      cosmic-hammer = pkgs.stdenvNoCC.mkDerivation {
        pname = "cosmic-hammer";
        inherit version src;
        nativeBuildInputs = [ pkgs.undmg ];
        sourceRoot = ".";
        installPhase = ''
          runHook preInstall
          mkdir -p $out/Applications
          cp -r "Cosmic Hammer.app" $out/Applications/
          runHook postInstall
        '';
        meta = {
          description = "macOS desktop automation with Lua";
          homepage = "https://github.com/jkhoeini/cosmic-hammer";
          platforms = [ "aarch64-darwin" ];
        };
      };
    in
    {
      packages.${system} = {
        default = cosmic-hammer;
        inherit cosmic-hammer;
      };
    };
}
