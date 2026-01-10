import state from './state.js';
import files from './files.js';
import util from './util.js';

const MAX_DURATION = 7 * 24 * 3600; // 7 days in seconds

let encryptionKeyCache: CryptoKey | undefined;
let hmacKeyCache: CryptoKey | undefined;

const HASH_ALG_BYTES = 32;
const HASH_ALG = `SHA-${HASH_ALG_BYTES * 8}`;
const HMAC_ALG: HmacKeyGenParams = { name: 'HMAC', hash: HASH_ALG };

const CRYPTO_ALG_BYTES = 16;
const CRYPTO_ALG: CipherAlgorithm = {
  name: 'AES-CBC',
  iv: Buffer.alloc(CRYPTO_ALG_BYTES, 0),
};

async function getEncryptionKey(): Promise<CryptoKey> {
  if (encryptionKeyCache) {
    return encryptionKeyCache;
  }

  const keyStr = await state.setOnce('shares:encryptionKey', async () => {
    const key = await crypto.subtle.generateKey({ name: 'AES-CBC', length: CRYPTO_ALG_BYTES * 8 }, true, ['encrypt', 'decrypt']);
    return await crypto.subtle.exportKey('raw', key).toString();
  });

  if (!keyStr) {
    throw new Error('Failed to get or generate encryption key');
  }

  encryptionKeyCache = await crypto.subtle.importKey('raw', keyStr, 'AES-CBC', false, ['encrypt', 'decrypt']);
  if (!encryptionKeyCache) {
    throw new Error('Failed to import encryption key');
  }

  return encryptionKeyCache;
}

async function getHmacKey(): Promise<CryptoKey> {
  if (hmacKeyCache) {
    return hmacKeyCache;
  }

  const keyStr = await state.setOnce('shares:hmacKey', async () => {
    const key = await crypto.subtle.generateKey(HMAC_ALG, true, ['sign', 'verify']);
    return await crypto.subtle.exportKey('raw', key).toString();
  });

  if (!keyStr) {
    throw new Error('Failed to get or generate hmac key');
  }

  hmacKeyCache = await crypto.subtle.importKey('raw', keyStr, HMAC_ALG, false, ['sign', 'verify']);
  if (!hmacKeyCache) {
    throw new Error('Failed to import hmac key');
  }

  return hmacKeyCache;
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

  const secureData = Buffer.from(`${expiry}\n${target}${slashIfDir}`);
  const hash = await crypto.subtle.sign(HMAC_ALG, await getHmacKey(), secureData);
  const token = await crypto.subtle.encrypt(
    CRYPTO_ALG,
    await getEncryptionKey(),
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
  const data = await crypto.subtle.decrypt(
    CRYPTO_ALG,
    await getEncryptionKey(),
    Buffer.from(token, 'base64url'),
  );

  if (data.byteLength <= HASH_ALG_BYTES) {
    doError(r, 400, 'Truncated share data');
    return;
  }

  const givenHash = data.slice(0, HASH_ALG_BYTES);
  const secureData = data.slice(HASH_ALG_BYTES);
  if (!await crypto.subtle.verify(HMAC_ALG, await getHmacKey(), givenHash, secureData)) {
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
