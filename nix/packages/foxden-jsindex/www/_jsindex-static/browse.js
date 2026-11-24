'use strict';

/* ---------- Durations ---------- */

const SHARE_MAX_SECONDS = 7 * 24 * 3600; // keep in sync with MAX_DURATION in shares.ts
const SHARE_MIN_SECONDS = 60;
const SHARE_DEFAULT = '1h';
const SHARE_PRESETS = [
    ['15 min', '15m'],
    ['1 hour', '1h'],
    ['8 hours', '8h'],
    ['1 day', '1d'],
    ['3 days', '3d'],
    ['1 week', '1w'],
];
const SHARE_LAST_DURATION_KEY = 'jsindex-share-duration';

const UNIT_SECONDS = {
    s: 1, sec: 1, secs: 1, second: 1, seconds: 1,
    m: 60, min: 60, mins: 60, minute: 60, minutes: 60,
    h: 3600, hr: 3600, hrs: 3600, hour: 3600, hours: 3600,
    d: 86400, day: 86400, days: 86400,
    w: 604800, wk: 604800, wks: 604800, week: 604800, weeks: 604800,
};
const UNIT_NAMES = [['week', 604800], ['day', 86400], ['hour', 3600], ['minute', 60], ['second', 1]];

// Accepts things like "90m", "2 hours", "1d 12h", "1h30m", "an hour", "half a day", "1:30" or a bare number of hours
function parseDuration(text) {
    let s = text.trim().toLowerCase();
    if (!s) {
        return null;
    }

    const clock = /^(\d+):([0-5]\d)$/.exec(s);
    if (clock) {
        return parseInt(clock[1], 10) * 3600 + parseInt(clock[2], 10) * 60;
    }
    if (/^\d+(\.\d+)?$/.test(s)) {
        return Math.round(parseFloat(s) * 3600);
    }

    s = s.replace(/\bhalf (an?|1) /g, '0.5 ')
        .replace(/\ban?\b/g, '1')
        .replace(/\band\b|,|\+/g, ' ');

    const re = /(\d+(?:\.\d+)?)\s*([a-z]+)/g;
    let total = 0;
    let last = 0;
    let match;
    while ((match = re.exec(s)) !== null) {
        if (s.slice(last, match.index).trim()) {
            return null;
        }
        const unit = UNIT_SECONDS[match[2]];
        if (!unit) {
            return null;
        }
        total += parseFloat(match[1]) * unit;
        last = re.lastIndex;
    }
    if (last === 0 || s.slice(last).trim()) {
        return null;
    }
    return Math.round(total);
}

function formatDurationLong(seconds) {
    const parts = [];
    let rest = Math.round(seconds);
    for (const [name, size] of UNIT_NAMES) {
        const n = Math.floor(rest / size);
        if (n > 0) {
            parts.push(`${n} ${name}${n === 1 ? '' : 's'}`);
            rest -= n * size;
        }
        if (parts.length === 2) {
            break;
        }
    }
    return parts.join(' ') || '0 seconds';
}

function formatDurationShort(seconds) {
    let rest = Math.max(SHARE_MIN_SECONDS, Math.round(seconds / 60) * 60);
    const parts = [];
    for (const [suffix, size] of [['d', 86400], ['h', 3600], ['m', 60]]) {
        const n = Math.floor(rest / size);
        if (n > 0) {
            parts.push(`${n}${suffix}`);
            rest -= n * size;
        }
    }
    return parts.join(' ');
}

function formatDateTime(date) {
    return date.toLocaleString(undefined, {
        weekday: 'short',
        month: 'short',
        day: 'numeric',
        hour: '2-digit',
        minute: '2-digit',
    });
}

