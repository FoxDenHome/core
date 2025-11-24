import fs from 'fs';
import util from './util.js';

const VARIABLE_REGEX = /\{\{\s*([^\}]+)\s*\}\}/g;
const INCLUDE_REGEX = /\[\[\s*([^\]]+)\s*\]\]/g;
const DICT_NAME = 'render_cache';

export type RequestContext = Record<string, any>;

let cacheBrokenWarned = false;

async function load(file: string): Promise<string> {
  const cache = ngx.shared[DICT_NAME];
  if (cache) {
    const cachedTemplate = cache.get(file);
    if (cachedTemplate !== undefined) {
      return cachedTemplate as string;
    }
  } else if (!cacheBrokenWarned) {
    ngx.log(ngx.WARN, `Shared dictionary "${DICT_NAME}" not found. Caching disabled.`);
    cacheBrokenWarned = true;
  }

  let respData = await fs.promises.readFile(file, {
    encoding: 'utf8',
  });

  let m: RegExpExecArray | null;
  while ((m = INCLUDE_REGEX.exec(respData)) !== null) {
    const includeResp = await load(m[1]);
    respData = respData.replace(m[0], includeResp || '');
  }

  if (cache) {
    ngx.log(ngx.INFO, `Loaded template ${file} into cache`);
    cache.set(file, respData);
  }
  return respData;
}

async function run(ctx: RequestContext, file: string): Promise<string> {
  if (!file) {
    throw new Error('File path is required for rendering');
  }

  const template = await load(file);

  const data = template.replace(VARIABLE_REGEX, (_, variableName) => {
    const value = ctx[variableName];
    if (value === undefined) {
      ngx.log(ngx.WARN, `Variable "${variableName}" not found in context when rendering ${file}`);
      return '';
    }
    return util.htmlEncode(value);
  });

  return data;
}

async function send(r: NginxHTTPRequest, ctx: RequestContext, file: string) {
  r.send(await run(ctx, file));
}

export default {
    run,
    send,
};
