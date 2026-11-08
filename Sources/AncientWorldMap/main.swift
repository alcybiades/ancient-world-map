import AppKit
import WebKit

// World History Encyclopedia's map, at the same view as the embed snippet
// (map_embedded.php?q=-1600:33.217:42.383:21600). The embed page itself is broken
// (it omits jQuery and other site globals), so we load the full map page and hide
// everything but the map. Path is /map/<date>/<lat>/<lon>/<zoom>/.
let mapURL = URL(string: "https://www.worldhistory.org/map/-1600/33.217/42.383/21600/")!

// Injected into the map page. Hides the site chrome, stretches the map to fill the
// window, and exposes pan/zoom helpers that the native gesture handlers call into. Relies on the page's own globals from /js/map.js:
// view (#map_container), zoom_level, map_zoom_to, map_load_*.
let injectedJS = """
(function () {
  var style = document.createElement('style');
  style.textContent = `
    html, body { margin: 0 !important; padding: 0 !important; overflow: hidden !important; background: #9fb8c4 !important; }
    body * { visibility: hidden !important; }
    #map_container, #map_container * { visibility: visible !important; }
    #map_container {
      position: fixed !important; top: 0 !important; left: 0 !important;
      width: 100vw !important; height: 100vh !important; margin: 0 !important;
      border: 0 !important; z-index: 2147483647 !important; cursor: grab !important;
    }
    #map_container #marker, #map_container #loc_new { visibility: hidden !important; }
    /* The site's own date banner sits where the native year control is. */
    #map_container #tooltip_layer, #map_container #tooltip_layer * { visibility: hidden !important; }
  `;
  document.documentElement.appendChild(style);

  var ZOOMS = [1200, 2400, 5400, 10800, 21600];
  var dragged = 0;

  function reload() {
    map_load_images();
    map_load_locations();
    map_load_info_layers();
  }

  window.awmPan = function (dx, dy) {
    if (typeof view === 'undefined') return;
    view.scrollLeft(view.scrollLeft() - dx);
    view.scrollTop(view.scrollTop() - dy);
    $('#tooltip_layer').hide();
    dragged += Math.abs(dx) + Math.abs(dy);
    if (dragged > tile_size / 2) { dragged = 0; reload(); }
  };

  window.awmPanEnd = function () {
    if (typeof view === 'undefined') return;
    dragged = 0;
    reload();
  };

  // Step one zoom level in (dir > 0) or out (dir < 0), keeping the map point under
  // (cx, cy) fixed on screen. Map width in px equals the zoom level.
  window.awmZoom = function (dir, cx, cy) {
    if (typeof view === 'undefined' || !zoom_enabled) return false;
    var i = ZOOMS.indexOf(zoom_level);
    var next = ZOOMS[i + (dir > 0 ? 1 : -1)];
    if (i < 0 || !next) return false;
    var old = zoom_level;
    var fx = (view.scrollLeft() + cx) / old;
    var fy = (view.scrollTop() + cy) / (old / 2);
    map_zoom_to(next);
    view.scrollLeft(Math.round(fx * next - cx));
    view.scrollTop(Math.round(fy * (next / 2) - cy));
    reload();
    return true;
  };

  // Pinch zoom. The map only has discrete levels, so while pinching we CSS-scale the
  // current level around the pinch point, switch levels whenever the scale reaches the
  // next level's ratio (keeping the leftover so it stays continuous), and on release
  // animate to whichever level is nearest.
  var pinch = null;
  var settleTimer = null;

  function wrapper() { return document.getElementById('map_wrapper'); }

  // Scale factor to the next level in or out (e.g. 2 or 2.25), or null at the limit.
  function ratio(dir) {
    var next = ZOOMS[ZOOMS.indexOf(zoom_level) + dir];
    if (!next) return null;
    return dir > 0 ? next / zoom_level : zoom_level / next;
  }

  // Past the most detailed level there are no sharper images, so further zoom is
  // handed to the native side, which magnifies the whole page like a browser does.
  function overzoom(factor) {
    try { webkit.messageHandlers.awm.postMessage({ over: factor }); } catch (e) {}
  }

  function preview(scale) {
    var w = wrapper();
    w.style.transformOrigin = (view.scrollLeft() + pinch.cx) + 'px ' + (view.scrollTop() + pinch.cy) + 'px';
    w.style.transform = scale === 1 ? '' : 'scale(' + scale + ')';
  }

  function finishSettle() {
    if (!settleTimer) return;
    clearTimeout(settleTimer.id);
    settleTimer.done();
  }

  function settle(target, dir) {
    var w = wrapper();
    w.style.transition = 'transform 180ms cubic-bezier(0.2, 0.8, 0.2, 1)';
    preview(target);
    var done = function () {
      settleTimer = null;
      w.style.transition = '';
      if (dir) awmZoom(dir, pinch.cx, pinch.cy);
      preview(1);
      pinch = null;
    };
    settleTimer = { id: setTimeout(done, 180), done: done };
  }

  window.awmPinchBegin = function (cx, cy) {
    if (typeof view === 'undefined') return;
    finishSettle();
    pinch = { s: 1, cx: cx, cy: cy };
  };

  window.awmPinch = function (magnification) {
    if (!pinch) return;
    pinch.s *= 1 + magnification;
    var up = ratio(1), down = ratio(-1);
    if (up && pinch.s >= up) {
      awmZoom(1, pinch.cx, pinch.cy);
      pinch.s /= up;
    } else if (down && pinch.s <= 1 / down) {
      awmZoom(-1, pinch.cx, pinch.cy);
      pinch.s *= down;
    }
    up = ratio(1); down = ratio(-1);
    if (!up && pinch.s > 1) {
      overzoom(pinch.s);
      pinch.s = 1;
    }
    // At the farthest level, allow a little rubber-band stretch only.
    pinch.s = Math.max(pinch.s, down ? 1 / down : 0.87);
    preview(pinch.s);
  };

  window.awmPinchEnd = function () {
    if (!pinch) return;
    var up = ratio(1), down = ratio(-1);
    // Commit once the pinch is ~40% of the way (in log scale) to the next level.
    if (up && pinch.s >= Math.pow(up, 0.4)) settle(up, 1);
    else if (down && pinch.s <= Math.pow(1 / down, 0.4)) settle(1 / down, -1);
    else settle(1, 0);
  };

  // Animated single-step zoom for double-click / two-finger double-tap.
  window.awmZoomAnimated = function (dir, cx, cy) {
    if (typeof view === 'undefined') return;
    finishSettle();
    var r = ratio(dir);
    if (!r) {
      if (dir > 0) overzoom(2);
      return;
    }
    pinch = { s: 1, cx: cx, cy: cy };
    settle(dir > 0 ? r : 1 / r, dir);
  };

  window.addEventListener('resize', function () {
    if (typeof view !== 'undefined') reload();
  });
})();
"""

