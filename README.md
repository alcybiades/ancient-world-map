# Ancient World Map

A small native macOS app that shows the [World History Encyclopedia](https://www.worldhistory.org/map/) map of the ancient world in a window of its own, with trackpad gestures and a year picker.

## Features

- **Map only.** Just the map fills the window: no site header, ads or page controls.
- **Two-finger pan.** Swipe on the trackpad to move around, including the glide after you lift your fingers. You can also click and drag.
- **Pinch to zoom.** Zooms around the point under your fingers. The site has 5 image levels; a pinch moves smoothly between them and settles on the nearest one when you let go.
- **Zoom past the top level.** Past the most detailed images, the app enlarges the page the way a browser does, up to 6×. Text stays sharp; the map images get softer.
- **Year picker.** A Liquid Glass control at the top sets the year in BCE. Type a year and press Return. The ‹ › buttons, or ↑ ↓ while typing, step 100 years.
- Double-click or two-finger double-tap zooms in.

## Requirements

- macOS 13 or later. Liquid Glass needs macOS 26; older versions get a frosted blur instead.
- Swift 5.9+ (Xcode or the Command Line Tools)
- An internet connection. Map images and data load live from worldhistory.org.

## Build & run

```sh
./build.sh
open "build/Ancient World Map.app"
```

`build.sh` builds a release binary with SwiftPM and wraps it into `build/Ancient World Map.app`, signed locally with an ad-hoc signature (no developer certificate). To run it straight from the command line during development, use `swift run`.

## How it works

Everything lives in [`Sources/AncientWorldMap/main.swift`](Sources/AncientWorldMap/main.swift).

- **Web view.** A `WKWebView` loads the full map page. The site's embeddable map (`map_embedded.php`) doesn't load jQuery and some other scripts it needs, so it never draws. An injected user script hides everything except `#map_container` and stretches it to fill the window.
- **Gestures.** Trackpad and mouse events are handled natively in a `WKWebView` subclass. They call small JavaScript helpers, which drive the map's own scroll position and zoom functions (`map_zoom_to`, `set_date`, and others).
- **Pinch zoom.** While you pinch, the current image level is scaled with CSS. The app switches level whenever the scale reaches the next level's ratio, keeping any leftover so the motion stays continuous. On release it animates to the nearest level.
- **Zooming past the top level.** This uses `WKWebView` page magnification. Magnification always grows from the top-left corner because the page itself doesn't scroll, so the app pans the map to keep the point under your fingers fixed.
- **Liquid Glass.** The control uses `NSGlassEffectView`, looked up at runtime so the project still builds with older SDKs.

The app depends on the site's current page structure and scripts. If worldhistory.org changes them, the app may need updating.

## Credits

All map content, imagery and data © [World History Encyclopedia](https://www.worldhistory.org/). This is an unofficial viewer and is not affiliated with or endorsed by World History Encyclopedia.
