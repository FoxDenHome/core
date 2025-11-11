FROM docker.io/nixos/nix

RUN nix-channel --update && \
    nix profile add nixpkgs#nixfmt-rfc-style && \
    nix profile add nixpkgs#nixfmt-tree
