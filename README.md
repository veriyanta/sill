# Sill

Sill is an offline image viewer, editor, and batch converter for Apple silicon Macs. The development target is macOS 15 or later.

## Open and browse

- Use Finder’s **Open With → Sill**, **File → Open…** (⌘O), or drag files into the window. **File → Open Recent** lists the last 12 individually opened images. **Clear Menu** removes their saved entries and bookmarks.
- A single-file open starts with the browser hidden. The window fits each selected image and keeps its top-left corner in place. Larger images scale down to the available space to the right and below that corner. Sill looks for neighboring images in natural filename order. If macOS requires a folder grant, the first navigation key opens the folder picker and continues to the requested image once you grant access. Select **Remember this folder** to reuse that grant when opening images in later sessions.
- The sidebar shows disks and folders above the thumbnail list. Select a disk or folder to browse it. Use the Up button to go to the parent folder or the drive menu to switch disks. Use the close button on either pane to hide it, or choose **View → Image Only** (⇧⌘0) to hide all panes and refit the image.
- **File → Open Folder…** (⇧⌘O) lists the folder’s immediate image files in natural filename order. **Include Subfolders** scans the current folder and its descendants. The recursive scan stops if it finds more than 4,096 images and keeps the previous list. Select **Remember this folder** in the picker if you want to reopen it in a later session. Folder access is otherwise session-only.
- Use Left Arrow for the previous image and Right Arrow or Space for the next image. Press Escape to close the viewer window. Use ⌘0 to fit and ⌘1 for one image pixel per display pixel. Drag to pan a zoomed image or pinch to zoom. The green window button and **Image → Enter or Exit Full Screen** use macOS fullscreen.
- The information button shows dimensions, detected format, and metadata reported by Image I/O. Animated images have playback and frame controls. Multipage files have page controls. The slideshow advances through the browser every three seconds.

## Edit and export

The edit panel offers crop, resize, rotation, flipping, grayscale, brightness, and contrast. Edits apply to the current preview with undo, redo, and reset. Navigating to a different file or frame clears the preview recipe. Export an image before navigating away if you want to keep those edits.

**File → Export Image…** (⌘E) defaults to a PNG copy. **File → Batch Export…** (⇧⌘E) works through the browser in order and can convert, resize, apply the current recipe, or write copies with a prefix or sequential numbering. **Original — exact copy** retains the source bytes. Frame/page export defaults to the current image for a single export and the primary image for a batch. Choose **Export all frames or pages** when writing GIF/APNG animations or TIFF pages.

Sill stages completed exports in the chosen folder and publishes them with a same-folder rename. **Keep both** is the default and resolves concurrent name collisions without replacing files. Replacing existing files requires an explicit choice and confirmation. Batch replacement guards against output names that overlap the input set. Batch cancel leaves already published files in place.

## Build and run

Open **Sill.xcodeproj**, select the shared **Sill** scheme, and run on **My Mac**. Full Xcode 16 or later is required for the Xcode project. A standalone Swift 6 toolchain with the macOS SDK can build an equivalent local app bundle.

```sh
./Support/build-app.sh
open .build/Sill.app
```

The script enables App Sandbox by default. For a local build that can find sibling images using the current account’s file permissions, run `SILL_APP_SANDBOX=0 ./Support/build-app.sh`. macOS privacy settings still apply. The app uses no network services or third-party dependencies. The supplied bundle is for local evaluation. Developer ID signing, notarization, a distribution channel, Intel support, and older macOS support remain release decisions.

## Run automation and checks

```sh
swift build -c release
bin="$(swift build -c release --show-bin-path)"
"$bin/SillChecks"
./Tests/check-cli.sh "$bin/sillctl"
"$bin/sillctl" --help
"$bin/sillctl" export input.jpg --to ./out --format png --rotate-right --resize 1600
"$bin/sillctl" batch ./photos --to ./out --format jpeg --quality 0.88 --prefix Photo- --number
```

Create the output folder before running the CLI. Its inputs and outputs are the explicit paths using the invoking account’s permissions. The app and CLI use the same SillCore pipeline.

To reproduce the viewer workload, run `SillChecks --make-viewer-fixtures /path/to/new-test-folder`. Open its `mixed-2000` folder and use **View → Viewer Diagnostics**. The timer runs from acceptance of the folder picker to the AppKit canvas’s first draw. The diagnostics also show the app’s physical footprint.

[Capability matrix and verification](CAPABILITIES.md)

## License

Sill is released under the [MIT License](LICENSE).
