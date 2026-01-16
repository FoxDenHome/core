const user = process.env.FOXCAVES_USERNAME;
const pass = process.env.FOXCAVES_API_KEY;

const LINK_EXPIRY = 30 * 24 * 60 * 60; // 30 days in seconds

async function shorten(url) {
    const res = await ngx.fetch('https://foxcav.es/api/v1/links', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Basic ' + btoa(`${user}:${pass}`),
        },
        body: JSON.stringify({ target: url, expires_in: LINK_EXPIRY }),
    });
    const data = await res.json();
    if (!res.ok) {
        throw new Error(`Error shortening URL: ${data.message || res.statusText}`);
    }
    return data.url;
}

async function create(r) {
    r.headersOut['Content-Type'] = 'text/plain';
    try {
        const target = decodeURIComponent(r.variables.arg_v || '');
        if (!target) {
            r.return(400, "Missing or empty 'v' parameter");
            return;
        }

        const shortUrl = await shorten(`${r.variables.scheme}://${r.variables.host}/circuitjs.html${target}`);
        r.return(200, shortUrl);
    } catch (e) {
        r.error(`Failed to shorten URL: ${e.stack || e}`);
        r.return(500, 'Internal Server Error');
    }
}

export default {
    create,
};
