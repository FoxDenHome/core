const SIZE_SUFFIXES = ['B', 'kB', 'MB', 'GB', 'TB', 'PB'];

function size(size: number | undefined): string {
    if (!size || size < 0) {
        return '-';
    }
    let index = 0;
    while (size >= 1024 && index < SIZE_SUFFIXES.length - 1) {
        size /= 1024;
        index++;
    }
    return `${size.toFixed(2)} ${SIZE_SUFFIXES[index]}`;
}

function date(date: Date | undefined): string {
    if (!date) {
        return '-';
    }
    return date.toISOString().replace('T', ' ').replace('Z', '');
}

export default {
    size,
    date,
};
