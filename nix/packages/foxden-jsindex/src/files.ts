import fs, { NjsStats } from 'fs';
import util from './util.js';
import format from './format.js';
import render, { RequestContext } from './render.js';
import sorting, { FileInfo } from './sorting.js';

async function tryReaddir(r: NginxHTTPRequest, fsPath: string): Promise<string[] | undefined> {
  try {
    return await fs.promises.readdir(fsPath);
  } catch (err: unknown) {
    const errCode = (err as any).code;
    switch (errCode) {
      case 'ENOENT':
        r.return(404);
        break;
      case 'EACCESS':
        r.return(403);
        break;
      default:
        r.error(`Error reading directory ${fsPath}: ${JSON.stringify(err)}`);
        r.return(500);
        break;
    }
    return undefined;
  }
}

async function tryStat(fsPath: string): Promise<NjsStats | undefined> {
  try {
    return await fs.promises.stat(fsPath);
  } catch (err: unknown) {
    return undefined;
  }
}


async function renderFile(r: NginxHTTPRequest, parentCtx: RequestContext, info: FileInfo, template: string): Promise<void> {
  const isDir = info.stat && info.stat.isDirectory();

  const linkName = isDir ? `${info.name}/` : info.name;
  const ctx: RequestContext = {
    ...parentCtx,
    file_name: info.nameOverride || linkName,
    file_url: linkName,
    file_size: isDir ? '-' : format.size(info.stat?.size),
    file_mtime: format.date(info.stat?.mtime),
    file_type: isDir ? 'directory' : 'file',
    file_actions: parentCtx.withShare ? `<a onclick="javascript:mklink(event)" title="Create 1 hour anonymous share link" href="${encodeURI(linkName)}/_mkshare?duration=3600"><span class="icon icon-share">&nbsp;</span></a>` : '&nbsp;',
  };
  await render.send(r, ctx, template);
}

async function index(r: NginxHTTPRequest): Promise<void> {
  const absPath = r.variables.request_original_filename;
  if (!absPath) {
    r.return(500);
    return;
  }

  const headerTemplate = r.variables.jsindex_header;
  const entryTemplate = r.variables.jsindex_entry;
  const footerTemplate = r.variables.jsindex_footer;
  if (!r.variables.document_root || !headerTemplate || !entryTemplate || !footerTemplate) {
    r.error('One or more of the following required variables are not set: document_root, jsindex_header, jsindex_entry, jsindex_footer');
    r.return(500);
    return;
  }

  const relPath = util.relativePath(absPath, r.variables.document_root, true);
  if (!relPath) {
    r.return(400);
    return;
  }

  const files = await tryReaddir(r, absPath);
  if (files === undefined) {
    return;
  }

  const fileInfos: FileInfo[] = [];

  const indexIgnore = r.variables.jsindex_ignore?.split(' ');

  for (const name of files) {
    if (name.startsWith('.')) {
      continue; // Skip hidden files
    }
  
    if (indexIgnore && indexIgnore.length > 0) {
      const fileUrl = util.joinUrl(relPath, name);
      if (indexIgnore.includes(fileUrl)) {
          continue; // Skip ignored files
      }
    }

    fileInfos.push({
      name,
      stat: await tryStat(`${absPath}/${name}`),
    });
  }

  const ctx: RequestContext = {
    path: relPath,
    archMirrorId: r.variables.arch_mirror_id,
    domain: r.variables.host,
    withShare: r.variables.jsindex_withshare === 'true'
  };

  sorting.apply(r, ctx, fileInfos);

  r.status = 200;
  r.headersOut['Content-Type'] = 'text/html; charset=UTF-8';
  r.sendHeader();
  await render.send(r, ctx, headerTemplate);

  if (relPath !== '/') {
    await renderFile(r, {
      ctx,
      withShare: false,
    }, {
        name: '..',
        nameOverride: '.. (parent directory)',
        stat: await fs.promises.stat(`${absPath}/..`),
    }, entryTemplate);
}

  for (const fileInfo of fileInfos) {
    await renderFile(r, ctx, fileInfo, entryTemplate);
  }
  
  await render.send(r, ctx, footerTemplate);
  r.finish();
}

export default {
    index,
};
