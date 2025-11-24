import { NjsStats } from 'fs';
import { RequestContext } from './render.js';

export type FileInfo = {
    name: string;
    nameOverride?: string;
    stat?: NjsStats;
};

const DEFAULT_SORT = 'namedirfirst';

function sortDirFirst(a: FileInfo, b: FileInfo): number {
    const aIsDir = a.stat?.isDirectory() || false;
    const bIsDir = b.stat?.isDirectory() || false;
    if (aIsDir === bIsDir) {
        return 0;
    }
    if (aIsDir) {
        return -1;
    }
    return 1;
}

function sortNameASC(a: FileInfo, b: FileInfo): number {
    if (a.name === b.name) {
        return 0;
    }
    if (a.name > b.name) {
        return 1;
    }
    return -1;
}

function sortSizeASC(a: FileInfo, b: FileInfo): number {
    const aSize = a.stat?.size || 0;
    const bSize = b.stat?.size || 0;
    return aSize - bSize;
}

function sortTimeASC(a: FileInfo, b: FileInfo): number {
    const aTime = a.stat?.mtime?.getTime() || 0;
    const bTime = b.stat?.mtime?.getTime() || 0;
    return aTime - bTime;
}

type SortMethod = {
    asc: (a: FileInfo, b: FileInfo) => number;
    desc: (a: FileInfo, b: FileInfo) => number;
};

const SORTING_METHODS: Record<string, SortMethod> = {
    namedirfirst: {
        asc: (a, b) => sortDirFirst(a, b) || sortNameASC(a, b),
        desc: (a, b) => sortDirFirst(a, b) || sortNameASC(b, a),
    },
    name: {
        asc: sortNameASC,
        desc: (a, b) => sortNameASC(b, a),
    },

    sizedirfirst: {
        asc: (a, b) => sortDirFirst(a, b) || sortSizeASC(a, b),
        desc: (a, b) => sortDirFirst(a, b) || sortSizeASC(b, a),
    },
    size: {
        asc: sortSizeASC,
        desc: (a, b) => sortSizeASC(b, a),
    },

    timedirfirst: {
        asc: (a, b) => sortDirFirst(a, b) || sortTimeASC(a, b),
        desc: (a, b) => sortDirFirst(a, b) || sortTimeASC(b, a),
    },
    time: {
        asc: sortTimeASC,
        desc: (a, b) => sortTimeASC(b, a),
    },
};

const BASE_CTX: RequestContext = {};
for (const name in SORTING_METHODS) {
    BASE_CTX[`sort_${name}_next`] = 'asc';
    BASE_CTX[`sort_${name}_icon`] = '';
}

function apply(r: NginxHTTPRequest, ctx: RequestContext, infos: FileInfo[]): void {
    let sort = r.variables.arg_sort || DEFAULT_SORT;
    const isAscending = r.variables.arg_order !== 'desc';

    let method = SORTING_METHODS[sort];
    if (!method) {
        sort = DEFAULT_SORT;
        method = SORTING_METHODS[DEFAULT_SORT];
    }

    Object.assign(ctx, BASE_CTX);
    if (isAscending) {
        ctx[`sort_${sort}_next`] = 'desc';
    }
    ctx[`sort_${sort}_icon`] = isAscending ? 'icon-arrow-up' : 'icon-arrow-down';

    const func = isAscending ? method.asc : method.desc;
    infos.sort(func);
}

export default {
    apply,
};
