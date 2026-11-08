(async () => {
  const out = [];
  const report = () => (document.title = "self-test:" + JSON.stringify(out));
  try {
    const app = window.haneokaApp;
    out.push({ bridge: !!app, internals: !!window.__TAURI_INTERNALS__, ua: navigator.userAgent.includes("HaneokaApp/"), capabilities: app?.capabilities });
    report();
    for (const [method, args] of [["gameAccounts", {}], ["saveSources", {}], ["songProgress", { server: "jp" }], ["nope", {}]]) {
      try {
        out.push({ method, value: await app.call(method, args) });
      } catch (error) {
        out.push({ method, error: String(error) });
      }
      report();
    }
  } catch (error) {
    out.push({ error: String(error) });
    report();
  }
})();
