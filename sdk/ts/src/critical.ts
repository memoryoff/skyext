// 客户端关键操作入口（P08 / grant_v1），sdk/lua/skyext/client/critical.lua 的对等实现。
//
// 只做结构校验与组装：不自签 Grant、不实现请求指纹、不改业务键重试。
// 契约见 docs/design/critical_grant_v1.md；mac 的验签只有服务端密钥能做。

export const CRITICAL_GRANT_VERSION = 1;
export const MAX_SEQ = 0xffff;

/** 64-bit 实体 ID：安全范围内用 number，超出时用 bigint 或十进制字符串 */
export type CriticalRid = bigint | number | string;

/** sproto binary 字段：浏览器侧通常是 Uint8Array，也允许已编码的字符串透传 */
export type CriticalMac = string | Uint8Array;

export interface OperationGrantV1 {
    version: 1;
    rid: CriticalRid;
    grant_id: string;
    issued_at: number;
    expires_at: number;
    max_seq: number;
    key_id: string;
    mac: CriticalMac;
}

export interface CriticalRequestV1 {
    grant: OperationGrantV1;
    seq: number;
    op_type: string;
    params: Record<string, unknown>;
}

export interface CriticalRequestOptions {
    grant: OperationGrantV1;
    seq: number;
    op_type: string;
    params?: Record<string, unknown>;
    /** 承载它的 sproto 协议名，由游戏层给出 */
    protocol: string;
}

export interface CriticalQueryOptions {
    protocol: string;
    op_id: string;
}

export type BuildResult<T> = { ok: true; value: T } | { ok: false; error: string };

const isInteger = (v: unknown): v is number => typeof v === "number" && Number.isInteger(v);
const nonEmpty = (v: unknown): v is string => typeof v === "string" && v.length > 0;
const MAX_INT64 = 0x7fffffffffffffffn;
const normalizeRid = (v: unknown): bigint | number | null => {
    if (typeof v === "bigint") {
        return v > 0n && v <= MAX_INT64 ? v : null;
    }
    if (typeof v === "number") {
        return Number.isSafeInteger(v) && v > 0 ? v : null;
    }
    if (typeof v !== "string" || !/^[1-9]\d*$/.test(v)) {
        return null;
    }
    const n = BigInt(v);
    return n <= MAX_INT64 ? n : null;
};

const normalizeMac = (v: unknown): Uint8Array | null => {
    if (v instanceof Uint8Array) {
        return v.byteLength > 0 ? v : null;
    }
    if (typeof v !== "string" || v.length === 0) {
        return null;
    }
    // 字符串是 latin1 字节串，不是 UTF-8 文本。直接交给 encodeDeep 会把
    // 0x80..0xff 扩展成两字节，导致 HMAC 在 wire 上被改坏。
    return Uint8Array.from(Array.from(v, (c) => c.charCodeAt(0) & 0xff));
};

const isRid = (v: unknown): v is CriticalRid => normalizeRid(v) !== null;
const isMac = (v: unknown): v is CriticalMac => normalizeMac(v) !== null;

/** 结构校验；返回 null 表示通过，否则返回错误信息 */
export function validateGrant(grant: unknown): string | null {
    if (typeof grant !== "object" || grant === null) {
        return "grant must be an object";
    }
    const g = grant as Partial<OperationGrantV1>;
    if (g.version !== CRITICAL_GRANT_VERSION) {
        return "unsupported grant version";
    }
    if (!isRid(g.rid)) {
        return "invalid rid";
    }
    if (!nonEmpty(g.grant_id) || !/^[0-9a-f]{32}$/.test(g.grant_id)) {
        return "invalid grant_id";
    }
    if (!isInteger(g.issued_at) || !isInteger(g.expires_at)) {
        return "invalid timestamps";
    }
    if (g.expires_at <= g.issued_at) {
        return "expires_at must be after issued_at";
    }
    if (!isInteger(g.max_seq) || g.max_seq < 1 || g.max_seq > MAX_SEQ) {
        return "invalid max_seq";
    }
    if (!nonEmpty(g.key_id)) {
        return "invalid key_id";
    }
    if (!isMac(g.mac)) {
        return "invalid mac";
    }
    return null;
}

export function buildRequest(
    opts: CriticalRequestOptions,
): BuildResult<{ protocol: string; request: CriticalRequestV1 }> {
    const grantError = validateGrant(opts?.grant);
    if (grantError) {
        return { ok: false, error: grantError };
    }
    const grant = {
        ...opts.grant,
        rid: normalizeRid(opts.grant.rid)!,
        mac: normalizeMac(opts.grant.mac)!,
    };
    if (!isInteger(opts.seq) || opts.seq < 1 || opts.seq > grant.max_seq) {
        return { ok: false, error: "seq out of range" };
    }
    if (!nonEmpty(opts.op_type)) {
        return { ok: false, error: "op_type is required" };
    }
    if (opts.params !== undefined && (typeof opts.params !== "object" || opts.params === null)) {
        return { ok: false, error: "params must be an object" };
    }
    if (!nonEmpty(opts.protocol)) {
        return { ok: false, error: "protocol is required" };
    }
    return {
        ok: true,
        value: {
            protocol: opts.protocol,
            request: {
                grant,
                seq: opts.seq,
                op_type: opts.op_type,
                params: opts.params ?? {},
            },
        },
    };
}

/** 只读查询持久化结果；不得自行改 op_id 重发 */
export function buildQuery(opts: CriticalQueryOptions): BuildResult<{ protocol: string; request: { op_id: string } }> {
    if (!nonEmpty(opts?.protocol)) {
        return { ok: false, error: "protocol is required" };
    }
    if (!/^(?:srv_[0-9a-f]{64}|[0-9a-f]{32}_[0-9a-f]{4})$/.test(opts.op_id)) {
        return { ok: false, error: "invalid op_id" };
    }
    return { ok: true, value: { protocol: opts.protocol, request: { op_id: opts.op_id } } };
}