final class MapWebView: WKWebView {
    private var lastDrag: NSPoint?

    // Page magnification beyond the map's most detailed level (see overzoom()).
    private let maxMagnification: CGFloat = 6
    private var nativePinch = false     // current pinch is driving page magnification
    private var zoomAnchor: NSPoint = .zero  // view coordinates of the pinch/click

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Event location in CSS pixels relative to the top-left of the view.
    private func cssPoint(_ event: NSEvent) -> NSPoint {
        let p = convert(event.locationInWindow, from: nil)
        return NSPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
    }

    private func js(_ script: String) {
        evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: Two-finger trackpad pan (and mouse wheel)

    override func scrollWheel(with event: NSEvent) {
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            dx *= 10
            dy *= 10
        }
        if dx != 0 || dy != 0 {
            // Keep the map under the fingers when the page is magnified.
            js("awmPan(\(dx / magnification), \(dy / magnification))")
        }
        if event.phase == .ended || event.momentumPhase == .ended {
            js("awmPanEnd()")
        }
    }

    // MARK: Pinch to zoom

    override func magnify(with event: NSEvent) {
        switch event.phase {
        case .began:
            zoomAnchor = convert(event.locationInWindow, from: nil)
            nativePinch = magnification > 1
            if nativePinch {
                magnifyPage(by: event.magnification)
            } else {
                let p = cssPoint(event)
                js("awmPinchBegin(\(p.x), \(p.y)); awmPinch(\(event.magnification))")
            }
        case .changed:
            if nativePinch {
                magnifyPage(by: event.magnification)
            } else {
                js("awmPinch(\(event.magnification))")
            }
        case .ended, .cancelled:
            js(nativePinch ? "awmPinchEnd(); awmPanEnd()" : "awmPinchEnd()")
            nativePinch = false
        default:
            break
        }
    }

