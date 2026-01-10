import fs from 'fs';

async function create(r: NginxHTTPRequest): Promise<void> {
  const absPath = r.variables.request_original_filename;
  if (!absPath) {
    r.return(500);
    return;
  }

  const linkTo = absPath.replace(/\/_createlink$/, '');
  const durationStr = r.args.duration || '3600';
  const duration = parseInt(durationStr, 10);
  if (isNaN(duration) || duration <= 0) {
    r.return(400, 'Invalid duration');
    return;
  }

  const expires_at = Date.now() + (duration * 1000);
  const token = `abcdefgh`; // TODO: Implement real token generation and storage
  const linkUrl = `/guest/_link/${expires_at}_${token}`;

  await fs.promises.symlink(linkTo, `/link/${expires_at}_${token}`);

  r.status = 200;
  r.headersOut['Content-Type'] = 'application/json';
  r.sendHeader();
  r.send(JSON.stringify({
    url: linkUrl,
    file: linkTo,
    expires_at: new Date(expires_at).toISOString(),
  }));
  r.finish();
}

export default {
    create,
};
