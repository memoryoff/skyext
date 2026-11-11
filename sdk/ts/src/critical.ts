// 客户端关键操作入口（P08 / grant_v1），sdk/lua/skyext/client/critical.lua 的对等实现。
//
// 只做结构校验与组装：不自签 Grant、不实现请求指纹、不改业务键重试。
// 契约见 docs/design/critical_grant_v1.md；mac 的验签只有服务端密钥能做。

export const CRITICAL_GRANT_VERSION = 1;
export const MAX_SEQ = 0xffff;

export interface OperationGrantV1 {
    version: 1;
    /** 64-bit ID 建议用字符串，避免 JS Number 截断 */
    rid: number | string;
    grant_id: string;
    issued_at: number;
    expires_at: number;
    max_seq: number;
    key_id: string;
    mac: string;
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

/** 结构校验；返回 null 表示通过，否则返回错误信息 */
export function validateGrant(grant: unknown): string | null {
    if (typeof grant !== "object" || grant === null) {
        return "grant must be an object";
    }
    const g = grant as Partial<OperationGrantV1>;
    if (g.version !== CRITICAL_GRANT_VERSION) {
        return "unsupported grant version";
    }
    if (!isInteger(g.rid) && !nonEmpty(g.rid)) {
        return "invalid rid";
    }
    if (!nonEmpty(g.grant_id) || g.grant_id.length !== 32) {
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
    if (!nonEmpty(g.mac)) {
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
    const grant = opts.grant;
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
    if (!nonEmpty(opts.op_id)) {
        return { ok: false, error: "op_id is required" };
    }
    return { ok: true, value: { protocol: opts.protocol, request: { op_id: opts.op_id } } };
}
