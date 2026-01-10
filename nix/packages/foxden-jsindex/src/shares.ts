import state from './state.js';
import files from './files.js';
import util from './util.js';

const MAX_DURATION = 7 * 24 * 3600; // 7 days in seconds

interface KeyStorage {
  encryption: CryptoKey;
  iv: Uint8Array;
  hmac: CryptoKey;
}

let encryptionKeyCache: KeyStorage | undefined;

const HASH_ALG_BYTES = 32;
const HASH_ALG = `SHA-${HASH_ALG_BYTES * 8}`;
const HMAC_ALG: HmacKeyGenParams = { name: 'HMAC', hash: HASH_ALG };

const CRYPTO_ALG_BYTES = 16;
const CRYPTO_ALG: AesKeyGenParams = {
  name: 'AES-CBC',
  length: CRYPTO_ALG_BYTES * 8,
};

async function getKeys(): Promise<KeyStorage> {
  if (encryptionKeyCache) {
    return encryptionKeyCache;
  }

  const keyStr = await state.setOnce('shares:keyStorage', async () => {
    const encryptionKey = await crypto.subtle.exportKey('raw', await crypto.subtle.generateKey(CRYPTO_ALG, true, ['encrypt', 'decrypt']));
    const hmacKey = await crypto.subtle.exportKey('raw', await crypto.subtle.generateKey(HMAC_ALG, true, ['sign', 'verify']));
    const iv = Buffer.allocUnsafe(CRYPTO_ALG_BYTES);
    await crypto.getRandomValues(iv);
    return Buffer.concat([new Uint8Array(hmacKey as ArrayBuffer), iv, new Uint8Array(encryptionKey as ArrayBuffer)]).toString('base64');
  });

  if (!keyStr) {
    throw new Error('Failed to get or generate keys');
  }

  const keyBuf = Buffer.from(keyStr, 'base64');
  const hmacKeyBuf = keyBuf.slice(0, HASH_ALG_BYTES);
  const iv = keyBuf.slice(HASH_ALG_BYTES, HASH_ALG_BYTES + CRYPTO_ALG_BYTES);
  const encryptionKeyBuf = keyBuf.slice(HASH_ALG_BYTES + CRYPTO_ALG_BYTES);

  encryptionKeyCache = {
    iv,
    encryption: await crypto.subtle.importKey('raw', encryptionKeyBuf, CRYPTO_ALG, false, ['encrypt', 'decrypt']),
    hmac: await crypto.subtle.importKey('raw', hmacKeyBuf, HMAC_ALG, false, ['sign', 'verify']),
  };

  return encryptionKeyCache;
}

function doError(r: NginxHTTPRequest, code: number, message: string): void {
  r.status = code;
  r.headersOut['Content-Type'] = 'application/json';
  r.sendHeader();
  r.send(JSON.stringify({ error: message }));
  r.finish();
}

async function create(r: NginxHTTPRequest): Promise<void> {
  const target = r.variables.request_filename;
  if (!target) {
    doError(r, 500, 'Could not determine request filename');
    return;
  }
  if (target.indexOf('\n') !== -1) {
    doError(r, 400, 'Invalid target path');
    return;
  }

  const durationStr = r.args.duration || '3600';
  const duration = parseInt(durationStr, 10);
  if (!isFinite(duration) || duration <= 0 || duration > MAX_DURATION) {
    doError(r, 400, `Invalid duration: must be between 1 and ${MAX_DURATION} seconds`);
    return;
  }

  const stat = await util.tryStat(target);
  if (!stat || (!stat.isFile() && !stat.isDirectory())) {
    doError(r, 400, 'Can only create shares to files or directories');
    return;
  }

  const slashIfDir = stat.isDirectory() ? '/' : '';
  const expiry = Math.ceil(Date.now() / 1000) + duration;

  const keys = await getKeys();
  const secureData = Buffer.from(`${expiry}\n${target}${slashIfDir}`);
  const hash = await crypto.subtle.sign(HMAC_ALG, keys.hmac, secureData);
  const token = await crypto.subtle.encrypt(
    {
      name: 'AES-CBC',
      iv: keys.iv,
    },
    keys.encryption,
    Buffer.concat([new Uint8Array(hash), secureData]),
  );

  const url = `/_share/${Buffer.from(token).toString('base64url')}${slashIfDir}`;
  if (r.variables.request_method?.toUpperCase() === 'POST') {
    r.status = 200;
    r.headersOut['Content-Type'] = 'application/json';
    r.sendHeader();
    r.send(JSON.stringify({
      expiry,
      target,
      url,
    }));
    r.finish();
    return;
  }

  r.headersOut['Share-Expiry'] = expiry.toFixed(0);
  r.headersOut['Share-Target'] = target;
  r.return(307, url);
}

async function view(r: NginxHTTPRequest): Promise<void> {
  const requestFilename = r.variables.request_filename;
  if (!requestFilename) {
    doError(r, 500, 'Could not determine request filename');
    return;
  }

  const urlSplit = requestFilename.split('/');
  while (urlSplit.length > 0 && urlSplit.shift() !== '_share');

  const token = urlSplit.shift() || '';

  const keys = await getKeys();
  const data = await crypto.subtle.decrypt(
    {
      name: 'AES-CBC',
      iv: keys.iv,
    },
    keys.encryption,
    Buffer.from(token, 'base64url'),
  );

  if (data.byteLength <= HASH_ALG_BYTES) {
    doError(r, 400, 'Truncated share data');
    return;
  }

  const givenHash = data.slice(0, HASH_ALG_BYTES);
  const secureData = data.slice(HASH_ALG_BYTES);
  if (!await crypto.subtle.verify(HMAC_ALG, keys.hmac, givenHash, secureData)) {
    doError(r, 400, 'Invalid share hash');
    return;
  }
  const metaSplit = Buffer.from(secureData).toString('utf8').split('\n');

  const expiryStr = metaSplit[0];
  const pathPrefix = metaSplit[1];
  if (!expiryStr || !pathPrefix) {
    doError(r, 400, 'Invalid meta');
    return;
  }

  const expiry = parseInt(expiryStr, 10) * 1000;
  if (!isFinite(expiry) || expiry < Date.now()) {
    doError(r, 400, 'Share outside of validity window');
    return;
  }

  const target = `${pathPrefix}${decodeURI(urlSplit.join('/'))}`;
  if (target.charAt(target.length - 1) === '/') {
    await files.indexRaw(r, target, pathPrefix, `/_share/${token}/`, '[SHARE]', true);
    return;
  }

  await r.internalRedirect(`/_jsindex-static/_share${target}`);
}

export default {
    create,
    view,
};
