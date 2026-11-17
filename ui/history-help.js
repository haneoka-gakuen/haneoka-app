import { t, icon, escape, snackbar, failure } from "./app.js";

export const historyHelpButton = () => `<button class="icon-button" type="button" data-history-help aria-label="${escape(t("readHelp"))}">${icon("help")}</button>`;

export function showHistoryHelp() {
  if (document.querySelector("[data-history-help-dialog]")) return;
  const previous = document.activeElement;
  const dialog = document.createElement("dialog");
  dialog.dataset.historyHelpDialog = "";
  dialog.setAttribute("aria-labelledby", "history-help-title");
  dialog.innerHTML = `<h2 id="history-help-title">${escape(t("readHelpTitle"))}</h2>
    <div class="dialog__body"><p>${escape(t("readHelpSummary"))}</p>
    <ol><li>${escape(t("readHelpStep1"))}</li><li>${escape(t("readHelpStep2"))}</li><li>${escape(t("readHelpStep3"))}</li></ol>
    <p>${escape(t("readHelpCredentials"))}</p><p>${escape(t("readHelpPrivacy"))}</p><p>${escape(t("readHelpOther"))}</p></div>
    <div class="dialog__actions"><button class="button button--text" type="button">${escape(t("close"))}</button></div>`;
  dialog.querySelector("button").addEventListener("click", () => dialog.close());
  dialog.addEventListener("close", () => { dialog.remove(); if (previous?.isConnected) previous.focus(); }, { once: true });
  document.body.append(dialog);
  dialog.showModal();
}

let installed = false;
export function installHistoryHelp() {
  if (installed) return;
  installed = true;
  document.addEventListener("click", event => { if (event.target.closest("[data-history-help]")) showHistoryHelp(); });
}

export function showReadingFailure(error) {
  const code = String(error?.message ?? error ?? "");
  const action = /history_|no_session/.test(code) ? { label: t("readHelp"), run: showHistoryHelp } : undefined;
  snackbar(failure(error), { action });
}
