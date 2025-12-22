let
  marshall = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL2vmQG3o3yMTXUbHYM7evCpUo/V+gK8Lofajt/hEjrB navis";
  server = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICIlaza7NGWBigAEDCmDqRNXm62/mrCt1LXLb49EDHNW marshall@polaris-nix";
  system = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJe8dn/plNp53zGSzHTZjjrQbo94WWMZf7508agyIwQQ agenix";
in {
  "bsky_pds.age".publicKeys = [marshall server system];
  "cifs.age".publicKeys = [marshall server system];
  "cloudflare_token.age".publicKeys = [marshall server system];
  "forgejo_token.age".publicKeys = [marshall server system];
  "helium_hmac.age".publicKeys = [marshall server system];
  "mailer_passwd.age".publicKeys = [marshall server system];
  "passwd.age".publicKeys = [marshall system];
  "slskd_env.age".publicKeys = [marshall server system];
  "zipline_secret.age".publicKeys = [marshall server system];
  "zipline_token.age".publicKeys = [marshall system];
}
