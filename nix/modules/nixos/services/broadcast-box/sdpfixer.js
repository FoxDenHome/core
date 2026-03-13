async function fixup(r, path) {
    const res = await r.subrequest(path, {
        body: r.requestBody,
        method: r.method,
    });
    if (res.status < 200 || res.status > 299) {
        r.return(res.status, `Error fetching ${r.method} ${path}: ${res.responseBody}`);
        return;
    }

    const data = res.responseBody
        .replace(/rport [0-9]+/g, 'rport 3333')
        .replace(/[0-9]+ typ srflx/g, '3333 typ srflx');

    r.headersOut['Content-Type'] = 'application/sdp';
    r.return(200, data);
}

async function whep(r) {
    return fixup(r, '/api/raw_whep');
}

async function whip(r) {
    return fixup(r, '/api/raw_whip');
}

export default {
    whep,
    whip,
};
