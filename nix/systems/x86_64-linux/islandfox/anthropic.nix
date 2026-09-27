{ config, ... }:
{
  sops.secrets."anthropic-oauth-secret" = config.lib.foxDen.sops.mkIfAvailable { };
  foxDen.dns.records = [
    {
      fqdn = "foxden.network";
      type = "TXT";
      ttl = 3600;
      value = "anthropic-domain-verification-6kmvr0=LAbewwKo7TUTgHkmwEu5HSvOT";
      horizon = "*";
    }
  ];
  services.kanidm.provision.systems.oauth2.anthropic = config.lib.foxDen.sops.mkIfAvailable {
    present = true;
    public = false;
    displayName = "Anthropic (Claude)";
    basicSecretFile = config.sops.secrets."anthropic-oauth-secret".path;
    originUrl = "https://auth.workos.com/sso/oidc/DCfxCoVBEWVpWzYmzPI21m3zu/callback";
    originLanding = "https://claude.ai";
    scopeMaps.login-users = [
      "email"
      "groups"
      "openid"
      "profile"
    ];
  };
}
