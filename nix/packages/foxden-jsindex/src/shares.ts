import state from './state.js';
import files from './files.js';
import cryptoModule from 'crypto';
import util from './util.js';

state.setInitial('shares:secretKey', async () => {
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

async function signTarget(target: string, expiryStr: string): Promise<string> {
  const secretKey = await state.get('shares:secretKey');
  if (!secretKey) {
    throw new Error('Shares secret key not found');
  }
  const hmac = cryptoModule.createHmac('sha256', secretKey);
  hmac.update(target);
  hmac.update(expiryStr);
  return hmac.digest('base64url');
}

async function create(r: NginxHTTPRequest): Promise<void> {
  const absPath = r.variables.request_filename;
  if (!absPath) {
    doError(r, 500, 'Could not determine file path');
    return;
  }

  const target = absPath.replace(/\/+_mkshare$/, '');
  const durationStr = r.args.duration || '3600';
  const duration = parseInt(durationStr, 10);
  if (!isFinite(duration) || duration <= 0) {
    doError(r, 400, 'Invalid duration');
    return;
  }

  const stat = await util.tryStat(target);
  if (!stat || (!stat.isFile() && !stat.isDirectory())) {
    doError(r, 400, 'Can only create shares to files or directories');
    return;
  }

  const targetSlashed = `${target}${stat.isDirectory() ? '/' : ''}`;

  const expiry = Math.ceil(Date.now() / 1000) + duration;
  const expiryStr = expiry.toFixed(0);
  const signature = await signTarget(targetSlashed, expiryStr);

  const url = `/_share/${signature};${expiryStr};${targetSlashed.length}${encodeURI(targetSlashed)}`;
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

  r.headersOut['Share-Expiry'] = expiryStr;
  r.headersOut['Share-Target'] = target;
  r.return(307, url);
}

async function view(r: NginxHTTPRequest): Promise<void> {
  const requestFilename = r.variables.request_filename;
  if (!requestFilename) {
    doError(r, 500, 'Could not determine request URI');
    return;
  }

  const urlSplit = requestFilename.split('/');
  while (urlSplit.length > 0 && urlSplit.shift() !== '_share');

  const meta = urlSplit.shift();
  const metaSplit = meta?.split(';');
  const targetRaw = urlSplit.join('/');
  if (!meta || !metaSplit || !targetRaw) {
    doError(r, 400, 'Missing parameters');
    return;
  }

  if (metaSplit.length < 3) {
    doError(r, 400, 'Missing meta');
    return;
  }

  const target = `/${decodeURI(targetRaw)}`;

  const givenSignature = metaSplit[0];
  const expiryStr = metaSplit[1];
  const validateLenStr = metaSplit[2];

  if (!givenSignature || !expiryStr || !validateLenStr) {
    doError(r, 400, 'Invalid meta');
    return;
  }

  const expiry = parseInt(expiryStr, 10) * 1000;
  if (!isFinite(expiry) || expiry < Date.now()) {
    doError(r, 400, 'Share outside of validity window');
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

  const hashedTarget = target.substring(0, validateLen);
  if (target.length !== validateLen && hashedTarget.charAt(hashedTarget.length - 1) !== '/') {
    doError(r, 400, 'Partial match does not end at directory boundary');
    return;
  }

  const correctSignature = await signTarget(hashedTarget, expiryStr);
  if (givenSignature !== correctSignature) {
    doError(r, 400, 'Invalid signature');
    return;
  }

  if (target.charAt(target.length - 1) === '/') {
    await files.indexRaw(r, target, hashedTarget, `/_share/${meta}${hashedTarget}`, true);
    return;
  }

  await r.internalRedirect(`/_jsindex-static/_share${target}`);
}

export default {
    create,
    view,
};
