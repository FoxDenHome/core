'use strict';

async function mklinkAsync(e) {
    const url = new URL(e.currentTarget.href);
    const response = await fetch(url.href, {
        method: 'GET',
    });
    const data = await response.json();
    if (!response.ok) {
        throw new Error(data.error || 'Failed to create link');
    }
    const absUrl = `${document.location.protocol}//${document.location.host}${data.url}`;
    await navigator.clipboard.writeText(absUrl);
    alert('Link created and copied to clipboard:\n' + absUrl);
}

function mklink(e) {
    e.preventDefault();
    mklinkAsync(e).catch((err) => {
        console.error('Error creating link:', err);
        alert('Error creating link: ' + err.message);
    });
}
