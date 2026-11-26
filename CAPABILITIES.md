# Capability matrix

The current evidence comes from representative fixtures on an Apple M5 with macOS 27.2.1. Every row remains pending runtime verification on macOS 15 Apple silicon. The application and CLI use a macOS 15 deployment target.

| Format | Viewing | Writing | Animation | Multipage | Metadata preservation on re-encode | Lossless operations |
| --- | --- | --- | --- | --- | --- | --- |
| JPEG | Verified with EXIF orientation 6 | Verified, quality control | — | — | EXIF capture date and GPS verified with opt-in. Orientation normalizes to the rendered raster. | Byte-identical copy verified. JPEG coefficient transforms are unavailable. |
| PNG | Verified | Still and APNG verified | APNG frame views and GIF-to-APNG timing/loop round-trip verified for full-canvas frames | — | Selected fields may pass through Image I/O. Round-trip unverified. | Byte-identical original copy path. Raster output uses PNG’s lossless compression. |
| TIFF | Still and three-page fixtures verified | Still and multipage verified | — | Three-page read and write verified | Selected fields may pass through Image I/O. Round-trip unverified. | Byte-identical original copy path. |
| HEIC | Still verified | Still verified, quality control | Unverified | Unverified | Selected fields may pass through Image I/O. Round-trip unverified. | Byte-identical original copy path. |
| GIF | Still and animated frame reads verified | Still, animated round-trip verified | Full-canvas frames, timing and infinite loop verified | — | Animation fields verified. Camera metadata round-trip unverified. | Byte-identical original copy path. |
| WebP | Still verified with a 1 × 1 fixture | Original copy only | Decoder path present. Animated fixtures unverified. | — | Original bytes retain source metadata. | Byte-identical original copy path. |
| BMP | Still verified | Still verified | — | — | Original bytes retain source metadata. | Byte-identical original copy path. |
| ICO | Single-icon fixture verified | Original copy only | — | Multiple embedded sizes unverified | Original bytes retain source metadata. | Byte-identical original copy path. |
| HEIF and camera RAW | Best-effort Image I/O decoding. Representative files pending. | Original copy only where Image I/O recognizes the source | Unverified | Unverified | Original bytes retain source metadata. | Byte-identical original copy path. |

Exported rasters default to omitting imported camera metadata. Opt-in passes selected EXIF, TIFF, and GPS fields to Image I/O. Codecs decide which fields they can store. Exact copies retain embedded metadata, auxiliary images, and compressed data because they copy the file bytes. General metadata editing, full XMP/IPTC retention across formats, JPEG coefficient-domain transforms, and animation disposal variants remain outside the verified workflows.

## Verification by phase

| Phase | Verification |
| --- | --- |
| Viewer | Built for arm64. JPEG EXIF orientation, PNG, GIF/APNG frame reads, TIFF page reads, natural ordering, thumbnail generation, Finder Open With, File Open, Open Recent, sibling selection, zoom, pan, fullscreen, and the information inspector exercised. The signed app kept navigation available on a corrupt PNG and settled on the matching WebP after five rapid steps. HEIC still, BMP, WebP, and ICO also decoded in the full check suite. |
| Editing and exports | Built the app. Applied crop, both rotation directions, horizontal flip, resize, grayscale, brightness, and contrast in representative recipes. Round-tripped JPEG, PNG, TIFF, HEIC, GIF, and BMP, plus GIF/APNG animation and TIFF pages. Checked JPEG metadata opt-in, exact copies, naming collisions, successful replacement, and cleanup after a failed replacement. From the signed app, rotated a 640 × 480 PNG and exported a 480 × 640 copy. |
| Batch and automation | Built the app and CLI. Checked browser-order numbering, conversion, corrupt-input reporting while valid inputs continue, cancellation, protection against batch self-overwrite, and CLI exit status. The signed app reported three successful exports and one corrupt input from its batch sheet. |
| Xcode project | Project and property-list syntax checked. The current host provides Apple Command Line Tools. Xcode scheme execution remains pending on a host with full Xcode. The Swift package build produced the signed application bundle. |

## Viewer benchmark

One run of the signed Release build on an Apple M5 with 16 GiB RAM and macOS 27.2.1. The selected local folder contained 2,000 files made from six synthetic JPEG, PNG, TIFF, HEIC, GIF, and WebP templates. The first image was a 1,920 × 1,080 JPEG. Sill had previously opened two images in the same process. The filesystem cache was left in its ordinary state.

| Measurement | Result |
| --- | ---: |
| Folder enumeration and sort | 88.6 ms |
| Folder picker acceptance to first canvas draw | 160.4 ms |
| Physical footprint before folder open | 51.3 MiB |
| Physical footprint at first draw | 56.6 MiB |
| Physical footprint when checked after the browser settled | 64.5 MiB |
| Process lifetime peak, including earlier activity | 121.3 MiB |

The benchmark includes the virtualized browser and thumbnails for its visible rows. It measures first draw in the AppKit canvas and excludes time spent in the folder picker. The fixture generator and diagnostics menu are documented in the README.

## Release gates

Run the automated suite and repeat the desktop checks on macOS 15 before marking the minimum version verified. Expand representative samples to animated WebP, partial GIF/APNG frames and disposal modes, 16-bit and wide-gamut images, camera RAW, and metadata round-trips for each eligible writer. Keep the viewing and writing claims for these cases provisional until the results are recorded.

Desktop drag and drop is implemented and still needs a confirmed Finder-to-window test. Cross-launch reopening of saved file and folder bookmarks and physical printing also remain unverified.
