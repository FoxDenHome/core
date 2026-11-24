import fs from 'fs';
import util from './util.js';
import format from './format.js';
import render, { RequestContext } from './render.js';
import sorting, { FileInfo } from './sorting.js';

const BUILTIN_TEMPLATES = '/njs/templates';

// Must stay in sync with what the thumbnailer (nasweb) can render
const IMAGE_EXTS = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'avif', 'bmp', 'svg', 'ico', 'apng', 'jxl', 'heic', 'heif', 'tif', 'tiff'];
// Formats a browser can show as-is (the lightbox only gets a "large" preview when thumbnails are on)
const BROWSER_IMAGE_EXTS = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'avif', 'bmp', 'svg', 'ico', 'apng'];
const VIDEO_EXTS = ['mp4', 'webm', 'm4v', 'mov', 'ogv', 'mkv'];

const THUMB_SIZES = ['small', 'large'];

type FileKind = 'directory' | 'image' | 'video' | 'file';

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

function encodePath(path: string): string {
  return path.split('/').map((part) => encodeURIComponent(part)).join('/');
}

function fileExt(name: string): string {
  const idx = name.lastIndexOf('.');
  return idx > 0 ? name.substring(idx + 1).toLowerCase() : '';
}

function fileKind(name: string, isDir: boolean): FileKind {
  if (isDir) {
    return 'directory';
  }
  const ext = fileExt(name);
  if (IMAGE_EXTS.includes(ext)) {
    return 'image';
  }
  if (VIDEO_EXTS.includes(ext)) {
    return 'video';
  }
  return 'file';
}

function makeActions(ctx: RequestContext, path: string, name: string): string {
  if (!ctx.withShares) {
    return '';
  }
  const isDir = path.endsWith('/');
  const shareMakeLink = `${encodePath(path.replace(/\/+$/, ''))}?mkshare=y&duration=3600`;
  return `<a class="share-action" onclick="javascript:makeShare(event);" title="Create anonymous share link" data-name="${util.htmlEncode(name)}" data-dir="${isDir ? 'y' : 'n'}" href="${util.htmlEncode(shareMakeLink)}"><span class="icon icon-share">&nbsp;</span></a>`;
}

function makeThumb(ctx: RequestContext, kind: FileKind, url: string): string {
  if ((kind === 'image' || kind === 'video') && ctx.withThumbs) {
    return `<img loading="lazy" decoding="async" alt="" src="${util.htmlEncode(`${url}?thumb=small`)}">`;
  }
  if (kind === 'image' && BROWSER_IMAGE_EXTS.includes(fileExt(url))) {
    return `<img loading="lazy" decoding="async" alt="" src="${util.htmlEncode(url)}">`;
  }
  const icon = kind === 'directory' ? 'directory' : 'file';
  return `<span class="icon icon-${icon} icon-large">&nbsp;</span>`;
}

function makeMediaAttrs(ctx: RequestContext, kind: FileKind, url: string): string {
  if (kind === 'video') {
    return 'data-media="video"';
  }
  if (kind !== 'image') {
    return '';
  }
  if (ctx.withThumbs) {
    return `data-media="image" data-preview="${util.htmlEncode(`${url}?thumb=large`)}"`;
  }
  if (BROWSER_IMAGE_EXTS.includes(fileExt(url))) {
    return 'data-media="image"';
  }
  return '';
}

async function renderFile(r: NginxHTTPRequest, parentCtx: RequestContext, info: FileInfo, template: string): Promise<void> {
  const isDir = !!(info.stat && info.stat.isDirectory());

  const linkName = isDir ? `${info.name}/` : info.name;
  const encodedName = info.name === '..' ? '..' : encodeURIComponent(info.name);
  const fileUrl = isDir ? `${encodedName}/${parentCtx.dirQuery}` : encodedName;
  const kind = fileKind(info.name, isDir);

  const ctx: RequestContext = {
    file_name: info.nameOverride || linkName,
    file_url: fileUrl,
    file_size: isDir ? '-' : format.size(info.stat?.size),
    file_mtime: format.date(info.stat?.mtime),
    file_type: isDir ? 'directory' : 'file',
    file_kind: kind,
    file_actions: info.noActions ? '' : makeActions(parentCtx, linkName, info.name),
  };
  if (parentCtx.view === 'grid') {
    ctx.file_thumb = makeThumb(parentCtx, kind, encodedName);
    ctx.file_media = makeMediaAttrs(parentCtx, kind, encodedName);
  }
  await render.send(r, ctx, template);
}

