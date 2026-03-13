async function fixup(r, path) {
    const res = await fetch(path);
    if (res.status < 200 || res.status > 299) {
        r.return(res.status, `Error fetching ${path}: ${res.statusText}`);
        return;
    }

    let data = await res.text();

    data = data
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
