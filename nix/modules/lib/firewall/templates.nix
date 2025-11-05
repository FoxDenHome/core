{ ... }: {
  trusted = comment: [
    {
      source = "10.1.0.0/16";
      comment = "trusted-mgmt-${comment}";
    }
    {
      source = "fd2c:f4cb:63be:1::/64";
      comment = "trusted-mgmt-${comment}";
    }
    {
      source = "10.2.0.0/16";
      comment = "trusted-lan-${comment}";
    }
    {
      source = "fd2c:f4cb:63be:2::/64";
      comment = "trusted-lan-${comment}";
    }
  ];
}
