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

async function setInitial(key: string, initialValueGenerator: () => string | Promise<string>) {
  const table = ngx.shared[DICT_NAME];
  if (table.get(key)) {
    return;
  }
  table.set(key, await initialValueGenerator());
}

export default {
    get,
    set,
    setInitial,
};
