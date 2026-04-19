{ ... }:
{
  # TODO: Remove on next nixpkgs update as PR merged: https://github.com/NixOS/nixpkgs/pull/510953
  config.boot.initrd.luks.cryptoModules = [
    "aes"
    "blowfish"
    "twofish"
    "serpent"
    "cbc"
    "xts"
    "lrw"
    "sha1"
    "sha256"
    "sha512"
    "af_alg"
    "algif_skcipher"
    "cryptd"
    "input_leds" # for capslock LED on most keyboards in case decryption requires password
  ];
}
