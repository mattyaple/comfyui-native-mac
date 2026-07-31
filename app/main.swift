import Cocoa
import WebKit
import UniformTypeIdentifiers

let serverURL = URL(string: "http://127.0.0.1:8188/")!

func jsStringLiteral(_ s: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [s])
    let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
    return String(json.dropFirst().dropLast()) // ["x"] -> "x"
}

func dlog(_ msg: String) {
    let line = ISO8601DateFormatter().string(from: Date()) + " " + msg + "\n"
    let url = URL(fileURLWithPath: NSHomeDirectory() + "/ComfyUI/user/comfyui-app.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// JS bodies for callAsyncJavaScript. MUST be declared before app.run() below:
// main.swift is a script-mode file, so top-level lets execute in order — anything
// after app.run() (which never returns) is never initialized and reads as "".
// Native-equivalent drag-drop: replay real DOM DragEvents into the page so
// ComfyUI's OWN handlers do all routing — core nodes, custom node drop-zones
// (e.g. MultiImageLoader), Vue layers. The page cannot distinguish this from a
// browser drop. Files arrive as base64 args when small; larger files are
// uploaded natively and fetched back inside the page.
let dropReplayJS = """
  try {
    const list = [];
    for (const f of files) {
      let file;
      if (f.b64) {
        const bin = atob(f.b64);
        const arr = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
        file = new File([arr], f.name, { type: f.mime });
      } else {
        const short = f.name.split('/').pop();
        const r = await fetch('/api/view?filename=' + encodeURIComponent(short) + '&type=input&subfolder=' + encodeURIComponent(f.sub || ''));
        if (!r.ok) continue;
        const bl = await r.blob();
        file = new File([bl], short, { type: bl.type || f.mime });
      }
      list.push(file);
    }
    if (!list.length) return 'no-files';
    const dt = new DataTransfer();
    for (const f of list) dt.items.add(f);
    const el = document.elementFromPoint(x, y) || document.body;
    const mk = (t) => new DragEvent(t, { clientX: x, clientY: y, dataTransfer: dt, bubbles: true, cancelable: true });
    el.dispatchEvent(mk('dragover'));
    el.dispatchEvent(mk('drop'));
    window.__dropHoverEl = null;
    return 'replayed:' + list.length + '->' + el.tagName + '@' + Math.round(x) + ',' + Math.round(y);
  } catch (e) { return 'err:' + e.message; }
"""

let hoverReplayJS = """
  try {
    const el = document.elementFromPoint(x, y) || document.body;
    if (!window.__dropHoverDT) {
      const dt = new DataTransfer();
      dt.items.add(new File([new Uint8Array([137, 80, 78, 71])], 'drag.png', { type: 'image/png' }));
      window.__dropHoverDT = dt;
    }
    const dt = window.__dropHoverDT;
    const prev = window.__dropHoverEl;
    if (prev && prev !== el) {
      prev.dispatchEvent(new DragEvent('dragleave', { bubbles: true, cancelable: true, dataTransfer: dt }));
    }
    window.__dropHoverEl = el;
    el.dispatchEvent(new DragEvent('dragover', { clientX: x, clientY: y, dataTransfer: dt, bubbles: true, cancelable: true }));
  } catch (e) {}
"""

let leaveReplayJS = """
  try {
    const prev = window.__dropHoverEl;
    if (prev) {
      prev.dispatchEvent(new DragEvent('dragleave', { bubbles: true, cancelable: true }));
      window.__dropHoverEl = null;
    }
    const a = window.app;
    if (a) { a.dragOverNode = null; if (a.canvas) a.canvas.setDirty(true, true); }
  } catch (e) {}
"""

// WKWebView's own native→DOM drag translation misroutes file drops, so we intercept
// media-file drags natively and replay them into the page as DOM DragEvents at exact
// AppKit coordinates. ComfyUI's own handlers then do ALL routing natively — core node
// widgets, custom node DOM drop-zones, workflow-PNG loading — identical to a browser.
// Non-media drags (e.g. .json workflows) fall through to WebKit's standard handling.
final class DropWebView: WKWebView {
    private var lastHoverAt = Date.distantPast

    // Media files ComfyUI upload widgets accept (Load Image / Load Audio / Load Video).
    // Non-media drags (e.g. .json workflows) return empty here and fall through to WebKit.
    private func mediaFileURLs(_ sender: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier,
                                                UTType.audio.identifier,
                                                UTType.movie.identifier],
        ]
        return (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL]) ?? []
    }

    private func clientPoint(_ sender: NSDraggingInfo) -> (CGFloat, CGFloat) {
        let p = convert(sender.draggingLocation, from: nil)
        return (p.x, isFlipped ? p.y : bounds.height - p.y)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !mediaFileURLs(sender).isEmpty else { return super.draggingEntered(sender) }
        dlog("draggingEntered (media file)")
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !mediaFileURLs(sender).isEmpty else { return super.draggingUpdated(sender) }
        if Date().timeIntervalSince(lastHoverAt) > 0.08 {
            lastHoverAt = Date()
            let (x, y) = clientPoint(sender)
            callAsyncJavaScript(hoverReplayJS, arguments: ["x": x, "y": y], in: nil, in: .page) { _ in }
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let s = sender, !mediaFileURLs(s).isEmpty {
            callAsyncJavaScript(leaveReplayJS, arguments: [:], in: nil, in: .page) { _ in }
            return
        }
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Array(mediaFileURLs(sender).prefix(20))
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        let (x, y) = clientPoint(sender)
        dlog("performDrag: \(urls.count) file(s) at (\(Int(x)),\(Int(y)))")

        // Small files ride the JS bridge as base64; big ones upload natively and are
        // fetched back inside the page. Budget keeps the single JS call modest.
        var directBudget = 8 * 1024 * 1024
        var descriptors = [[String: Any]](repeating: [:], count: urls.count)
        let group = DispatchGroup()
        for (i, url) in urls.enumerated() {
            guard let data = try? Data(contentsOf: url), data.count < 512 * 1024 * 1024 else { continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            if data.count <= directBudget {
                directBudget -= data.count
                descriptors[i] = ["b64": data.base64EncodedString(), "name": url.lastPathComponent, "mime": mime]
            } else {
                group.enter()
                uploadNative(data: data, name: url.lastPathComponent, mime: mime) { fname, sub in
                    if let fname { descriptors[i] = ["b64": "", "name": fname, "sub": sub, "mime": mime] }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let files = descriptors.filter { !$0.isEmpty }
            guard !files.isEmpty else { dlog("performDrag: no readable files"); return }
            self.callAsyncJavaScript(dropReplayJS, arguments: ["files": files, "x": x, "y": y],
                                     in: nil, in: .page) { r in
                switch r {
                case .success(let v): dlog("drop replay: \(String(describing: v ?? "nil"))")
                case .failure(let e):
                    let ns = e as NSError
                    dlog("drop replay exception: \(ns.userInfo["WKJavaScriptExceptionMessage"] ?? ns.localizedDescription)")
                }
            }
        }
        return true
    }

    private func uploadNative(data: Data, name: String, mime: String,
                              completion: @escaping (String?, String) -> Void) {
        let boundary = "comfy-drop-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8188/upload/image")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func addField(_ s: String) { body.append(s.data(using: .utf8)!) }
        addField("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(name)\"\r\nContent-Type: \(mime)\r\n\r\n")
        body.append(data)
        addField("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n--\(boundary)--\r\n")
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { respData, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard err == nil, status == 200, let respData,
                  let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                  let fname = json["name"] as? String
            else {
                dlog("native upload failed: status=\(status) err=\(err?.localizedDescription ?? "none")")
                completion(nil, "")
                return
            }
            completion(fname, (json["subfolder"] as? String) ?? "")
        }.resume()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var pollTimer: Timer?
    var startedServer = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        if #available(macOS 12.3, *) { config.preferences.isElementFullscreenEnabled = true }
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = DropWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "ComfyUI"
        window.contentView = webView
        window.setFrameAutosaveName("ComfyUIMainWindow")
        window.isReleasedWhenClosed = false
        if window.frame.origin == .zero { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        showLoadingPage(message: "Checking ComfyUI server…")
        checkServer { up in
            if up { self.loadUI() } else { self.startServerAndWait() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // ⌘Q: offer to also stop the background server (with a queue warning).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let (up, queued) = serverStateSync(), up else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "Quit ComfyUI"
        a.informativeText = queued > 0
            ? "The ComfyUI server is running with \(queued) job\(queued == 1 ? "" : "s") in the queue. Stopping the server will cancel them."
            : "The ComfyUI server is running in the background."
        a.addButton(withTitle: "Quit, Keep Server Running")
        a.addButton(withTitle: "Quit & Stop Server")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            return .terminateNow
        case .alertSecondButtonReturn:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            p.arguments = ["-f", "ComfyUI/main.py"]
            try? p.run()
            p.waitUntilExit()
            dlog("server stopped via quit dialog")
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    // Quick synchronous probe used only during quit: (serverUp, queuedJobs).
    private func serverStateSync() -> (Bool, Int)? {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8188/api/queue")!)
        req.timeoutInterval = 1
        var result: (Bool, Int)?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { result = (false, 0); return }
            var queued = 0
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                queued = ((json["queue_running"] as? [Any])?.count ?? 0)
                    + ((json["queue_pending"] as? [Any])?.count ?? 0)
            }
            result = (true, queued)
        }.resume()
        _ = sem.wait(timeout: .now() + 1.5)
        return result ?? (false, 0)
    }

    func showLoadingPage(message: String) {
        let html = """
        <html><body style="background:#171717;color:#ddd;font-family:-apple-system,sans-serif;\
        display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
        <div style="text-align:center">
        <div style="width:36px;height:36px;margin:0 auto 18px;border:3px solid #333;border-top-color:#4a90d9;\
        border-radius:50%;animation:r 0.9s linear infinite"></div>
        <div style="font-size:17px">\(message)</div>
        <div id="s" style="font-size:12px;color:#888;margin-top:10px"></div></div>
        <style>@keyframes r{to{transform:rotate(360deg)}}</style>
        <script>let n=0;setInterval(()=>{document.getElementById('s').textContent=(++n)+'s';},1000)</script>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func checkServer(_ done: @escaping (Bool) -> Void) {
        var req = URLRequest(url: serverURL)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            DispatchQueue.main.async { done((resp as? HTTPURLResponse)?.statusCode == 200) }
        }.resume()
    }

    func startServerAndWait() {
        if !startedServer {
            startedServer = true
            showLoadingPage(message: "Starting ComfyUI server…")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", "nohup \"$HOME/ComfyUI/start.sh\" >> \"$HOME/ComfyUI/user/comfyui-server.log\" 2>&1 &"]
            try? p.run()
        }
        var waited = 0
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { t in
            waited += 1
            if waited > 120 {
                t.invalidate()
                self.showLoadingPage(message: "Server didn't start — check ~/ComfyUI/user/comfyui-server.log")
                return
            }
            self.checkServer { up in
                if up { t.invalidate(); self.loadUI() }
            }
        }
    }

    func loadUI() { webView.load(URLRequest(url: serverURL)) }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        dlog("page loaded: \(webView.url?.absoluteString ?? "?")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            // Startup self-checks for the replay architecture: (1) globals persist
            // across separate evaluations, (2) MB-scale args marshal intact.
            webView.callAsyncJavaScript("window.__probePersist = 'yes'; return 'set';",
                                        arguments: [:], in: nil, in: .page) { _ in
                webView.callAsyncJavaScript("return 'persist:' + (window.__probePersist || 'NO');",
                                            arguments: [:], in: nil, in: .page) { r in
                    dlog("probe globals: \(String(describing: (try? r.get()) ?? "nil"))")
                }
            }
            let big = String(repeating: "a", count: 2 * 1024 * 1024)
            webView.callAsyncJavaScript("return 'bigArg:' + a.length;",
                                        arguments: ["a": big], in: nil, in: .page) { r in
                dlog("probe 2MB arg: \(String(describing: (try? r.get()) ?? "nil"))")
            }
            let tinyPng = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
            let probeFiles: [[String: Any]] = [["b64": tinyPng, "name": "replay-probe.png", "mime": "image/png"]]
            webView.callAsyncJavaScript(dropReplayJS, arguments: ["files": probeFiles, "x": 4.0, "y": 4.0],
                                        in: nil, in: .page) { r in
                dlog("probe replay dispatch: \(String(describing: (try? r.get()) ?? "nil"))")
            }
        }
    }

    @objc func reloadPage(_ sender: Any?) {
        checkServer { up in up ? self.loadUI() : self.startServerAndWait() }
    }

    @objc func openInBrowser(_ sender: Any?) { NSWorkspace.shared.open(serverURL) }

    // target=_blank links (docs, node repos) → default browser
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        if let url = navigationAction.request.url,
           let host = url.host, host != "127.0.0.1", host != "localhost",
           navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // workflow exports etc. → ~/Downloads
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var dest = downloads.appendingPathComponent(suggestedFilename)
        let base = dest.deletingPathExtension().lastPathComponent
        let ext = dest.pathExtension
        var i = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = downloads.appendingPathComponent("\(base)-\(i)" + (ext.isEmpty ? "" : ".\(ext)"))
            i += 1
        }
        completionHandler(dest)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = message
        a.runModal(); completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert(); a.messageText = prompt
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        tf.stringValue = defaultText ?? ""
        a.accessoryView = tf
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn ? tf.stringValue : nil)
    }

    // <input type=file> (Load workflow / image upload)
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.begin { r in completionHandler(r == .OK ? panel.urls : nil) }
    }
}

func makeMenu(_ delegate: AppDelegate) -> NSMenu {
    let main = NSMenu()

    let appItem = NSMenuItem(); main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "About ComfyUI", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide ComfyUI", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit ComfyUI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu

    let editItem = NSMenuItem(); main.addItem(editItem)
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit

    let viewItem = NSMenuItem(); main.addItem(viewItem)
    let view = NSMenu(title: "View")
    view.addItem(withTitle: "Reload", action: #selector(AppDelegate.reloadPage(_:)), keyEquivalent: "r")
    view.addItem(withTitle: "Open in Browser", action: #selector(AppDelegate.openInBrowser(_:)), keyEquivalent: "b")
    view.addItem(.separator())
    let fs = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
    fs.keyEquivalentModifierMask = [.command, .control]
    viewItem.submenu = view

    let windowItem = NSMenuItem(); main.addItem(windowItem)
    let win = NSMenu(title: "Window")
    win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    win.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowItem.submenu = win
    NSApp.windowsMenu = win

    return main
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.mainMenu = makeMenu(delegate)
app.run()

// Injected into the ComfyUI page. Makes the whole window a file drop zone and routes
// image drops onto the node under the cursor through ComfyUI's own upload + widget API,
// reusing the app's node hit-testing so it behaves exactly like a browser drop.

// Replays native drags as DOM DragEvents so ComfyUI's own handlers run — validated
// against the live frontend (synthetic dragover+drop routed a file into a node).
// Function bodies for callAsyncJavaScript — arguments arrive as named parameters,
// everything is self-contained per call (no window globals; those don't persist in
// this WKWebView for reasons WebKit keeps to itself). Drop replays ComfyUI's own DOM
// drag events, which was validated against the live frontend.
