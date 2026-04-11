// Preload: route Node.js global fetch AND WebSocket through HTTPS_PROXY.
//
// Problem: Node 22's built-in fetch/WebSocket use an internal bundled undici
// that does not honour HTTPS_PROXY and whose dispatcher cannot be patched from
// user-land code.
//
// Solution:
//   - fetch  → replaced with npm-undici's fetch wired to a ProxyAgent
//   - WebSocket → replaced with a browser-API-compatible wrapper around the
//                 `ws` npm package, which supports https-proxy-agent natively
//
// The shell hook exports GLOBAL_NODE_MODULES (= npm root -g) and NODE_PATH
// so that bare require() calls in this file resolve to the global npm store.
const proxyUrl = process.env.HTTPS_PROXY || process.env.https_proxy;
if (!proxyUrl) return;

const root = process.env.GLOBAL_NODE_MODULES;
if (!root) return;

try {
  // ── fetch ──────────────────────────────────────────────────────────────────
  const { ProxyAgent, setGlobalDispatcher, fetch: undiciFetch } =
    require(root + '/undici');
  const dispatcher = new ProxyAgent(proxyUrl);
  setGlobalDispatcher(dispatcher);
  globalThis.fetch = (url, opts) => undiciFetch(url, { ...opts, dispatcher });

  // ── WebSocket ──────────────────────────────────────────────────────────────
  // `ws` + https-proxy-agent@5 (CJS) is the proven way to tunnel wss:// via
  // CONNECT proxy.  We shim the browser WebSocket API so existing callers
  // (obsidian-headless) work without modification.
  const WS = require(root + '/ws');
  const { HttpsProxyAgent } = require(root + '/https-proxy-agent');

  const CONNECTING = 0, OPEN = 1, CLOSING = 2, CLOSED = 3;

  class ProxiedWebSocket extends EventTarget {
    static get CONNECTING() { return CONNECTING; }
    static get OPEN()       { return OPEN; }
    static get CLOSING()    { return CLOSING; }
    static get CLOSED()     { return CLOSED; }

    constructor(url, protocols) {
      super();
      this._onopen    = null;
      this._onclose   = null;
      this._onerror   = null;
      this._onmessage = null;
      this.binaryType = 'arraybuffer';

      this._ws = new WS(url.toString(),
        protocols ? (Array.isArray(protocols) ? protocols : [protocols]) : [],
        { agent: new HttpsProxyAgent(proxyUrl) }
      );

      this._ws.on('open', () => {
        const ev = new Event('open');
        this.dispatchEvent(ev);
        if (typeof this._onopen === 'function') this._onopen(ev);
      });

      // ws 8.x passes (data, isBinary) to the message callback.
      // Text frames (isBinary=false) arrive as Buffer of UTF-8 bytes;
      // binary frames (isBinary=true) as Buffer of raw bytes.
      // The browser WebSocket API delivers text as string and binary as
      // ArrayBuffer (when binaryType='arraybuffer').
      this._ws.on('message', (d, isBinary) => {
        let data;
        if (!isBinary) {
          // Text frame — convert Buffer → string
          data = Buffer.isBuffer(d) ? d.toString('utf8') : d;
        } else if (this.binaryType === 'arraybuffer' && Buffer.isBuffer(d)) {
          // Binary frame — convert Buffer → ArrayBuffer
          data = d.buffer.slice(d.byteOffset, d.byteOffset + d.byteLength);
        } else {
          data = d;
        }
        const ev = new MessageEvent('message', { data });
        this.dispatchEvent(ev);
        if (typeof this._onmessage === 'function') this._onmessage(ev);
      });

      this._ws.on('close', (code, reason) => {
        const reasonStr = Buffer.isBuffer(reason) ? reason.toString() : (reason || '');
        // CloseEvent is not available in Node.js — synthesise a compatible object.
        const ev = Object.assign(new Event('close'), {
          code,
          reason: reasonStr,
          wasClean: code === 1000,
        });
        this.dispatchEvent(ev);
        if (typeof this._onclose === 'function') this._onclose(ev);
      });

      this._ws.on('error', (err) => {
        const ev = Object.assign(new Event('error'), {
          error: err,
          message: err.message,
        });
        this.dispatchEvent(ev);
        if (typeof this._onerror === 'function') this._onerror(ev);
      });
    }

    get readyState() {
      switch (this._ws.readyState) {
        case WS.CONNECTING: return CONNECTING;
        case WS.OPEN:       return OPEN;
        case WS.CLOSING:    return CLOSING;
        case WS.CLOSED:     return CLOSED;
        default:            return CLOSED;
      }
    }

    get url()      { return this._ws.url; }
    get protocol() { return this._ws.protocol || ''; }

    send(data) { this._ws.send(data); }
    close(code, reason) { this._ws.close(code, reason); }

    // on* property aliases (obsidian-headless assigns these directly)
    set onopen(fn)    { this._onopen    = fn; }
    get onopen()      { return this._onopen; }
    set onclose(fn)   { this._onclose   = fn; }
    get onclose()     { return this._onclose; }
    set onerror(fn)   { this._onerror   = fn; }
    get onerror()     { return this._onerror; }
    set onmessage(fn) { this._onmessage = fn; }
    get onmessage()   { return this._onmessage; }
  }

  globalThis.WebSocket = ProxiedWebSocket;

} catch (e) {
  process.stderr.write('[node-proxy-bootstrap] error: ' + e.stack + '\n');
}
