import state from './state.js';
import files from './files.js';
import util from './util.js';

const MAX_DURATION = 7 * 24 * 3600; // 7 days in seconds

const REVOCATIONS_DICT = 'shares_revocations';

const CRYPTO_ALG: AesKeyGenParams = {
  name: 'AES-GCM',
  length: 128,
};
const CRYPTO_ALG_BYTES = Math.ceil(CRYPTO_ALG.length / 8);

interface KeyStorage {
  encryption: CryptoKey;
}

let keyStorageCache: KeyStorage | undefined;

async function generateKeys(): Promise<string> {
  const encryptionKeyRaw = await crypto.subtle.exportKey('raw', await crypto.subtle.generateKey(CRYPTO_ALG, true, ['encrypt', 'decrypt']));
  return Buffer.from(encryptionKeyRaw as ArrayBuffer).toString('base64');
}

async function getKeys(): Promise<KeyStorage> {
  if (keyStorageCache) {
    return keyStorageCache;
  }

  const keyStr = await state.setOnce('shares:keyStorage', generateKeys);
  if (!keyStr) {
    throw new Error('Failed to get or generate keys');
  }

  const keyBuf = Buffer.from(keyStr, 'base64');

  keyStorageCache = {
    encryption: await crypto.subtle.importKey('raw', keyBuf, CRYPTO_ALG, false, ['encrypt', 'decrypt']),
  };
  return keyStorageCache;
}

function respondError(r: NginxHTTPRequest, code: number, message: string): void {
  respondJSON(r, code, { error: message });
}

function respondJSON(r: NginxHTTPRequest, code: number, data: unknown): void {
  r.status = code;
  r.headersOut['Content-Type'] = 'application/json';
  r.sendHeader();
  r.send(JSON.stringify(data));
  r.finish();
}

async function create(r: NginxHTTPRequest): Promise<void> {
  const target = r.variables.request_filename;
  if (!target) {
    respondError(r, 500, 'Could not determine request filename');
    return;
  }
  if (target.indexOf('\0') !== -1) {
    respondError(r, 400, 'Invalid target path');
    return;
  }

  const durationStr = r.args.duration || '3600';
  const duration = parseInt(durationStr, 10);
  if (!isFinite(duration) || duration <= 0 || duration > MAX_DURATION) {
    respondError(r, 400, `Invalid duration: must be between 1 and ${MAX_DURATION} seconds`);
    return;
  }

  const stat = await util.tryStat(target);
  if (!stat || (!stat.isFile() && !stat.isDirectory())) {
    respondError(r, 400, 'Can only create shares to files or directories');
    return;
  }

  const expiry = Math.ceil(Date.now() / 1000) + duration;

  const iv = Buffer.allocUnsafe(CRYPTO_ALG_BYTES);
  await crypto.getRandomValues(iv);

  const data = Buffer.from(`\0\0\0\0\0\0${target}${stat.isDirectory() ? '/' : ''}`, 'utf8');
  data.writeUIntLE(expiry, 0, 6);

  const keys = await getKeys();
  const token = Buffer.concat([iv, new Uint8Array(await crypto.subtle.encrypt(
    {
      iv,
      name: CRYPTO_ALG.name as "AES-CBC", // lol, type hack
    },
    keys.encryption,
    data,
  ))]);

  const url = `/_share/${token.toString('base64url')}/${stat.isDirectory() ? '' : target.split('/').pop()}`;

  if (r.variables.request_method?.toUpperCase() === 'POST') {
    respondJSON(r, 200, {
      expiry,
      target,
      url,
    });
    return;
  }

  r.headersOut['Share-Expiry'] = expiry.toFixed(0);
  r.headersOut['Share-Target'] = target;
  r.return(307, url);
}

async function view(r: NginxHTTPRequest): Promise<void> {
  const requestFilename = r.variables.request_filename;
  if (!requestFilename) {
    respondError(r, 500, 'Could not determine request filename');
    return;
  }

  const urlSplit = requestFilename.split('/');
  while (urlSplit.length > 0 && urlSplit.shift() !== '_share');

  const tokenB64 = urlSplit.shift() || '';

  let data: Buffer;
  const token = Buffer.from(tokenB64, 'base64url');
  if (token.byteLength <= CRYPTO_ALG_BYTES) {
    respondError(r, 400, 'Truncated or malformed token');
    return;
  }

  const tokenId = token.slice(0, CRYPTO_ALG_BYTES);

  const revocationKey = tokenId.toString('base64url');
  const revocationsTbl = ngx.shared[REVOCATIONS_DICT];
  if (revocationsTbl.has(revocationKey)) {
    respondError(r, 403, 'This token has been revoked');
    return;
  }

  try {
    const keys = await getKeys();

    data = Buffer.from(await crypto.subtle.decrypt(
      {
        iv: tokenId,
        name: CRYPTO_ALG.name as "AES-CBC", // lol, type hack
      },
      keys.encryption,
      token.slice(CRYPTO_ALG_BYTES),
    ));
  } catch (e) {
    respondError(r, 400, 'Invalid token');
    return;
  }

  if (data.byteLength < 1) {
    respondError(r, 500, 'Empty token');
    return;
  }

  const expiry = data.readUIntLE(0, 6);
  const pathPrefix = data.slice(6).toString('utf8');
  if (expiry <= 0 || !isFinite(expiry) || !pathPrefix) {
    respondError(r, 500, 'Internal token data error');
    return;
  }

  const timeLeft = (expiry * 1000) - Date.now();
  if (timeLeft <= 0) {
    respondError(r, 403, 'Token outside of validity window');
    return;
  }

  if (r.variables.arg_revoke === 'y') {
    revocationsTbl.set(revocationKey, 'y', timeLeft + 1000);
    respondJSON(r, 200, { message: 'Token revoked' });
    return;
  }

  if (pathPrefix.charAt(pathPrefix.length - 1) !== '/') {
    await r.internalRedirect(`/_jsindex-static/_share${pathPrefix}`);
    return;
  }

  const shareName = pathPrefix.replace(/\/+$/, '').split('/').pop() || 'SHARE';

  const target = `${pathPrefix}${decodeURI(urlSplit.join('/'))}`;
  if (target.charAt(target.length - 1) === '/') {
    await files.indexRaw(r, target, pathPrefix, `/_share/${tokenB64}/`, `[${shareName}]`, true);
    return;
  }

  await r.internalRedirect(`/_jsindex-static/_share${target}`);
}

export default {
    create,
    view,
};