    private func magnifyPage(by delta: CGFloat) {
        let target = min(max(magnification * (1 + delta), 1), maxMagnification)
        setPageMagnification(target)
        if target <= 1 && delta < 0 {
            // Back at 1x: hand the rest of the pinch to the map's own zoom levels.
            nativePinch = false
            let p = anchorCSSPoint
            js("awmPinchBegin(\(p.x), \(p.y))")
        }
    }

    private var anchorCSSPoint: NSPoint {
        NSPoint(x: zoomAnchor.x, y: isFlipped ? zoomAnchor.y : bounds.height - zoomAnchor.y)
    }

    /// The page itself never scrolls (the map scrolls inside it), so magnification always
    /// grows from the top-left corner. Pan the map to keep the anchor point fixed instead.
    private func setPageMagnification(_ target: CGFloat) {
        let old = magnification
        guard target != old else { return }
        setMagnification(target, centeredAt: .zero)
        let p = anchorCSSPoint
        js("awmPan(\(p.x / target - p.x / old), \(p.y / target - p.y / old))")
    }

    /// Called when the map is at its most detailed level and wants to zoom further.
    func overzoom(by factor: CGFloat) {
        nativePinch = true
        setPageMagnification(min(magnification * factor, maxMagnification))
    }

    private func zoomIn(at event: NSEvent) {
        zoomAnchor = convert(event.locationInWindow, from: nil)
        if magnification > 1 {
            overzoom(by: 2)
            nativePinch = false
            js("awmPanEnd()")
        } else {
            let p = cssPoint(event)
            js("awmZoomAnimated(1, \(p.x), \(p.y))")
        }
    }

    // Two-finger double tap
    override func smartMagnify(with event: NSEvent) {
        zoomIn(at: event)
    }

    // MARK: Click-and-drag pan

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)  // ends editing in the year field
        if event.clickCount == 2 {
            zoomIn(at: event)
            return
        }
        lastDrag = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastDrag else { return }
        let now = event.locationInWindow
        js("awmPan(\((now.x - last.x) / magnification), \((last.y - now.y) / magnification))")
        lastDrag = now
    }

    override func mouseUp(with event: NSEvent) {
        if lastDrag != nil { js("awmPanEnd()") }
        lastDrag = nil
    }

    // Swallow the page's context menu
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

// MARK: - Year control

/// Floating Liquid Glass pill for picking the map's year. Years are signed like the
/// map's own dates: negative is BCE, positive is CE. There is no year 0.
final class YearBar: NSView, NSTextFieldDelegate {
    private let field = NSTextField()
    private let eraButton = NSButton(title: "", target: nil, action: nil)
    private let step = 100
    private let range = -20000...Calendar.current.component(.year, from: Date())
    private(set) var year: Int
    var onChange: ((Int) -> Void)?

    init(year: Int) {
        self.year = year
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let earlier = Self.button("chevron.left", "\(step) years earlier", self, #selector(stepEarlier))
        let later = Self.button("chevron.right", "\(step) years later", self, #selector(stepLater))

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        field.placeholderString = "Year"
        field.delegate = self
        field.target = self
        field.action = #selector(commit)
        field.widthAnchor.constraint(equalToConstant: 58).isActive = true

        eraButton.isBordered = false
        eraButton.target = self
        eraButton.action = #selector(toggleEra)
        eraButton.toolTip = "Switch between BCE and CE"
        eraButton.alignment = .left
        eraButton.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let stack = NSStackView(views: [earlier, field, eraButton, later])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let glass = Self.makeGlass(content: stack, cornerRadius: 22)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.heightAnchor.constraint(equalToConstant: 44),
        ])
        showYear()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Real Liquid Glass (NSGlassEffectView, macOS 26+) looked up at runtime, since the
    /// installed SDK predates it. Falls back to a blurred material on older systems.
    private static func makeGlass(content: NSView, cornerRadius: CGFloat) -> NSView {
        if let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let glass = glassClass.init(frame: .zero)
            glass.setValue(content, forKey: "contentView")
            glass.setValue(cornerRadius, forKey: "cornerRadius")
            return glass
        }
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = cornerRadius
        blur.layer?.cornerCurve = .continuous
        blur.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            content.topAnchor.constraint(equalTo: blur.topAnchor),
            content.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        return blur
    }

