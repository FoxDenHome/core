function respond(r, code, data) {
  r.status = code;
  r.headersOut['Content-Type'] = 'text/plain';
  r.sendHeader();
  r.send(data);
  r.finish();
}

const user = process.env.FOXCAVES_USERNAME;
const pass = process.env.FOXCAVES_API_KEY;

async function shorten(url) {
    const res = await ngx.fetch('https://foxcav.es/api/v1/links', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Basic ' + btoa(`${user}:${pass}`),
        },
        body: JSON.stringify({ target: url }),
    });
    const data = await res.json();
    if (!res.ok) {
        throw new Error(`Error shortening URL: ${data.message || res.statusText}`);
    }
    return data.url;
}

async function create(r) {
    const target = r.variables.arg_v;

    if (!target) {
        respond(r, 400, "Missing 'v' parameter");
        return;
    }

    Response(r, 200, await shorten(`${r.variables.scheme}://${r.variables.host}/circuitjs.html${target}`));
}

export default {
    create,
};
