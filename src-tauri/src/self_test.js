(async () => {
  const out = [];
  const report = () => (document.title = "self-test:" + JSON.stringify(out));
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  try {
    const app = window.haneokaApp;
    out.push({ bridge: !!app, ua: navigator.userAgent.includes("HaneokaApp/"), capabilities: app?.capabilities });
    report();
    for (const [method, args] of [["gameAccounts", {}], ["saveSources", {}], ["adbDevices", {}], ["iosBackups", {}]]) {
      try {
        out.push({ method, value: await app.call(method, args) });
      } catch (error) {
        out.push({ method, error: String(error) });
      }
      report();
    }
    if (location.pathname.endsWith("/saves/")) {
      await wait(2500);
      const rows = [...document.querySelectorAll("save-workspace .detail-object")].map((b) => b.textContent.trim().replace(/\s+/g, " "));
      out.push({ rows });
      report();
      const usb = [...document.querySelectorAll("save-workspace button.detail-object")].find((b) => /USB/.test(b.textContent));
      usb?.click();
      await wait(2500);
      out.push({ dialog: document.querySelector("save-workspace dialog[open] .dialog__body")?.textContent.trim().replace(/\s+/g, " ") });
      report();
    }
  } catch (error) {
    out.push({ error: String(error) });
    report();
  }
})();
