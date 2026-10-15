// Shared helpers for the invite functions. No dependencies.
const crypto = require("node:crypto");

const REPO = process.env.SNAPPER_REPO || "arif12islam/snapper";

function secret() {
  const s = process.env.SIGNING_SECRET;
  if (!s || s.length < 16) throw new Error("SIGNING_SECRET is missing or too short");
  return s;
}

function b64url(buf) {
  return Buffer.from(buf).toString("base64url");
}

/** A link that proves an email was invited and stops working after `days`. */
function makeToken(email, days = 7) {
  const payload = b64url(JSON.stringify({ e: email, exp: Date.now() + days * 86400000 }));
  const sig = crypto.createHmac("sha256", secret()).update(payload).digest("base64url");
  return `${payload}.${sig}`;
}

function readToken(token) {
  if (typeof token !== "string" || !token.includes(".")) return null;
  const [payload, sig] = token.split(".");
  const expected = crypto.createHmac("sha256", secret()).update(payload).digest("base64url");
  const a = Buffer.from(sig || "");
  const b = Buffer.from(expected);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  try {
    const data = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
    if (!data.e || typeof data.exp !== "number" || data.exp < Date.now()) return null;
    return data;
  } catch {
    return null;
  }
}

function inviteList() {
  return (process.env.INVITE_EMAILS || "")
    .split(/[,\s]+/)
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
}

/** Exact address, or a whole domain written as @example.com. */
function isInvited(email) {
  const list = inviteList();
  const domain = "@" + email.split("@")[1];
  return list.includes(email) || list.includes(domain);
}

function validEmail(email) {
  return typeof email === "string" && email.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email);
}

async function latestDmg() {
  const headers = { "User-Agent": "snapper-site", Accept: "application/vnd.github+json" };
  if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers });
  if (!res.ok) throw new Error(`GitHub answered ${res.status}`);
  const release = await res.json();
  const asset = (release.assets || []).find((a) => a.name.toLowerCase().endsWith(".dmg"));
  if (!asset) throw new Error("The latest release has no .dmg");
  return { version: release.tag_name, url: asset.browser_download_url, name: asset.name };
}

async function sendMail({ to, subject, html, text }) {
  const key = process.env.RESEND_API_KEY;
  const from = process.env.MAIL_FROM;
  if (!key || !from) throw new Error("RESEND_API_KEY or MAIL_FROM is missing");
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from, to, subject, html, text }),
  });
  if (!res.ok) throw new Error(`Email service answered ${res.status}`);
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

module.exports = { makeToken, readToken, isInvited, validEmail, latestDmg, sendMail, escapeHtml };
