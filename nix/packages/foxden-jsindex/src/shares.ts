import fs from 'fs';
import shared from './shared.js';
import files from './files.js';
import mcrypto from 'crypto';

shared.setInitial('link_secret_key', async () => {
  const u8 = Buffer.allocUnsafe(32);
  await crypto.getRandomValues(u8);
  return u8.toString('base64url');
});

function doError(r: NginxHTTPRequest, code: number, message: string): void {
  r.status = code;
  r.headersOut['Content-Type'] = 'application/json';
  r.sendHeader();
  r.send(JSON.stringify({ error: message }));
  r.finish();
}

async function hashToken(token: string, expiry: string): Promise<string> {
  const secretKey = await shared.get('link_secret_key');
  if (!secretKey) {
    throw new Error('Secret key not found');
  }
  const hmac = mcrypto.createHmac('sha256', secretKey);
  hmac.update(token);
  hmac.update(expiry);
  return hmac.digest('base64url');
}

async function create(r: NginxHTTPRequest): Promise<void> {
  const absPath = r.variables.request_filename;
  if (!absPath) {
    doError(r, 500, 'Could not determine file path');
    return;
  }

  const target = absPath.replace(/\/_mkshare$/, '');
  const durationStr = r.args.duration || '3600';
  const duration = parseInt(durationStr, 10);
  if (!isFinite(duration) || duration <= 0) {
    doError(r, 400, 'Invalid duration');
    return;
  }

  const stat = await fs.promises.stat(target);
  if (!stat.isFile() && !stat.isDirectory()) {
    doError(r, 400, 'Can only create links to files or directories');
    return;
  }

  const targetSlashed = `${target}${stat.isDirectory() ? '/' : ''}`;

  const expiry = new Date(Date.now() + (duration * 1000)).toISOString();
  const token = await hashToken(targetSlashed, expiry);

  r.status = 200;
  r.headersOut['Content-Type'] = 'application/json';
  r.sendHeader();
  r.send(JSON.stringify({
    expiry,
    target,
    url: `/_share/${token};${expiry};${targetSlashed.length}${encodeURI(targetSlashed)}`,
  }));
  r.finish();
}

async function view(r: NginxHTTPRequest): Promise<void> {
  const absPath = r.variables.request_uri;
  if (!absPath) {
    doError(r, 500, 'Could not determine request URI');
    return;
  }

  const linkSplit = absPath.split('/');
  linkSplit.shift(); // ROOT
  linkSplit.shift(); // _share
  const meta = linkSplit.shift()?.split(';');
  const targetRaw = linkSplit.join('/');

  if (!meta || !targetRaw) {
    doError(r, 400, 'Missing parameters');
    return;
  }

  const target = `/${decodeURI(targetRaw)}`;

  const givenToken = meta[0];
  const expiry = meta[1];
  const validateLenStr = meta[2];

  if (!givenToken || !expiry || !validateLenStr) {
    doError(r, 400, 'Missing meta');
    return;
  }

  const validateLen = parseInt(validateLenStr, 10);
  if (!isFinite(validateLen) || validateLen <= 0) {
    doError(r, 400, 'Invalid validate length');
    return;
  }

  if (validateLen > target.length) {
    doError(r, 400, 'Outside of shared path');
    return;
  }

  const now = new Date();
  const expiryDate = new Date(expiry);
  if (now > expiryDate) {
    doError(r, 400, 'Share has expired');
    return;
  }

  const hashedTarget = target.substring(0, validateLen);
  if (target.length !== validateLen && hashedTarget.charAt(hashedTarget.length - 1) !== '/') {
    doError(r, 400, 'Partial match does not end at directory boundary');
    return;
  }

  const correctToken = await hashToken(hashedTarget, expiry);
  if (givenToken !== correctToken) {
    doError(r, 400, 'Invalid token');
    return;
  }

  if (target.charAt(target.length - 1) === '/') {
    await files.indexRaw(r, target);
    return;
  }

  await r.internalRedirect(`/_jsindex-share-file/${target}`);
}

export default {
    create,
    view,
};
