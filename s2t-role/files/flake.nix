{
  description = "Local Speech-to-Text Environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        pkgsCuda = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            cudaSupport = true;
          };
        };

        mkEnv = pkgsSet: whisperPkg:
          let
            runtimeDeps = with pkgsSet; [
              whisperPkg
              teleport
              podman
              shadow
              pipewire
              wl-clipboard
              xclip
              libnotify
              jq
              curl
              keyd
              ydotool
              sox
              ffmpeg
              (python3.withPackages (p: [ p.evdev p.google-cloud-speech p.pika ]))
            ];

            controller = pkgsSet.writeScriptBin "s2t-controller" (builtins.readFile ./scripts/controller.sh);
            monitor = pkgsSet.writeScriptBin "s2t-monitor" (builtins.readFile ./scripts/monitor.py);
          in
          pkgsSet.symlinkJoin {
            name = "s2t-env";
            paths = [
              controller
              monitor
            ] ++ runtimeDeps;
          };

        whisperCpu = pkgs.whisper-cpp;
        cudaArchEnv = builtins.getEnv "S2T_CUDA_ARCH";
        cudaArch = if cudaArchEnv != "" then cudaArchEnv else "75";
        cudaForceMmqEnv = builtins.getEnv "S2T_CUDA_FORCE_MMQ";
        cudaForceMmq = (cudaForceMmqEnv != "") && (cudaForceMmqEnv != "0");

        whisperCudaBase =
          if pkgsCuda ? whisper-cpp-cuda then pkgsCuda.whisper-cpp-cuda
          else if pkgsCuda.whisper-cpp ? override then pkgsCuda.whisper-cpp.override { cudaSupport = true; }
          else pkgsCuda.whisper-cpp;

        whisperCuda = whisperCudaBase.overrideAttrs (old: {
          cmakeFlags =
            (old.cmakeFlags or [])
            ++ [ "-DCMAKE_CUDA_ARCHITECTURES=${cudaArch}" ]
            ++ (if cudaForceMmq then [ "-DGGML_CUDA_FORCE_MMQ=ON" ] else []);
        });
        
      in
      {
        packages.default = mkEnv pkgs whisperCpu;
        packages.cuda = mkEnv pkgsCuda whisperCuda;
        
        apps.default = {
            type = "app";
            program = "${self.outputs.packages.${system}.default}/bin/s2t-controller";
        };

        apps.cuda = {
            type = "app";
            program = "${self.outputs.packages.${system}.cuda}/bin/s2t-controller";
        };
      }
    );
}
