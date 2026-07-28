//! Standalone reimplementation of `CertificateOrder::cache_key()` (see
//! `src/conf/order.rs`, `src/conf/identifier.rs` and `src/conf/pkey.rs` in the parent crate).
//!
//! Kept deliberately independent of the `nginx-acme` crate itself: that crate only builds as an
//! nginx `cdylib` module and its types are tied to `ngx_pool_t`/`ngx_str_t`, so this tool mirrors
//! the relevant logic with owned `String`s instead. If the identifier normalization rules or the
//! `Identifier`/`PrivateKey` enum layouts change upstream, update this file to match.
use std::hash::{Hash, Hasher};
use std::net::IpAddr;

use siphasher::sip::SipHasher;

#[derive(Hash)]
enum Identifier {
    Dns(String),
    Ip(String),
}

// Order and variants must match `PrivateKey` in `src/conf/pkey.rs` exactly: the derived `Hash`
// impl feeds the variant's declaration index into the hasher.
#[derive(Hash)]
enum PrivateKey {
    Ecdsa(u32),
    Rsa(u32),
    File(Vec<u8>),
    #[allow(dead_code)]
    Unset,
}

struct ByteRecorder(Vec<u8>);

impl Hasher for ByteRecorder {
    fn write(&mut self, bytes: &[u8]) {
        self.0.extend_from_slice(bytes);
    }

    fn finish(&self) -> u64 {
        unreachable!("only used to record bytes fed to the real SipHasher")
    }
}

/// Ported from `validate_dns_identifier` in `src/conf/order.rs`.
/// Returns true if the name needs to be lowercased.
fn validate_dns_identifier(name: &str) -> Result<bool, String> {
    #[derive(PartialEq, Eq)]
    enum State {
        Start,
        Label,
        Dot,
        Wildcard,
    }

    let mut alloc = false;
    let mut state = State::Start;

    for (i, ch) in name.bytes().enumerate() {
        state = match ch {
            0x00..=0x20 | 0x7f.. => return Err(format!("invalid character {ch:x} at position {i}")),

            b'*' if state == State::Start => State::Wildcard,
            b'.' if state != State::Dot => State::Dot,
            _ if state == State::Wildcard => {
                return Err(format!("unexpected character '{}' at position {i}", ch as char))
            }

            b'A'..=b'Z' => {
                alloc = true;
                State::Label
            }
            b'0'..=b'9' | b'a'..=b'z' | b'-' | b'_' | b'~' => State::Label,
            b'%' => State::Label,
            b'!' | b'$' | b'&' | b'\'' | b'(' | b')' | b'+' | b',' | b';' | b'=' => State::Label,

            _ => return Err(format!("unexpected character '{}' at position {i}", ch as char)),
        };
    }

    if state != State::Label {
        return Err("does not end with a label".into());
    }

    Ok(alloc)
}

/// Ported from `parse_ip_identifier` in `src/conf/order.rs`: identifiers that parse as an IP
/// address are always stored in their canonical textual form.
fn parse_ip_identifier(value: &str) -> Option<String> {
    value.parse::<IpAddr>().ok().map(|addr| addr.to_string())
}

/// Ported from `CertificateOrder::try_add_identifier` in `src/conf/order.rs`.
fn add_identifier(identifiers: &mut Vec<Identifier>, value: &str) -> Result<(), String> {
    if let Some(addr) = parse_ip_identifier(value) {
        identifiers.push(Identifier::Ip(addr));
        return Ok(());
    }

    let realloc = validate_dns_identifier(value)?;

    if let Some(host) = value.strip_prefix('.') {
        let www = format!("www.{host}").to_ascii_lowercase();
        let bare = www[4..].to_string();
        identifiers.push(Identifier::Dns(www));
        identifiers.push(Identifier::Dns(bare));
    } else if realloc {
        identifiers.push(Identifier::Dns(value.to_ascii_lowercase()));
    } else {
        identifiers.push(Identifier::Dns(value.to_string()));
    }

    Ok(())
}

