// DownlinkV2 的 wire 信封解码。服务端契约见 docs/design/session_downlink_v2.md。
//
// 布局（固定 45 字节头 + 原始 sproto 包）：
//   magic           4  "SKX2"
//   version         1  2
//   session_epoch  32  小写 hex（16 字节随机数的可读编码）
//   seq             8  大端无符号，等于服务端 session_io.sent
//   payload         剩余
//
// 网关不解码，只做字节转发；客户端必须在这里完成 (epoch, seq) 的读取和校验。
// seq 用 BigInt 读，超过 Number.MAX_SAFE_INTEGER 直接判非法——不能静默按 32 位截断。

export interface DownlinkV2 {
    version: number;
    sessionEpoch: string;
    seq: number;
    payload: Uint8Array;
}

const MAGIC = [0x53, 0x4b, 0x58, 0x32]; // "SKX2"
const VERSION = 2;
const EPOCH_BYTES = 32;
const HEADER_BYTES = 4 + 1 + EPOCH_BYTES + 8;
const MAX_SAFE = BigInt(Number.MAX_SAFE_INTEGER);

function isEpoch(value: string): boolean {
    return /^[0-9a-f]{32}$/.test(value);
}

/** 返回 null 表示这不是一个合法的 DownlinkV2 包（客户端应丢弃或按握手响应处理） */
export function decodeDownlinkV2(bytes: Uint8Array): DownlinkV2 | null {
    if (bytes.length < HEADER_BYTES) {
        return null;
    }
    for (let i = 0; i < MAGIC.length; i++) {
        if (bytes[i] !== MAGIC[i]) {
            return null;
        }
    }
    const version = bytes[4];
    if (version !== VERSION) {
        return null;
    }
    let epoch = "";
    for (let i = 0; i < EPOCH_BYTES; i++) {
        epoch += String.fromCharCode(bytes[5 + i]);
    }
    if (!isEpoch(epoch)) {
        return null;
    }
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const raw = view.getBigUint64(5 + EPOCH_BYTES);
    if (raw > MAX_SAFE) {
        return null;
    }
    return {
        version,
        sessionEpoch: epoch,
        seq: Number(raw),
        payload: bytes.subarray(HEADER_BYTES),
    };
}
