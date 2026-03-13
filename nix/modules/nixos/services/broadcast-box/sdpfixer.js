async function fixup(r, path) {
    const res = await r.subrequest(path, {
        method: r.method,
    });
    if (res.status < 200 || res.status > 299) {
        r.return(res.status, `Error fetching ${r.method} ${path}: ${res.responseText}`);
        return;
    }

    for (const key in res.headersOut) {
        if (!res.headersOut.hasOwnProperty(key)) {
            continue;
        }
        r.headersOut[key] = res.headersOut[key];
    }

    if (res.headersOut['Content-Type'] !== 'application/sdp') {
        r.return(res.status, res.responseText);
        return;
    }

    const data = res.responseText
        .replace(/rport [0-9]+/g, 'rport 3333')
        .replace(/[0-9]+ typ srflx/g, '3333 typ srflx');
    r.return(res.status, data);
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
