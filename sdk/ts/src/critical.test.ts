// 客户端 Grant 组装与边界校验，与 critical.test.lua 用例一一对应。
import { describe, expect, test } from "bun:test";
import { buildQuery, buildRequest, MAX_SEQ, validateGrant, type OperationGrantV1 } from "./critical.js";

function grant(over: Partial<OperationGrantV1> = {}): OperationGrantV1 {
    return {
        version: 1,
        rid: 7,
        grant_id: "a".repeat(32),
        issued_at: 1000,
        expires_at: 4600,
        max_seq: 5,
        key_id: "k1",
        mac: "deadbeef",
        ...over,
    };
}

function opts(over: Partial<Parameters<typeof buildRequest>[0]> = {}) {
    return {
        grant: grant(),
        seq: 1,
        op_type: "shop.buy",
        params: { amount: 1 },
        protocol: "critical.execute",
        ...over,
    };
}

describe("client critical request", () => {
    test("builds a request from a well-formed grant", () => {
        const result = buildRequest(opts());
        expect(result.ok).toBe(true);
        if (result.ok) {
            expect(result.value.protocol).toBe("critical.execute");
            expect(result.value.request.seq).toBe(1);
            expect(result.value.request.params.amount).toBe(1);
        }
    });

    test("refuses a seq outside the grant range or a non-integer seq", () => {
        expect(buildRequest(opts({ seq: 0 })).ok).toBe(false);
        expect(buildRequest(opts({ seq: 6 })).ok).toBe(false);
        expect(buildRequest(opts({ seq: 1.5 })).ok).toBe(false);
        expect(buildRequest(opts({ seq: 5 })).ok).toBe(true);
    });

    test("refuses an invalid max_seq instead of truncating it", () => {
        expect(buildRequest(opts({ grant: grant({ max_seq: 0 }) })).ok).toBe(false);
        expect(buildRequest(opts({ grant: grant({ max_seq: MAX_SEQ + 1 }) })).ok).toBe(false);
        expect(buildRequest(opts({ grant: grant({ max_seq: MAX_SEQ }) })).ok).toBe(true);
    });

    test("refuses inverted lifetimes and malformed ids", () => {
        expect(buildRequest(opts({ grant: grant({ expires_at: 1000 }) })).ok).toBe(false);
        expect(buildRequest(opts({ grant: grant({ grant_id: "short" }) })).ok).toBe(false);
        expect(buildRequest(opts({ grant: grant({ version: 2 as 1 }) })).ok).toBe(false);
        expect(validateGrant(grant({ key_id: "" }))).toBe("invalid key_id");
    });

    test("requires op_type, protocol and an object params", () => {
        expect(buildRequest(opts({ op_type: "" })).ok).toBe(false);
        expect(buildRequest(opts({ protocol: "" })).ok).toBe(false);
        expect(buildRequest(opts({ params: "x" as unknown as Record<string, unknown> })).ok).toBe(false);
    });

    test("builds a read-only query without inventing an op id", () => {
        const q = buildQuery({ protocol: "critical.query", op_id: "srv_" + "a".repeat(64) });
        expect(q.ok).toBe(true);
        expect(buildQuery({ protocol: "critical.query", op_id: "" }).ok).toBe(false);
    });
});
