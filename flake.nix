{
  description = "macOS touch input for KD1 / Silicon Works SW4101C";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { nixpkgs, ... }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      app = pkgs.stdenv.mkDerivation {
        pname = "kdtouch";
        version = "0.1.0";
        src = pkgs.lib.fileset.toSource {
          root = ./.;
          fileset = pkgs.lib.fileset.unions [
            ./Sources
            ./Tests
            ./Resources
            ./Info.plist
            ./build.sh
          ];
        };
        nativeBuildInputs = [ pkgs.swift pkgs.zsh ];
        buildInputs = [ pkgs.apple-sdk_26 ];
        dontConfigure = true;
        # ビルド時に署名するため、その後はMach-Oを書き換えない。
        dontFixup = true;
        buildPhase = ''
          runHook preBuild
          zsh ./build.sh
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p "$out/Applications"
          cp -R build/KDTouch.app "$out/Applications/"
          runHook postInstall
        '';
        meta = {
          description = "Touch input for KD1 / Silicon Works SW4101C on macOS";
          homepage = "https://github.com/yuki-yano/kdtouch";
          license = pkgs.lib.licenses.mit;
          platforms = [ system ];
        };
      };
    in {
      packages.${system}.default = app;
      checks.${system}.default = app;
      devShells.${system}.default = pkgs.mkShell {
        inputsFrom = [ app ];
      };
    };
}
