self:

import ./common.nix {
  inherit self;
  install = cfg: {
    home.packages = [ cfg.package ];
  };
}
