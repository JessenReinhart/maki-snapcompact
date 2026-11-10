const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const zlib = require("node:zlib");

// --- Native Addon Discovery ---
let cachedNatives = null;
function loadNatives() {
  if (cachedNatives !== null) return cachedNatives;

  const candidates = [
    process.env.PI_NATIVES_PATH,
    path.join(os.homedir(), ".omp", "natives", "18.2.0", "pi_natives.win32-x64-baseline.node")
  ].filter(Boolean);

  // Search dynamically in ~/.omp/natives if candidates not found
  try {
    const ompDir = path.join(os.homedir(), ".omp", "natives");
    if (fs.existsSync(ompDir)) {
      const versions = fs.readdirSync(ompDir);
      for (const v of versions) {
        const p = path.join(ompDir, v, "pi_natives.win32-x64-baseline.node");
        if (fs.existsSync(p)) candidates.push(p);
      }
    }
  } catch {}

  for (const p of candidates) {
    try {
      if (fs.existsSync(p)) {
        const mod = require(p);
        if (typeof mod.renderSnapcompactPng === "function") {
          cachedNatives = mod;
          return mod;
        }
      }
    } catch {}
  }
  return null;
}

// --- Minimal Fallback Grayscale PNG Generator ---
function createFallbackPng(text, width = 1568, height = 1568) {
  const rowBytes = width + 1;
  const rawData = Buffer.alloc(rowBytes * height, 0xff);
  for (let y = 0; y < height; y++) {
    rawData[y * rowBytes] = 0;
  }
  const deflated = zlib.deflateSync(rawData);

  function crc32(buf) {
    let c = 0xffffffff;
    for (let i = 0; i < buf.length; i++) {
      c ^= buf[i];
      for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
    }
    return (c ^ 0xffffffff) >>> 0;
  }

  function makeChunk(type, data) {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length, 0);
    const typeBuf = Buffer.from(type, "ascii");
    const crcBuf = Buffer.alloc(4);
    crcBuf.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
    return Buffer.concat([len, typeBuf, data, crcBuf]);
  }

  const header = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 0;
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;

  const chunks = [
    header,
    makeChunk("IHDR", ihdr),
    makeChunk("IDAT", deflated),
    makeChunk("IEND", Buffer.alloc(0))
  ];
  return Buffer.concat(chunks).toString("base64");
}

async function renderFrame(text, shape) {
  const natives = loadNatives();
  const size = shape.frameSize || shape.size || 1568;
  if (natives && typeof natives.renderSnapcompactPng === "function") {
    return await natives.renderSnapcompactPng(text, {
      size,
      font: shape.font || "8x13",
      cellWidth: shape.cellWidth || 11,
      cellHeight: shape.cellHeight || 16,
      stretch: shape.stretch || false,
      variant: shape.variant || "bw",
      lineRepeat: shape.lineRepeat || 1,
      columns: shape.columns
    });
  }
  return createFallbackPng(text, size, size);
}

function supportedChars(font, text) {
  const natives = loadNatives();
  if (natives && typeof natives.snapcompactSupportedChars === "function") {
    return natives.snapcompactSupportedChars(font || "8x13", text || "");
  }
  return text || "";
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length < 2) {
    console.error("Usage: node snapcompact-render.cjs <input_json> <output_json>");
    process.exit(1);
  }

  const inputPath = args[0];
  const outputPath = args[1];

  const raw = fs.readFileSync(inputPath, "utf8");
  const data = JSON.parse(raw);

  if (data.action === "supported_chars") {
    const supported = supportedChars(data.font, data.text);
    fs.writeFileSync(outputPath, JSON.stringify({ ok: true, supported }), "utf8");
    return;
  }

  const frames = data.frames || [];
  const defaultShape = data.shape || { font: "8x13", cellWidth: 11, cellHeight: 16, frameSize: 1568 };

  const rendered = [];
  for (const f of frames) {
    const text = typeof f === "string" ? f : f.text;
    const shape = (typeof f === "object" && f.shape) ? f.shape : defaultShape;
    const b64 = await renderFrame(text, shape);
    rendered.push(b64);
  }

  fs.writeFileSync(outputPath, JSON.stringify({ ok: true, rendered }), "utf8");
}

main().catch(err => {
  console.error("Renderer error:", err);
  process.exit(1);
});
