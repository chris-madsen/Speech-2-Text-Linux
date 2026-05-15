{
  description = "Pop!_OS + NVIDIA: faster-whisper (large-v3-turbo) devshell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";

      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      python = pkgs.python311;
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          python
          pkgs.ffmpeg
          pkgs.teleport
          pkgs.podman
          pkgs.shadow
          pkgs.cudatoolkit
          pkgs.google-cloud-sdk
          pkgs.git
          python.pkgs.pip
        ];

        shellHook = ''
          export LD_LIBRARY_PATH=${pkgs.cudatoolkit}/lib:${pkgs.cudatoolkit.lib}/lib:${pkgs.stdenv.cc.cc.lib}/lib:$LD_LIBRARY_PATH
          echo "CUDA toolkit: ${pkgs.cudatoolkit}"
        '';
      };
    };
}