function toLocalInputValue(date) {
    const pad = (n) => String(n).padStart(2, '0');
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function storageGet(key) {
    try {
        return window.localStorage.getItem(key);
    } catch (e) {
        return null;
    }
}

function storageSet(key, value) {
    try {
        window.localStorage.setItem(key, value);
    } catch (e) {
        // Not important, it's just a remembered default
    }
}

/* ---------- Dialog helpers ---------- */

function closeOnBackdropClick(dialog) {
    dialog.addEventListener('click', (e) => {
        if (e.target !== dialog) {
            return;
        }
        const rect = dialog.getBoundingClientRect();
        const inside = e.clientX >= rect.left && e.clientX <= rect.right && e.clientY >= rect.top && e.clientY <= rect.bottom;
        if (!inside) {
            dialog.close();
        }
    });
}

/* ---------- Share dialog ---------- */

let shareDialog;

function getShareDialog() {
    if (shareDialog) {
        return shareDialog;
    }

    const d = document.createElement('dialog');
    d.className = 'share-dialog';
    d.innerHTML = `
<form class="share-form" novalidate>
  <h2>Share <span class="share-name"></span></h2>
  <label for="share-duration">Link stays valid for</label>
  <input type="text" id="share-duration" autocomplete="off" spellcheck="false" placeholder="e.g. 2h, 3 days, 1w, 1h 30m">
  <div class="presets" role="group" aria-label="Common durations"></div>
  <label for="share-until">…or until</label>
  <input type="datetime-local" id="share-until">
  <p class="hint" aria-live="polite"></p>
  <label class="share-grid-option checkbox"><input type="checkbox"> Open the folder in grid view</label>
  <div class="dialog-buttons">
    <button type="button" class="cancel">Cancel</button>
    <button type="submit" class="primary create">Create link</button>
  </div>
</form>
<div class="share-result" hidden>
  <h2>Link created</h2>
  <label for="share-url">Anyone with this link can view <span class="share-name"></span></label>
  <div class="share-url-row">
    <input type="text" id="share-url" readonly>
    <button type="button" class="primary copy">Copy</button>
  </div>
  <p class="hint result-hint" aria-live="polite"></p>
  <div class="dialog-buttons">
    <button type="button" class="done">Done</button>
  </div>
</div>`;
    document.body.appendChild(d);

    const form = d.querySelector('.share-form');
    const durationInput = d.querySelector('#share-duration');
    const untilInput = d.querySelector('#share-until');
    const hint = form.querySelector('.hint');
    const presets = d.querySelector('.presets');
    const createButton = d.querySelector('.create');
    const gridOption = d.querySelector('.share-grid-option');
    const result = d.querySelector('.share-result');
    const urlInput = d.querySelector('#share-url');
    const resultHint = d.querySelector('.result-hint');

    for (const [label, value] of SHARE_PRESETS) {
        const button = document.createElement('button');
        button.type = 'button';
        button.textContent = label;
        button.dataset.seconds = String(parseDuration(value));
        button.addEventListener('click', () => {
            durationInput.value = value;
            update(true);
            durationInput.focus();
        });
        presets.appendChild(button);
    }

    // Returns seconds if valid, shows why not otherwise
    function update(syncUntil) {
        const text = durationInput.value;
        const seconds = parseDuration(text);
        let error = '';
        if (!text.trim()) {
            error = 'Enter how long the link should work.';
        } else if (seconds === null) {
            error = 'Couldn\'t read that. Try something like 90m, 2 hours or 1d 12h.';
        } else if (seconds < SHARE_MIN_SECONDS) {
            error = 'Links must last at least a minute.';
        } else if (seconds > SHARE_MAX_SECONDS) {
            error = `Links can last at most ${formatDurationLong(SHARE_MAX_SECONDS)}.`;
        }

        for (const button of presets.children) {
            button.classList.toggle('selected', !error && Number(button.dataset.seconds) === seconds);
        }

        const now = Date.now();
        untilInput.min = toLocalInputValue(new Date(now + SHARE_MIN_SECONDS * 1000));
        untilInput.max = toLocalInputValue(new Date(now + SHARE_MAX_SECONDS * 1000));

        durationInput.setAttribute('aria-invalid', error ? 'true' : 'false');
        hint.classList.toggle('error', !!error);
        createButton.disabled = !!error;
        if (error) {
            hint.textContent = error;
            return null;
        }

        const expiry = new Date(now + seconds * 1000);
        if (syncUntil) {
            untilInput.value = toLocalInputValue(expiry);
        }
        hint.textContent = `Expires ${formatDateTime(expiry)} (in ${formatDurationLong(seconds)})`;
        return seconds;
    }

    durationInput.addEventListener('input', () => update(true));
    untilInput.addEventListener('input', () => {
        if (!untilInput.value) {
            return;
        }
        const until = new Date(untilInput.value);
        durationInput.value = formatDurationShort((until.getTime() - Date.now()) / 1000);
        update(false);
    });

    form.addEventListener('submit', (e) => {
        e.preventDefault();
        const seconds = update(false);
        if (seconds === null || !d.shareLink) {
            durationInput.focus();
            return;
        }
        createButton.disabled = true;
        createButton.textContent = 'Creating…';
        createShare(d.shareLink, seconds, !gridOption.hidden && gridOption.querySelector('input').checked)
            .then(async (share) => {
                storageSet(SHARE_LAST_DURATION_KEY, durationInput.value.trim());
                form.hidden = true;
                result.hidden = false;
                urlInput.value = share.url;
                const expires = `Expires ${formatDateTime(new Date(share.expiry * 1000))}.`;
                resultHint.textContent = expires;
                urlInput.focus();
                urlInput.select();
                if (await copyText(share.url)) {
                    resultHint.textContent = `Copied to clipboard. ${expires}`;
                }
            })
            .catch((err) => {
                console.error('Error creating link:', err);
                hint.textContent = `Couldn't create the link: ${err.message}`;
                hint.classList.add('error');
            })
            .finally(() => {
                createButton.disabled = false;
                createButton.textContent = 'Create link';
            });
    });

    d.querySelector('.cancel').addEventListener('click', () => d.close());
    d.querySelector('.done').addEventListener('click', () => d.close());
    d.querySelector('.copy').addEventListener('click', async () => {
        urlInput.select();
        if (await copyText(urlInput.value)) {
            resultHint.textContent = 'Copied to clipboard.';
        }
    });
    closeOnBackdropClick(d);

    d.openFor = (link) => {
        d.shareLink = link;
        for (const el of d.querySelectorAll('.share-name')) {
            el.textContent = `“${link.dataset.name || 'this'}”`;
        }
        const isDir = link.dataset.dir === 'y';
        const gridAvailable = isDir && !!document.querySelector('.view-toggle');
        gridOption.hidden = !gridAvailable;
        gridOption.querySelector('input').checked = gridAvailable && !!document.querySelector('.grid');

        form.hidden = false;
        result.hidden = true;
        durationInput.value = storageGet(SHARE_LAST_DURATION_KEY) || SHARE_DEFAULT;
        update(true);
        d.showModal();
        durationInput.focus();
        durationInput.select();
    };

    shareDialog = d;
    return d;
}

async function copyText(text) {
    try {
        await navigator.clipboard.writeText(text);
        return true;
    } catch (e) {
        return false;
    }
}

async function createShare(link, seconds, gridView) {
    const url = new URL(link.href);
    url.searchParams.set('duration', String(seconds));
    const response = await fetch(url.href, {
        method: 'POST',
    });
    let data;
    try {
        data = await response.json();
    } catch (e) {
        throw new Error(`HTTP ${response.status}`);
    }
    if (!response.ok) {
        throw new Error(data.error || `HTTP ${response.status}`);
    }
    const absUrl = new URL(data.url, document.location.href);
    if (gridView) {
        absUrl.searchParams.set('view', 'grid');
    }
    return {
        url: absUrl.href,
        expiry: data.expiry,
    };
}

function makeShare(e) {
    e.preventDefault();
    getShareDialog().openFor(e.currentTarget);
}

/* ---------- Grid view and lightbox ---------- */

let lightbox;

function getLightbox() {
    if (lightbox) {
        return lightbox;
    }

    const d = document.createElement('dialog');
    d.className = 'lightbox';
    d.innerHTML = `
<div class="lightbox-stage"></div>
<button type="button" class="lightbox-nav lightbox-prev" aria-label="Previous">&#8249;</button>
<button type="button" class="lightbox-nav lightbox-next" aria-label="Next">&#8250;</button>
<button type="button" class="lightbox-close" aria-label="Close">&#10005;</button>
<div class="lightbox-bar">
  <span class="lightbox-name"></span>
  <span class="lightbox-count"></span>
  <a class="lightbox-original" target="_blank" rel="noopener">Open original</a>
</div>`;
    document.body.appendChild(d);

    const stage = d.querySelector('.lightbox-stage');
    d.items = [];
    d.index = 0;

    d.show = (index) => {
        const count = d.items.length;
        d.index = (index + count) % count;
        const link = d.items[d.index];

        stage.textContent = '';
        let media;
        if (link.dataset.media === 'video') {
            media = document.createElement('video');
            media.controls = true;
            media.autoplay = true;
            media.playsInline = true;
            media.src = link.href;
        } else {
            media = document.createElement('img');
            media.alt = '';
            media.src = link.dataset.preview || link.href;
        }
        media.addEventListener('error', () => {
            const note = document.createElement('p');
            note.className = 'lightbox-error';
            note.textContent = 'No preview available for this file. Use "Open original" to download it.';
            media.replaceWith(note);
        });
        stage.appendChild(media);

        d.querySelector('.lightbox-name').textContent = link.querySelector('.tile-name').textContent;
        d.querySelector('.lightbox-count').textContent = `${d.index + 1} / ${count}`;
        d.querySelector('.lightbox-original').href = link.href;
        for (const nav of d.querySelectorAll('.lightbox-nav')) {
            nav.hidden = count < 2;
        }

        // Warm up the neighbours so flipping through feels instant
        for (const offset of [1, -1]) {
            const next = d.items[(d.index + offset + count) % count];
            if (next && next.dataset.media === 'image') {
                new Image().src = next.dataset.preview || next.href;
            }
        }
    };

    d.querySelector('.lightbox-prev').addEventListener('click', () => d.show(d.index - 1));
    d.querySelector('.lightbox-next').addEventListener('click', () => d.show(d.index + 1));
    d.querySelector('.lightbox-close').addEventListener('click', () => d.close());
    stage.addEventListener('click', (e) => {
        if (e.target === stage) {
            d.close();
        }
    });
    d.addEventListener('keydown', (e) => {
        if (e.key === 'ArrowLeft') {
            e.preventDefault();
            d.show(d.index - 1);
        } else if (e.key === 'ArrowRight') {
            e.preventDefault();
            d.show(d.index + 1);
        }
    });
    d.addEventListener('close', () => {
        stage.textContent = ''; // stops videos
    });

    let touchX = null;
    stage.addEventListener('touchstart', (e) => {
        touchX = e.touches.length === 1 ? e.touches[0].clientX : null;
    }, { passive: true });
    stage.addEventListener('touchend', (e) => {
        if (touchX === null || e.changedTouches.length !== 1) {
            return;
        }
        const dx = e.changedTouches[0].clientX - touchX;
        touchX = null;
        if (Math.abs(dx) > 50) {
            d.show(d.index + (dx < 0 ? 1 : -1));
        }
    });

    lightbox = d;
    return d;
}

function initGrid() {
    const grid = document.querySelector('.grid');
    if (!grid) {
        return;
    }

    // Thumbnails that can't be rendered fall back to the plain file icon
    grid.addEventListener('error', (e) => {
        const el = e.target;
        if (el.tagName !== 'IMG') {
            return;
        }
        const thumb = el.closest('.tile-thumb');
        if (thumb) {
            thumb.innerHTML = '<span class="icon icon-file icon-large">&nbsp;</span>';
        }
    }, true);

    grid.addEventListener('click', (e) => {
        if (e.button !== 0 || e.ctrlKey || e.metaKey || e.shiftKey || e.altKey) {
            return;
        }
        const link = e.target.closest('a.tile-link[data-media]');
        if (!link) {
            return;
        }
        e.preventDefault();
        const lb = getLightbox();
        lb.items = Array.from(grid.querySelectorAll('a.tile-link[data-media]'));
        lb.showModal();
        lb.show(lb.items.indexOf(link));
    });
}

document.addEventListener('DOMContentLoaded', initGrid);