    private static func button(_ symbol: String, _ label: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))!
        let button = NSButton(image: image, target: target, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 32),
        ])
        return button
    }

    private func showYear() {
        field.stringValue = String(abs(year))
        eraButton.attributedTitle = NSAttributedString(string: year < 0 ? "BCE" : "CE", attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    private func set(_ newYear: Int) {
        let clamped = min(max(newYear, range.lowerBound), range.upperBound)
        year = clamped == 0 ? 1 : clamped
        showYear()
        onChange?(year)
    }

    /// The typed number in the current era, or nil if it isn't a valid year.
    private var typedYear: Int? {
        guard let value = Int(field.stringValue), value > 0 else { return nil }
        let signed = year < 0 ? -value : value
        return range.contains(signed) ? signed : nil
    }

    @objc private func commit() {
        if let value = typedYear {
            if value != year { set(value) }
        } else {
            NSSound.beep()
            showYear()
        }
    }

    @objc private func toggleEra() {
        set(-(typedYear ?? year))
    }

    /// Moves by `delta` years, skipping the nonexistent year 0 (1 BCE is followed by 1 CE).
    private func move(by delta: Int) {
        var next = year + delta
        if year < 0 && next >= 0 { next += 1 }
        if year > 0 && next <= 0 { next -= 1 }
        set(next)
    }

    @objc private func stepEarlier() { move(by: -step) }
    @objc private func stepLater() { move(by: step) }

    // Digits only; Up/Down arrows step through time.
    func controlTextDidChange(_ obj: Notification) {
        let digits = field.stringValue.filter(\.isNumber)
        if digits != field.stringValue { field.stringValue = digits }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): stepEarlier(); return true
        case #selector(NSResponder.moveDown(_:)): stepLater(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            showYear()
            window?.makeFirstResponder(nil)
            return true
        default: return false
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var webView: MapWebView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(
            WKUserScript(source: injectedJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        config.userContentController.add(self, name: "awm")

        webView = MapWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Ancient World Map"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 0.62, green: 0.72, blue: 0.77, alpha: 1)
        window.minSize = NSSize(width: 400, height: 300)
        let container = NSView()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        // Matches the year in mapURL.
        let yearBar = YearBar(year: -1600)
        yearBar.onChange = { [weak self] year in
            self?.webView.evaluateJavaScript(
                "if (typeof set_date === 'function') set_date(\(year))", completionHandler: nil)
        }
        container.addSubview(yearBar)
        NSLayoutConstraint.activate([
            yearBar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            yearBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
        ])
        window.contentView = container
        window.setFrameAutosaveName("AncientWorldMapWindow")
        if !window.setFrameUsingName("AncientWorldMapWindow") { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)

        webView.load(URLRequest(url: mapURL))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any], let factor = body["over"] as? Double {
            webView.overzoom(by: factor)
        }
    }

    // Keep the window on the map: block outbound links and pop-ups.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let isMainFrameLink = action.targetFrame?.isMainFrame ?? true
        decisionHandler(isMainFrameLink && action.navigationType == .linkActivated ? .cancel : .allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

let mainMenu = NSMenu()
let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit Ancient World Map", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
let windowItem = NSMenuItem()
mainMenu.addItem(windowItem)
let windowMenu = NSMenu(title: "Window")
windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
windowMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
windowMenu.items.last?.keyEquivalentModifierMask = [.command, .control]
windowItem.submenu = windowMenu
app.mainMenu = mainMenu

app.activate(ignoringOtherApps: true)
app.run()
