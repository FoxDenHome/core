{ nixpkgs, ... }:
let
  get = (
    attrPath: nixosConfigurations:
    nixpkgs.lib.filterAttrs (name: val: val != null) (
      nixpkgs.lib.attrsets.mapAttrs (
        name: val: (nixpkgs.lib.attrsets.attrByPath attrPath null val.config)
      ) nixosConfigurations
    )
  );

  getList = (
    attrPath: nixosConfigurations:
    nixpkgs.lib.lists.flatten (nixpkgs.lib.attrsets.attrValues (get attrPath nixosConfigurations))
  );
in
{
  get = get;
  getList = getList;

  getAttrSet = (
    attrPath: nixosConfigurations: nixpkgs.lib.mergeAttrsList (getList attrPath nixosConfigurations)
  );
}
