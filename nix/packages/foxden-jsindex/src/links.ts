import fs from 'fs';
import shared from './shared.js';

shared.setInitial('link_secret_key', async () => {
  const u8 = new Uint8Array(32);
  await crypto.getRandomValues(u8);
  return Buffer.from(u8).toString('hex');
});

async function hashToken(token: string, expiry: string): Promise<string> {
  const secretKey = shared.get('link_secret_key');
  if (!secretKey) {
    throw new Error('Secret key not found');
  }
  const hash = await crypto.subtle.digest('SHA-256', `${secretKey}:${token}:${expiry}`);
  return Buffer.from(hash).toString('hex');
}

async function create(r: NginxHTTPRequest): Promise<void> {
  const absPath = r.variables.request_filename;
  if (!absPath) {
    r.return(500);
    return;
  }

  const target = absPath.replace(/\/_mklink$/, '');
  const durationStr = r.args.duration || '3600';
  const duration = parseInt(durationStr, 10);
  if (isNaN(duration) || duration <= 0) {
    r.return(400, 'Invalid duration');
    return;
  }

  const stat = await fs.promises.stat(target);
  if (!stat.isFile()) {
    r.return(400, 'Can only create links to files');
    return;
  }

  const expiry = new Date(Date.now() + (duration * 1000)).toISOString();
  const token = await hashToken(target, expiry);

  r.status = 200;
  r.headersOut['Content-Type'] = 'application/json';
  r.sendHeader();
  r.send(JSON.stringify({
    expiry,
    target,
    url: `/_link?token=${encodeURIComponent(token)}&target=${encodeURIComponent(target)}&expiry=${encodeURIComponent(expiry)}`,
  }));
  r.finish();
}

async function view(r: NginxHTTPRequest): Promise<void> {
  const givenToken = r.args.token;
  const expiry = r.args.expiry;
  const target = r.args.target;
  if (!givenToken || !expiry || !target) {
    r.return(400, 'Missing parameters');
    return;
  }

  const now = new Date();
  const expiryDate = new Date(expiry);
  if (now > expiryDate) {
    r.return(400, 'Link has expired');
    return;
  }

  const correctToken = await hashToken(target, expiry);

  if (givenToken !== correctToken) {
    r.return(400, 'Invalid token');
    return;
  }

  try {
    r.internalRedirect(`/_jsindex-link-direct/${target}`);
  } catch (err) {
    r.return(500, 'Error accessing file');
  }
}

export default {
    create,
    view,
};
