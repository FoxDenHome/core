const DICT_NAME = 'state';

async function get(key: string): Promise<string | undefined> {
  const table = ngx.shared[DICT_NAME];
  const value = table.get(key);
  if (typeof value === 'string') {
    return value;
  }
}

async function set(key: string, value: string): Promise<void> {
    const table = ngx.shared[DICT_NAME];
    table.set(key, value);
}

async function setOnce(key: string, initialValueGenerator: () => string | Promise<string>) {
  const table = ngx.shared[DICT_NAME];
  const existing = table.get(key);
  if (typeof existing === 'string') {
    return existing;
  }
  const val = await initialValueGenerator();
  const ok = table.add(key, val);
  if (!ok) {
    // Someone else set it in the meantime
    return get(key);
  }
  return val;
}

export default {
    get,
    set,
    setOnce,
};
