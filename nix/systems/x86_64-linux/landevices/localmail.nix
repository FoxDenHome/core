{ lib, ... }:
let
  dkimEntries = {
    "darksignsonline.com" = {
      router = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAunIPLsrGvNWh05gkQzdbSPlbhS8PWwzn63cOAL9ON9eZAnfaHvfqx9VQXZajZrWsVPumLkMktgbwAR1jOAUid7aT9ep3/IUyiqAqZtkY9IuDxDpodbJMlUdTJ/XyDprS8t61JgVKrQaB5pPbt8T6u9XBfjBPqVqTEzm/RkK9gM/Ijt+ncEK/bGtw6/rQlodh6ka7d7kgtdoUcJkRPw3lOAXRBJ160YMSp0Ti0ToJIu6JsjpxOwt1HKZoJNrLJSngcWGAAh6wA0q30Hy/BV3FuHBmhZQr4yUl2j0Ix+Iy9lHGc9YDOmacNd4P/lmQU7kgkx4zhjKJXgd4sHS37SuP1wIDAQAB";
      router-backup = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAoVe1YQYu81BGARQTSmeA8sZvwrjrAO4XAKebWYujYBrnGSkGT65pOUWYH9EHB5iQw58qBGD4BBbvLEngNIWUaua86yTOHL2jU/G47/WA/oDXHIVWcZ02qZywbhAXbmo+Dfd7jWR6khO8nmgjDE+PgPIPhLpY8L3YSA8xSEZEZ2w6a1hDOjxXltKWlsW/XpMxoTIYgUvlp+kvKtfTmHvXvzFCnDjs8+EruWGVrRewJ98eBje+CEpoMIEc6PXGLpE2sN9JKyVoVPRes58QdCeRX8L51WBGTDnuZsVVSAoo8XK0ftleHdfIJX3QNVEemxLluZOzAettSXM50R/xUyBnGQIDAQAB";
    };
    "foxcav.es" = {
      router = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAsbBrGoPhkVi12PY3i1AqeCA9YShQ9IS5FiKqbG4WjiQtSpY9G9Ib6Ex8nTV5hcFO/HEWnzuebAMNpBrkTurDLWDb2ruzuI5EZ1ESeRv6scT1ln1RaIx9nFKomVfAsAFoaZW9qJPK0haeWzWRSXRcMS2M+DLgReQ1GSRkiA43vWMxmN6LB56bFCCWqewisfRKHZJ9riFFUdS1QKAqK5cR1FSVEHtZ23eI+KebnHvFCO7eixYH2PtG5xJsVgjHA5qtShS52sjwqoIyYbhBsS09tZxssAkKxwCNDr/YgL0CKkK++oUcUhwWTQ6/MXlYb9SjeuB3vDFJzWq0cbcTc1hdwwIDAQAB";
      router-backup = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAr7eFy+ZtPg6gxSQ3n065ErHjQidxES9siSBfPYaJ6+yn2nQDZYPvLX8ZIrZ9cOqyROR1TVAlM/OpbvuH3GLl3FUxOHdFCUP6QnW1NqS52oCOWMBTp9BvsDvSh9LjEayADYW/c9gy2jzOXgfH5LI5wJg6udUcDdr2NIHJNI38p0XSDcOdNxKn0qcckJWQOp3y4DQ16s1CLXsnBc2vPRFYPyJSjA8AN0g5SGaBSDouiEax34UOU9zeNFI/D4FxOPVSBnFav3ExvHMTfi5BdfrRozTqCgqWzwTWWsdw6PDAT+XgHoLx2dinY+4DGt40UPC3eF5as8zP1B9e4co0i+Np4wIDAQAB";
    };
    "foxden.network" = {
      router = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAs6Xols0j8gQIRkA8dbS8BQbyMeYdpW96PvuAQ2Wz4TqquMG1tzuOq2q8WD38lbl7eyRrKW17B4F/yr8cA05cxi2ghCVM8eABBPMLaBprzbGWBN3YwPOD3wuPsXEa2Z+C4u6zxo/p8uGUJM7zhebrltNvrDHCDUQ5qbqGs0n8vNzM/X3FjVmehsAT/PSKXVFP3gXAyvAkg8h8Js95b2duYwlPywQUCSVcrIYqQH5QYkal9swa8sXSluN/2MxAjlIXULCAN8N3VGO6NxUgXsN8BdYOv+FLYXth2gqUmzdWPh/+65jlNM29flbEEys8HeiYtFgLELQ76pw7Y/5Wwt+oSwIDAQAB";
      router-backup = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAseHzdMUuMMH3PrdbAgoIjUSkpXe5V4YH+pW5UPlxchWI2YxlmT++z3tW21OSv1qKYwDw0UGR5rIS/MVm3B3eBEsmTv0wQJ+ueP8qRpA1BU+7U7g2LtYMpdKkx5W2+zK0X93Bkt4EUKbwEZ/bMR2LgLJvkMNG2ruBiEOzpft7I0Jhv94AcuDtIF9on/7et9Vw/7jbTS+EiHt9JfgkGoNPJm0PDPQ7NAcvTA1y0d6NZtnXxAUfcVIeD78wDfEbs/IfaI5Jf1X4rD+1MYP5NJjIMUkH1BRwb+fF1Z82lyJRPqqODOzl6M+4oRfOEE+xeC6mJgv0RxudlWoMgSiVtmJ4WQIDAQAB";
    };
  };
in
{
  config.foxDen.dns.records = lib.mkMerge (
    map (
      domain:
      map (record: {
        fqdn = "${record.name}._domainkey.${domain.name}";
        type = "TXT";
        ttl = 3600;
        inherit (record) value;
        horizon = "external";
      }) (lib.attrsToList domain.value)
    ) (lib.attrsToList dkimEntries)
  );
}
