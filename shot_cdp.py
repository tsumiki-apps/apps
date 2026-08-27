import json, base64, subprocess, time, urllib.request, sys, os, signal
import websocket

URL, OUT, W, H = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
MOBILE = len(sys.argv) > 5 and sys.argv[5] == 'mobile'
CH = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PORT = 9333
prof = "/private/tmp/claude-501/-Users-ko-dai----/560cef22-86ef-4eb6-a89d-69900c648e8b/scratchpad/chromeprof"

p = subprocess.Popen([CH, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                      f"--remote-debugging-port={PORT}", f"--user-data-dir={prof}", "--remote-allow-origins=*",
                      "about:blank"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    ws_url = None
    for _ in range(60):
        try:
            tabs = json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json/list"))
            for t in tabs:
                if t.get("type") == "page" and t.get("webSocketDebuggerUrl"):
                    ws_url = t["webSocketDebuggerUrl"]; break
            if ws_url: break
            # ページターゲットが無ければ作る
            req = urllib.request.Request(f"http://127.0.0.1:{PORT}/json/new?url=about:blank", method="PUT")
            try: urllib.request.urlopen(req)
            except Exception: pass
        except Exception: pass
        time.sleep(0.5)
    if not ws_url: raise SystemExit("Chrome did not expose a page target")

    ws = websocket.create_connection(ws_url, timeout=30)
    n = [0]
    def cmd(method, params=None):
        n[0] += 1
        ws.send(json.dumps({"id": n[0], "method": method, "params": params or {}}))
        while True:
            m = json.loads(ws.recv())
            if m.get("id") == n[0]:
                if "error" in m: raise SystemExit(f"{method}: {m['error']}")
                return m.get("result", {})

    cmd("Page.enable")
    cmd("Emulation.setDeviceMetricsOverride", {
        "width": W, "height": H, "deviceScaleFactor": float(os.environ.get("SHOT_DSF", 2)), "mobile": MOBILE,
        "screenWidth": W, "screenHeight": H})
    if MOBILE:
        cmd("Emulation.setTouchEmulationEnabled", {"enabled": True})
        cmd("Network.setUserAgentOverride", {"userAgent":
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
            "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"})
    cmd("Page.navigate", {"url": URL})
    time.sleep(5)
    JS = os.environ.get("SHOT_JS", "")
    if JS:
        cmd("Runtime.evaluate", {"expression": JS})
        time.sleep(2)
    r = cmd("Page.captureScreenshot", {"format": "png", "captureBeyondViewport": False})
    open(OUT, "wb").write(base64.b64decode(r["data"]))
    print("saved", OUT)
    ws.close()
finally:
    p.terminate()
