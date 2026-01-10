import fs from 'fs';
import util from './util.js';
import shared from './shared.js';

const VARIABLE_REGEX = /(\{\{\{?)\s*([^\}]+)\s*(\}\}\}?)/g;
const INCLUDE_REGEX = /\[\[\s*([^\]]+)\s*\]\]/g;

export type RequestContext = Record<string, any>;

async function load(file: string): Promise<string> {
  const sharedKey = `render:${file}`;

  const cachedTemplate = await shared.get(sharedKey);
  if (cachedTemplate) {
    return cachedTemplate;
  }

  let respData = await fs.promises.readFile(file, {
    encoding: 'utf8',
  });

  let m: RegExpExecArray | null;
  while ((m = INCLUDE_REGEX.exec(respData)) !== null) {
    const includeResp = await load(m[1]);
    respData = respData.replace(m[0], includeResp || '');
  }

  await shared.set(sharedKey, respData);
  return respData;
}

async function run(ctx: RequestContext, file: string): Promise<string> {
  if (!file) {
    throw new Error('File path is required for rendering');
  }

  const template = await load(file);

  const data = template.replace(VARIABLE_REGEX, (raw, openTag, variableName, closeTag) => {
    if (openTag.length !== closeTag.length) {
      ngx.log(ngx.WARN, `Mismatched tags in template ${file} for tag "${raw}"`);
      return '';
    }

    const value = ctx[variableName];
    if (value === undefined) {
      ngx.log(ngx.WARN, `Variable for tag "${raw}" not found in context when rendering ${file}`);
      return '';
    }

    if (openTag.length === 3) {
      return value;
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
