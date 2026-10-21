self:

import ./common.nix {
  inherit self;
  install = cfg: {
    environment.systemPackages = [ cfg.package ];
  };
}