/// Ported from `PrivateKey`'s `TryFrom<ngx_str_t>` in `src/conf/pkey.rs`.
fn parse_key(spec: &str) -> Result<PrivateKey, String> {
    let (kind, bits) = match spec.split_once(':') {
        Some((k, b)) => (k, Some(b)),
        None => (spec, None),
    };

    match kind {
        "ecdsa" => match bits {
            None | Some("256") => Ok(PrivateKey::Ecdsa(256)),
            Some("384") => Ok(PrivateKey::Ecdsa(384)),
            Some("521") => Ok(PrivateKey::Ecdsa(521)),
            Some(b) => Err(format!("unsupported curve: {b}")),
        },
        "rsa" => match bits {
            None | Some("2048") => Ok(PrivateKey::Rsa(2048)),
            Some("3072") => Ok(PrivateKey::Rsa(3072)),
            Some("4096") => Ok(PrivateKey::Rsa(4096)),
            Some(b) => Err(format!("unsupported key size: {b}")),
        },
        "file" => {
            let path = bits.ok_or("file: requires a path, e.g. file:/etc/ssl/key.pem")?;
            eprintln!(
                "warning: `file:` key hashing is not verified against nginx-sys's ngx_str_t \
                 Hash impl -- treat this result as unconfirmed"
            );
            Ok(PrivateKey::File(path.as_bytes().to_vec()))
        }
        _ => Err(format!("unknown key kind: {kind} (expected ecdsa[:bits], rsa[:bits] or file:path)")),
    }
}

fn first_name(identifiers: &[Identifier]) -> Option<&str> {
    let dns = identifiers.iter().find(|x| matches!(x, Identifier::Dns(_)));
    dns.or_else(|| identifiers.first()).map(|x| match x {
        Identifier::Dns(v) | Identifier::Ip(v) => v.as_str(),
    })
}

fn cache_key(identifiers: &[Identifier], key: &PrivateKey) -> Option<String> {
    let name = first_name(identifiers)?;

    // Mirrors `CertificateOrder`'s manual `Hash` impl (src/conf/order.rs:57-64): identifiers,
    // then key, fed straight into one `SipHasher::default()` (SipHash-2-4, keys 0/0).
    let mut recorder = ByteRecorder(Vec::new());
    identifiers.hash(&mut recorder);
    key.hash(&mut recorder);

    let mut hasher = SipHasher::default();
    hasher.write(&recorder.0);

    Some(format!("{name}-{:x}", hasher.finish()))
}

fn print_usage(prog: &str) {
    eprintln!(
        "usage: {prog} <identifier>... [--key ecdsa[:256|384|521] | rsa[:2048|3072|4096] | file:<path>]\n\n\
         <identifier> is anything you'd pass to `server_name` / `acme_certificate`:\n  \
         a DNS name, a leading-dot name (expands to \"www.\" + bare form), or an IP address.\n\n\
         --key defaults to ecdsa:256, matching PrivateKey::default().\n\n\
         example: {prog} example.com .example.net --key rsa:2048"
    );
}

fn main() {
    let mut args = std::env::args();
    let prog = args.next().unwrap_or_else(|| "nginx-acme-cache-key".into());

    let mut raw_identifiers = Vec::new();
    let mut key_spec: Option<String> = None;

    let mut it = args.peekable();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "-h" | "--help" => {
                print_usage(&prog);
                return;
            }
            "--key" => {
                key_spec = Some(it.next().unwrap_or_else(|| {
                    eprintln!("--key requires a value");
                    std::process::exit(2);
                }));
            }
            _ => raw_identifiers.push(arg),
        }
    }

    if raw_identifiers.is_empty() {
        print_usage(&prog);
        std::process::exit(2);
    }

    let mut identifiers = Vec::new();
    for value in &raw_identifiers {
        if let Err(e) = add_identifier(&mut identifiers, value) {
            eprintln!("invalid identifier \"{value}\": {e}");
            std::process::exit(1);
        }
    }

    let key = match parse_key(key_spec.as_deref().unwrap_or("ecdsa:256")) {
        Ok(k) => k,
        Err(e) => {
            eprintln!("invalid --key: {e}");
            std::process::exit(1);
        }
    };

    match cache_key(&identifiers, &key) {
        Some(id) => println!("{id}"),
        None => unreachable!("checked raw_identifiers is non-empty above"),
    }
}
