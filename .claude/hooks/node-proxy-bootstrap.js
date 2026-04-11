// Preload: route Node.js global fetch through HTTPS_PROXY.
// Node 22's built-in fetch (undici) does not auto-honour HTTPS_PROXY,
// but the npm-installed undici exposes setGlobalDispatcher + ProxyAgent.
// The shell hook sets GLOBAL_NODE_MODULES so we can find undici without
// hardcoding a path.
const proxyUrl = process.env.HTTPS_PROXY || process.env.https_proxy;
if (proxyUrl) {
  const root = process.env.GLOBAL_NODE_MODULES;
  if (root) {
    try {
      const { ProxyAgent, setGlobalDispatcher } = require(root + '/undici');
      setGlobalDispatcher(new ProxyAgent(proxyUrl));
    } catch (e) {
      process.stderr.write('[node-proxy-bootstrap] could not set proxy dispatcher: ' + e.message + '\n');
    }
  }
}
