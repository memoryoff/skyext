// DownlinkV2 信封解码的契约测试。布局见 docs/design/session_downlink_v2.md。
import { describe, expect, test } from "bun:test";
import { decodeDownlinkV2 } from "./downlink.js";

const EPOCH = "ab".repeat(16);

function envelope(seq: bigint, payload: Uint8Array, epoch = EPOCH, version = 2): Uint8Array {
    const out = new Uint8Array(45 + payload.length);
    out.set([0x53, 0x4b, 0x58, 0x32, version], 0); // "SKX2" + version
    for (let i = 0; i < 32; i++) {
        out[5 + i] = epoch.charCodeAt(i);
    }
    new DataView(out.buffer).setBigUint64(37, seq);
    out.set(payload, 45);
    return out;
}

describe("downlink v2", () => {
    test("round-trips epoch, seq and payload bytes", () => {
        const payload = new Uint8Array([1, 0, 2, 255]);
        const d = decodeDownlinkV2(envelope(101n, payload));
        expect(d).not.toBeNull();
        expect(d!.version).toBe(2);
        expect(d!.sessionEpoch).toBe(EPOCH);
        expect(d!.seq).toBe(101);
        expect(Array.from(d!.payload)).toEqual([1, 0, 2, 255]);
    });

    test("rejects bad magic, version, epoch and short packets", () => {
        const good = envelope(1n, new Uint8Array(0));
        expect(decodeDownlinkV2(good.slice(0, 44))).toBeNull();

        const badMagic = good.slice();
        badMagic[0] = 0x58;
        expect(decodeDownlinkV2(badMagic)).toBeNull();

        const badVersion = envelope(1n, new Uint8Array(0), EPOCH, 3);
        expect(decodeDownlinkV2(badVersion)).toBeNull();

        const badEpoch = envelope(1n, new Uint8Array(0), "z".repeat(32));
        expect(decodeDownlinkV2(badEpoch)).toBeNull();
    });

    test("refuses a seq above Number.MAX_SAFE_INTEGER instead of truncating", () => {
        // 2^53 超过安全整数；JS 侧不能静默按 32 位截断
        expect(decodeDownlinkV2(envelope(9007199254740992n, new Uint8Array(0)))).toBeNull();
    });
});
