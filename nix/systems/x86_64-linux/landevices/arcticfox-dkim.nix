{ ... }:
let
  dkimPrefix = "arcticfox._domainkey";
in
{
  config.foxDen.dns.records = [
    {
      fqdn = "${dkimPrefix}.doridian.net";
      type = "TXT";
      ttl = 3600;
      value = "v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA3f9m7AcniGGUN+1XjLO65/vnMsj9gPqL8VpAZTNn8yshIB8pgOau599Z+a8u6OEUyNdoEiGGXhQ+cbaheZ73itCiyhpcMsr4vW862WzZxEqKk/19a8AK1956PhNUMATJ51I7xBI+2ktswwW8dZq5NXvB7Yobah3H+cyVWpJLyZsIt+P0U7+oNRsXUeLeRxBmkRZjGhnsrWx6DlU4sTg1o97sZ2nbTX6Nzi+UxG9abXUfdfcvkgpWbXjpI+EuPeaIHJ8+HFuVKzsWEA4Fajfq0Et2ROjVyzoqX7ndxLOaSHzLFXPqYo2OrDHoPrk1NQ6wLRLojrxfginoHebuSaSuUQIDAQAB";
      horizon = "*";
    }
    {
      fqdn = "${dkimPrefix}.doridian.de";
      type = "TXT";
      ttl = 3600;
      value = "v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAukzkScpLJLJkPp0uGickXcocADk8ubFB24f3y66blR3fYhBDaYHmKNnJDzzlQEmZcSvrZLezM39EyBJVXIUS7zdtG2R2Dpv4KEAUFzA63D0wTzF2KX3YMyJz5enNTAKw7qPRPqZdhpDiBVq+gjPK++MuOkRa/ejZTPQfibsv5gZULOv11A9PjfxyB93AK285NXWthcXqCO5mB06zrz2hbkDLTwzSwsLKpWaxcIXEy2/ynnxqAZrNm30dUDE+0wp39gLP9egjsaqljHTklV+TufM84v1Z+IgnEG7YWardIUs4jorMi+jWviBDHxkbstYKzJUd/kzUqtLkp5YWHzHVrQIDAQAB";
      horizon = "*";
    }
    {
      fqdn = "${dkimPrefix}.f0x.es";
      type = "TXT";
      ttl = 3600;
      value = "v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAracUz6uiFBmgvBzygy5K3IFz6fU7ABcNkqFzXM/d9wUp2yFXweOI49sSfFRKAhjxN5fj8xslfWkIFUMmgQNOy1f04RkQPp95mPaxGkkALaENFsbYRloxt7BCVSbw9Jryqm7Fe8dIETR/ruUK3fCVhnDKPw8MTkDQdSNM144q40jvpJGpwzluLXO+wBAgKrIuD7TJrudlqLnIvV9p8Ej4r7V8EQHQrm1DLmACK00Ond2JzUk15Tcj8ZP5hVneOybefdDiKytFoA6g2tcTuiDYiKgR0kHiHsGPH9t1pWo/kdy5Awfh97SA32rLzHZQEEf/oH5TII9Vfr93LCnm3Tg6dwIDAQAB";
      horizon = "*";
    }
    {
      fqdn = "${dkimPrefix}.foxcav.es";
      type = "TXT";
      ttl = 3600;
      value = "v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEArrTbZ+5eHMvI2ft86CZsXTW/bsknAsaEoBIFKMSjfcQIDlLzj3PErXvQiNkYJaK6mlf+D1Aq804qoAyePATg6kbreTgOIlkhJ/3WA61GfSVUpecwsvt3i38h9AcFemk6y+DMXmcR4/OBRLwXxYUvMJLMZS/EYDBqf0qklrLo29vXCjUZ4pBD1vzH7g38iG3LD1adObrVCBmKjgyFB0XHN7abRwDvnacwwEmcj7ZTTPebgkP7Y1MI3wGxaTVcDMm9NGorKf0uO2tiqCjPT+CyxOZHfZgg5yTFagbt4IK3O5wN25J6Ce2r7VN3+Ol2Vmgk6+zIoPGpeEAVO3IuJu0i2QIDAQAB";
      horizon = "*";
    }
    {
      fqdn = "${dkimPrefix}.darksignsonline.com";
      type = "TXT";
      ttl = 3600;
      value = "v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEApfeAjE0+HWB81Xqd4oL1eZ60bVLOLjKsnx749e8/dT8BDfMuu4HlLGI9JOWvIss14qCpyMWu8KlC8grr+pocxoWYlJzfDPbWEKhaQBtpSQqPCiiAt+w1H2mr3NEQau0yrHtzv709Glpp1K2W+qOdvQgDw6YHqPhYxKlMY9Rdhv2VfY6jnzEGpJFVuDORXyWKYzl7evvB+lldm6xkxAT5bW3SYgQY5DPdlmG80v/hHhQBnHc8b/N1eM0FTA1dlSTrRODXMNkS0yuiN1kj96CwyQPN4dnY6uAXwrcM4LyCtbL133SgEfNS5gnNL3J+iFC2oAhx2gRGFl4FtFJKTrzRHwIDAQAB";
      horizon = "*";
    }
    {
      fqdn = "${dkimPrefix}.zoofaeth.de";
      type = "TXT";
      ttl = 3600;
      value = "v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAlxpjKvLc5A0fQclpYjkmsWZrofVlShA+P74hJbpyqbn48kYljBoAdPn0tqK6doJQdQQgGvd5VKnbZbhEiLCsGpJ31EBaQHyUM2oYGFnoC8qIeWi4deQhw/HNpI8dhT5Bt2a4bEgL6xhIMRmaeTrXqov67nE2tXiFLoluQqW3K8zcohaHZ1HPMEeSoff8EXSZBQvX+z8ZunGIUtNTypngKNUndvo0A3oraheQJ8zBibz3wBGILor/0w1IhscXceSxkw29vETo1D0Od5POResbGDNoivdazz7OQWtXtclYnG7tfwD/sJP0bjLQqyIfGWFqQbaanty7c/ZqP8Fkl8xM2QIDAQAB";
      horizon = "*";
    }
    {
      fqdn = "${dkimPrefix}.candy-girl.net";
      type = "TXT";
      ttl = 3600;
      value = "v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAljBmbiHNtHgHYBtq1GH9dGL3B/D3OGKtLgJ02I//siiisOV05aqQTq2QpzvhJ3QjyeeAMSLO5jNLfe9CaoUzSfqo6r2CNvy9Eu1e7BmP/TQir+QVaZ5IT0SZ05pIGbs/5C1hGiLEAnHrIeMogLYlq082cxEncc/X3JWpfuca3JrbmgvaSFWpLZg3wKEVO3lEqCN1uhe/XEcTMh9VF+E7yY1GjEtTtLsjfeTX8cQE8Azx1OQjW4xlU+tcqFjMJGGlz5Py6xOA5D4Z5qieOUGh1u9O/6CwjlSrAMHIgs58e2lpomtu5vbyPCU5H0uW7WObp185VahE4snKrrj8Q6lcfwIDAQAB";
      horizon = "*";
    }
  ];
}
