const DICT_NAME = 'shared';

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

async function setInitial(key: string, initialValueGenerator: () => string | Promise<string>): Promise<string> {
  const table = ngx.shared[DICT_NAME];
  let value = table.get(key);
  if (typeof value !== 'string') {
    const initialValue = await initialValueGenerator();
    table.set(key, initialValue);
    value = initialValue;
  }
  return value;
}

export default {
    get,
    set,
    setInitial,
};
