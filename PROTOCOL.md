# Verified RW403B-N protocol notes

These observations come from one RW403B-N. Compatibility with every MUNBYN model or firmware revision is not established.

## Transport

- Classic SPP is advertised on RFCOMM channel 1. A binary device-info query returned the same identity/status response as BLE. TSPL text and bitmap probes produced no physical output.
- The built-in CUPS `bluetooth://` backend uses HCRP. Pairing, discovery, connection, and CUPS job completion did not establish a physically successful print through that route.
- BLE advertisements use AF30, but the verified data service is **ABF0**.
- **ABF1**: commands, write with response. **ABF3**: notifications. **ABF4**: raster packets, write without response.
- The helper waits for write readiness, paces packets, and releases the connection after the job.

## Framing and protobuf

Frame header: `55`, length low byte, length high six bits plus checksum bits, remaining checksum bits. The checksum is the XOR of `55`, the two raw length bytes, and payload bytes, split across header bytes 2 and 3. Payload limit: 1156 bytes. `src/Protocol.m` implements the bit layout.

The device-info query is `55 02 40 5d 08 01`.

Outer send message: field 1 event enum; field 5 binary event body. Event 1 queries identity, event 4 carries raster, event 10 ends the job. Outer replies use field 1 event, field 2 response code (200 success), and field 3 response data.

Raster body fields:

| Field | Meaning |
| --- | --- |
| 1 | Copies for this image (always 1; client expands requested copies) |
| 2 | Compressed chunk bytes |
| 3 | Whole uncompressed bitmap length, **sint32/zigzag** |
| 4 | Packet count in this section |
| 5 | Packet index, starting at 1 |
| 6 | Width in whole mm on first packet of each section, then 0 |
| 7 | Total section count |
| 8 | Compression mode 1 |
| 10 | Compressed section length, **sint32/zigzag** |
| 12 | Section index, starting at 1 |

Raster is one bit per dot, black=1, MSB first, white padding=0. Sections contain up to 8192 uncompressed bytes, aligned to eight full rows. Compressed data is split into 400-byte chunks.

Compression is Heatshrink **window bits 11 / lookahead bits 4**. The initially consulted public JS wrapper source used 8/6, but static inspection of the actual vendor codec's compiled `print_config` constants showed 11/4. The wrong 8/6 stream received acknowledgements and a completion report without a physical print. Correcting to 11/4 produced the confirmed bitmap. This is why a round trip against a locally matching decoder alone was insufficient validation.

Report event 6 with inner code 11/info `2` acknowledges a section. Inner code 10/info `0` is interpreted by the vendor as print completion. This signal must still be distinguished from physical acceptance. The implementation also sends the vendor's end-of-job event 10 after all raster sections.

## Media-feed correction

The full 4 x 6 raster was 812 x 1218 dots. Its last ink was on row 1185 (zero based). Sending all 1218 rows caused an additional blank label. Sending only rows 0 through 1185, preserving every printed pixel and its position, eliminated the extra blank label in a physical retest. Stock was confirmed as true 4 x 6 inches, not 100 x 150 mm.

## Evidence provenance

Static resources inspected from [MUNBYN’s web editor](https://editor.munbyn.com/):

- `static/js/app.e3efa380.js`: configuration, framing module 4476, protobuf module 53689, raster/compression utility module 58861.
- `static/js/165.1bd064fb.js`: current RW402B-family module selected by the editor for RW403B.
- The editor's Heatshrink library: ISC notice and compiled configuration constants. It was inspected, not bundled or executed as part of the solution.

No vendor JavaScript, compiled codec, proprietary CUPS filter, or installer is bundled. Only the ISC-licensed upstream Heatshrink implementation is vendored.

## Small labels and custom sizes

The PPD offers a 2 x 1-inch preset and custom sizes from 40 to 104 mm wide and 25.4 to 200 mm long. The raster validator accepts their rounded 203 dpi dimensions; the encoder enforces a maximum of 1600 rows independently of width. These are driver limits.

A 2 x 1-inch PDF converted through macOS's CUPS filters produces 406 x 203 pixels with either the preset or `PageSize=Custom.144x72`. Both paths produced the same monochrome test bitmap. Two white pixels pad the right edge to 408 dots / 51 bytes per row. As with larger labels, only trailing white rows are removed. This fixes the previous PPD's fixed-size fallback and the helper's large-label-only validation. The custom-size job was then physically verified on 2 x 1-inch stock: complete border and bottom marker, QR scan `RW403B-2X1`, and no additional blank label. Other custom dimensions remain unverified on hardware.
