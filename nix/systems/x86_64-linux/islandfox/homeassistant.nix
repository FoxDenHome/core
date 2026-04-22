{ ... }:
{
  foxDen.services.kanidm.oauth2.homeassistant = {
    present = true;
    public = true;
    displayName = "HomeAssistant";
    preferShortUsername = true;
    originUrl = "https://homeassistant.foxden.network/auth/oidc/callback";
    scopeMaps.login-users = [
      "email"
      "groups"
      "openid"
      "profile"
    ];
  };
}
