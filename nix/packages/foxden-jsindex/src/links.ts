import fs from 'fs';

const DICT_NAME = 'links';

async function create(r: NginxHTTPRequest): Promise<void> {
  const absPath = r.variables.request_filename;
  if (!absPath) {
    r.return(500);
    return;
  }

  const targetPath = absPath.replace(/\/_mklink$/, '');
  const durationStr = r.args.duration || '3600';
  const duration = parseInt(durationStr, 10);
  if (isNaN(duration) || duration <= 0) {
    r.return(400, 'Invalid duration');
    return;
  }

  const expires_at = Date.now() + (duration * 1000);
  const token = `abcdefgh`; // TODO: Implement real token generation and storage
  const linkUrl = `/_link/${token}`;

  const table = ngx.shared[DICT_NAME];
  table.set(token, targetPath);

  r.status = 200;
  r.headersOut['Content-Type'] = 'application/json';
  r.sendHeader();
  r.send(JSON.stringify({
    url: linkUrl,
    file: targetPath,
    expires_at: new Date(expires_at).toISOString(),
  }));
  r.finish();
}

async function view(r: NginxHTTPRequest): Promise<void> {
  const reqUri = r.variables.request_uri;
  if (!reqUri) {
    r.return(500);
    return;
  }

  const linkToken = reqUri.replace(/\/_link\//, '');
  const table = ngx.shared[DICT_NAME];
  const targetPath = table.get(linkToken);
  if (!targetPath) {
    r.return(404, `Link not found or expired: ${linkToken}`);
    return;
  }

  try {
    r.internalRedirect(`/_jsindex-link-direct/${targetPath}`);
  } catch (err) {
    r.return(500, 'Error accessing file');
  }
}

export default {
    create,
    view,
};
