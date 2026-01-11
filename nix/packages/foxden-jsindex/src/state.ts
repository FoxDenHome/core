const DICT_NAME = 'state';

async function get(key: string): Promise<string | number | undefined> {
  const table = ngx.shared[DICT_NAME];
  return table.get(key);
}

async function set(key: string, value: string | number, timeout?: number): Promise<void> {
    const table = ngx.shared[DICT_NAME];
    table.set(key, value, timeout);
}

async function setOnce<T extends string | number>(key: string, initialValueGenerator: () => T | Promise<T>): Promise<T> {
  const table = ngx.shared[DICT_NAME];
  const existing = table.get(key);
  if (existing !== undefined) {
    return existing as T;
  }

  const val = await initialValueGenerator();
  const ok = table.add(key, val);
  if (!ok) {
    return table.get(key) as T;
  }
  return val;
}

export default {
    get,
    set,
    setOnce,
};
