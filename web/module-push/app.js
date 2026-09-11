"use strict";
const keyInput = document.querySelector("#public-key");
const statusLabel = document.querySelector("#status");
const subscribeButton = document.querySelector("#subscribe");
const downloadButton = document.querySelector("#download");
const copyButton = document.querySelector("#copy");
let registration;
let exported;
const storedKey = "djonehub-notify-public-key";

function say(message) { statusLabel.textContent = message; }
function decodeKey(value) {
  if (!/^[A-Za-z0-9_-]{87}$/.test(value)) throw new Error("请检查公钥是否完整（87 个字符）。");
  const bytes = Uint8Array.from(atob(value.replace(/-/g, "+").replace(/_/g, "/") + "="), c => c.charCodeAt(0));
  if (bytes.length !== 65 || bytes[0] !== 4) throw new Error("这不是有效的模块通知公钥。");
  return bytes;
}
function updateExport(subscription, publicKey) {
  const value = subscription.toJSON();
  // Omit browser-specific fields such as expirationTime for the strict CLI.
  exported = JSON.stringify({version: 1, public_key: publicKey, subscription: {endpoint: value.endpoint, keys: value.keys}}, null, 2);
  downloadButton.disabled = copyButton.disabled = false;
}
subscribeButton.addEventListener("click", async () => {
  subscribeButton.disabled = true;
  try {
    const publicKey = keyInput.value.trim();
    const key = decodeKey(publicKey);
    if (!registration) throw new Error("通知服务尚未就绪，请稍后重试。");
    // Request permission directly from the click before awaiting unrelated
    // work, preserving Safari's user-gesture requirement.
    if (Notification.permission !== "granted" && await Notification.requestPermission() !== "granted") {
      throw new Error("尚未允许通知。请从主屏幕打开，并在系统设置中允许提醒。");
    }
    const existing = await registration.pushManager.getSubscription();
    if (existing) {
      const oldKey = new Uint8Array(existing.options.applicationServerKey || []);
      if (oldKey.length !== key.length || oldKey.some((value, index) => value !== key[index])) throw new Error("此网页已连接另一个模块。请先停止提醒，再使用新公钥连接。");
    }
    const subscription = existing || await registration.pushManager.subscribe({userVisibleOnly: true, applicationServerKey: key});
    localStorage.setItem(storedKey, publicKey);
    updateExport(subscription, publicKey);
    say("已允许提醒。请导出配对文件并导入模块；收到测试通知后，才算完成连接。");
  } catch (error) {
    say(error.name === "NotAllowedError" ? "尚未允许通知。请从主屏幕打开，并在系统设置中允许提醒。" : error.message);
  } finally { subscribeButton.disabled = false; }
});
downloadButton.addEventListener("click", () => {
  if (!exported) return;
  const url = URL.createObjectURL(new Blob([exported], {type: "application/json"}));
  const link = document.createElement("a");
  link.href = url; link.download = "djonehub-push-subscription.json";
  document.body.append(link); link.click(); link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10000);
});
copyButton.addEventListener("click", async () => {
  try { await navigator.clipboard.writeText(exported); say("已复制配对内容。请只交给你自己的模块。"); }
  catch { say("无法复制，请使用“导出配对文件”。"); }
});
document.querySelector("#disconnect").addEventListener("click", async () => {
  try {
    const subscription = await registration?.pushManager.getSubscription();
    if (subscription && !(await subscription.unsubscribe())) throw new Error("取消订阅失败，请重试。");
    localStorage.removeItem(storedKey);
    exported = undefined;
    downloadButton.disabled = copyButton.disabled = true;
    say("已停止提醒。模块上保存的订阅也可以移除。");
  } catch (error) { say(error.message); }
});
(async () => {
  try {
    keyInput.value = localStorage.getItem(storedKey) || "";
    if (!isSecureContext || !("serviceWorker" in navigator) || !("PushManager" in window) || !("Notification" in window)) {
      subscribeButton.disabled = true;
      say("此环境尚不支持推送。iPhone 请使用 HTTPS 页面，添加到主屏幕后打开（iOS 16.4 或更新版本）。");
      return;
    }
    registration = await navigator.serviceWorker.register("./sw.js", {scope: "./"});
    registration = await navigator.serviceWorker.ready;
    say("准备就绪。输入模块通知公钥，即可允许提醒。");
    const existing = await registration.pushManager.getSubscription();
    if (existing && keyInput.value) {
      const key = decodeKey(keyInput.value);
      const existingKey = new Uint8Array(existing.options.applicationServerKey || []);
      if (existingKey.length === key.length && existingKey.every((v, i) => v === key[i])) {
        updateExport(existing, keyInput.value);
        say("此设备已订阅。你可以重新导出配对文件，或从模块发送测试通知。");
      }
    }
  } catch { say("无法初始化提醒页面，请确认网络连接和浏览器权限后重新打开。"); }
})();
