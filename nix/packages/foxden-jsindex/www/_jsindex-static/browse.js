'use strict';

async function mklinkAsync(e) {
    const url = new URL(e.currentTarget.href);
    const response = await fetch(url.href, {
        method: 'POST',
    });
    const data = await response.json();
    if (!response.ok) {
        throw new Error(data.error || 'Unknown error');
    }
    const absUrl = `${document.location.protocol}//${document.location.host}${data.url}`;
    await navigator.clipboard.writeText(absUrl);
    alert('Shared link created and copied to clipboard :3');
}

function mklink(e) {
    e.preventDefault();
    mklinkAsync(e).catch((err) => {
        console.error('Error creating link:', err);
        alert('Error creating link: ' + err.message);
    });
}
