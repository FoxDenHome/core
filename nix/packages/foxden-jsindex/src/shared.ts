const DICT_NAME = 'shared';

export async function get(key: string): Promise<string | undefined> {
  const table = ngx.shared[DICT_NAME];
  const value = table.get(key);
  if (typeof value === 'string') {
    return value;
  }
}

export async function set(key: string, value: string): Promise<void> {
    const table = ngx.shared[DICT_NAME];
    table.set(key, value);
}

export async function setInitial(key: string, initialValueGenerator: () => string | Promise<string>): Promise<string> {
  const table = ngx.shared[DICT_NAME];
  let value = table.get(key);
  if (typeof value !== 'string') {
    const initialValue = await initialValueGenerator();
    table.set(key, initialValue);
    value = initialValue;
  }
  return value;
}
