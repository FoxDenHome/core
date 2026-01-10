import fs from 'fs';
import shared from './shared.js';

shared.setInitial('link_secret_key', async () => {
  const u8 = new Uint8Array(32);
  await crypto.getRandomValues(u8);
  return Buffer.from(u8).toString('hex');
});

function doError(r: NginxHTTPRequest, code: number, message: string): void {
  r.status = code;
  r.headersOut['Content-Type'] = 'application/json';
  r.sendHeader();
  r.send(JSON.stringify({ error: message }));
  r.finish();
}

async function hashToken(token: string, expiry: string): Promise<string> {
  const secretKey = shared.get('link_secret_key');
  if (!secretKey) {
    throw new Error('Secret key not found');
  }
  const hash = await crypto.subtle.digest('SHA-256', `${secretKey}\n${token}\n${expiry}\n${secretKey}`);
  return Buffer.from(hash).toString('hex');
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
    url: `/_share/${token};${expiry};${targetSlashed.length}${targetSlashed}`,
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
  const target = linkSplit.join('/');

  if (!meta || !target) {
    doError(r, 400, 'Missing parameters');
    return;
  }

  const givenToken = meta[0];
  const expiry = meta[1];
  const validateLenStr = meta[2];

  if (!givenToken || !expiry || !validateLenStr) {
    doError(r, 400, 'Missing meta');
    return;
  }

  const validateLen = parseInt(validateLenStr, 10);
  if (!isFinite(validateLen) || validateLen <= 0 || validateLen > target.length) {
    doError(r, 400, 'Invalid validate length');
    return;
  }

  const now = new Date();
  const expiryDate = new Date(expiry);
  if (now > expiryDate) {
    doError(r, 400, 'Share has expired');
    return;
  }

  const relevantTarget = target.substring(0, validateLen + 1);
  if (target.length !== validateLen && relevantTarget.substring(relevantTarget.length - 1) !== '/') {
    doError(r, 400, `Partial target must end at slash vl=${validateLen}, tl=${target.length}, rl=${relevantTarget.length}, rt=${relevantTarget}, t=${target}`);
    return;
  }

  const correctToken = await hashToken(relevantTarget, expiry);
  if (givenToken !== correctToken) {
    doError(r, 400, 'Invalid token');
    return;
  }

  try {
    r.internalRedirect(`/_jsindex-share-direct/${target}`);
  } catch (err) {
    doError(r, 500, 'Error accessing file');
  }
}

export default {
    create,
    view,
};
