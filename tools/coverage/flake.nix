{
  # Pin of the sibling corruption_reader for ./corruption-coverage, kept out
  # of the main flake on purpose: that repository is private, and a private
  # input in jp2z's own flake would make every `nix build` and `nix develop`
  # of this public project depend on access to it. Here only the coverage
  # driver pays that cost. Consumer contract: corruption_reader
  # docs/consumer_cli.md, section 8 (pin a commit, fetch over SSH, pin
  # forward deliberately when a new version is announced).
  description = "corruption-reader executable pinned for jp2z's ./corruption-coverage";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    corruption-reader = {
      url = "git+ssh://git@github.com/pmarreck/corruption_reader?rev=21ee639537644c81ada3e780c19608817dda92ca";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, corruption-reader }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems f;
    in {
      packages = forAll (system: {
        default = corruption-reader.packages.${system}.default;
      });
    };
}