function joinQuery(...parts: string[]): string {
  return parts.filter((part) => !!part).join('&');
}

function makeViewToggle(ctx: RequestContext): string {
  if (!ctx.withGrid) {
    return '';
  }
  const link = (view: string, label: string) => {
    const query = joinQuery(view === 'grid' ? 'view=grid' : 'view=list', ctx.sortQuery);
    const active = ctx.view === view ? ' active' : '';
    return `<a class="view-option${active}" href="?${util.htmlEncode(query)}">${label}</a>`;
  };
  return `<nav class="view-toggle" aria-label="View"><span>View:</span>${link('list', 'List')}${link('grid', 'Grid')}</nav>`;
}

async function index(r: NginxHTTPRequest): Promise<void> {
  await indexRaw(r, r.variables.request_original_filename, r.variables.document_root, '/', '', false);
}

async function thumb(r: NginxHTTPRequest): Promise<void> {
  await thumbRaw(r, r.variables.request_filename);
}

async function thumbRaw(r: NginxHTTPRequest, target: string | undefined): Promise<void> {
  const size = r.args.thumb as string;
  if (!target || !THUMB_SIZES.includes(size) || target.indexOf('\0') !== -1) {
    r.return(400);
    return;
  }
  // Mapped to the thumbnailer by the location in the consuming nginx config
  await r.internalRedirect(`/_jsindex-static/_thumb/${size}${target}`);
}

async function indexRaw(r: NginxHTTPRequest,
  absPath: string | undefined,
  rootPath: string | undefined,
  rootUrl: string | undefined,
  titlePrefix: string | undefined,
  readOnly: boolean,
): Promise<void> {
  if (!absPath || !rootPath || !rootUrl) {
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

  const relPath = util.relativePath(absPath, rootPath, true);
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
      stat: await util.tryStat(`${absPath}/${name}`),
    });
  }

  const withGrid = r.variables.jsindex_grid === 'true';
  const view = withGrid && r.variables.arg_view === 'grid' ? 'grid' : 'list';

  const ctx: RequestContext = {
    rootUrl,
    rootUrlNoSlash: rootUrl.replace(/\/+$/, ''),
    titlePrefix,
    path: relPath,
    archMirrorId: r.variables.arch_mirror_id,
    domain: r.variables.host,
    // Share views are anonymous and read-only, creating shares from them can't work
    withShares: !readOnly && r.variables.jsindex_shares === 'true',
    withGrid,
    withThumbs: r.variables.jsindex_thumbs === 'true',
    view,
  };
  ctx.pathActions = readOnly ? '' : makeActions(ctx, relPath, relPath === '/' ? 'root directory' : relPath.replace(/\/+$/, '').split('/').pop() || relPath);

  sorting.apply(r, ctx, fileInfos);

  // Keep view and sort when navigating, so e.g. a shared gallery stays a gallery
  ctx.viewQuery = view === 'grid' ? '&view=grid' : '';
  const keepQuery = joinQuery(view === 'grid' ? 'view=grid' : '', ctx.sortQuery);
  ctx.dirQuery = keepQuery ? `?${keepQuery}` : '';
  ctx.viewToggle = makeViewToggle(ctx);

  const templateDir = r.variables.jsindex_templates || BUILTIN_TEMPLATES;
  const listingEntry = view === 'grid' ? `${templateDir}/entry_grid.html` : entryTemplate;

  r.status = 200;
  r.headersOut['Content-Type'] = 'text/html; charset=UTF-8';
  r.sendHeader();
  await render.send(r, ctx, headerTemplate);
  await render.send(r, ctx, `${templateDir}/${view}_pre.html`);

  if (relPath !== '/') {
    await renderFile(r, ctx, {
        name: '..',
        nameOverride: '.. (parent directory)',
        stat: await fs.promises.stat(`${absPath}/..`),
        noActions: true,
    }, listingEntry);
  }

  for (const fileInfo of fileInfos) {
    await renderFile(r, ctx, fileInfo, listingEntry);
  }

  await render.send(r, ctx, `${templateDir}/${view}_post.html`);
  await render.send(r, ctx, footerTemplate);
  r.finish();
}

export default {
    index,
    indexRaw,
    thumb,
    thumbRaw,
};
