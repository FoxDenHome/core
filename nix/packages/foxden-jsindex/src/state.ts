const DICT_NAME = 'state';

async function get(key: string): Promise<string | undefined> {
  const table = ngx.shared[DICT_NAME];
  return table.get(key) as string | undefined;
}

async function set(key: string, value: string): Promise<void> {
    const table = ngx.shared[DICT_NAME];
    table.set(key, value);
}

async function setOnce(key: string, initialValueGenerator: () => string | Promise<string>): Promise<string> {
  const table = ngx.shared[DICT_NAME];
  const existing = table.get(key);
  if (existing !== undefined) {
    return existing as string;
  }

  const val = await initialValueGenerator();
  const ok = table.add(key, val);
  if (!ok) {
    return table.get(key) as string;
  }
  return val;
}

export default {
    get,
    set,
    setOnce,
};
