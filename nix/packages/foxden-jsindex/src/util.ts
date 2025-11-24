const HTML_ENCODE_REGEX = /[&<>"']/g;
const HTML_ENTITIES: Record<string, string> = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&#39;',
};

function htmlEncode(str: string): string {
  return str.replace(HTML_ENCODE_REGEX, (match) => HTML_ENTITIES[match] || match);
}

function relativePath(path: string, base: string, isDir: boolean = false): string | undefined {
  if (!base.endsWith('/')) {
    base += '/';
  }
  if (!path.startsWith(base)) {
    return undefined;
  }
  let relPath = path.substring(base.length);
  if (!relPath.startsWith('/')) {
    relPath = '/' + relPath;
  }
  if (isDir && !relPath.endsWith('/')) {
    relPath += '/';
  }
  return relPath;
}

function joinUrl(base: string, append: string): string {
  let url;
  if (base.endsWith('/')) {
    url = base + append;
  } else {
    url = base + '/' + append;
  }
  return url;
}

export default {
    htmlEncode,
    relativePath,
    joinUrl,
};
