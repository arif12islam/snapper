// POST /api/request  { email }
// Always answers the same way, so the invite list cannot be probed.
const { makeToken, isInvited, validEmail, sendMail, escapeHtml } = require("./_lib");

const NEUTRAL = "Thanks. If you have been invited, your download link is on its way. Check your inbox in a minute.";

module.exports = async (req, res) => {
  res.setHeader("Cache-Control", "no-store");
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json({ error: "Method not allowed" });
  }

  const body = typeof req.body === "string" ? safeParse(req.body) : req.body || {};
  if (body.website) return res.status(200).json({ message: NEUTRAL });     // honeypot field, bots fill it in

  const email = String(body.email || "").trim().toLowerCase();
  if (!validEmail(email)) return res.status(400).json({ error: "Enter a valid email address." });

  try {
    const origin = process.env.SITE_URL || `https://${req.headers.host}`;
    if (isInvited(email)) {
      const link = `${origin}/api/download?token=${encodeURIComponent(makeToken(email))}`;
      await sendMail({
        to: email,
        subject: "Your Snapper download",
        text: [
          "Here is your link to download Snapper for macOS.",
          "",
          link,
          "",
          "The link works for 7 days and always serves the latest version.",
          "Works on any Mac with an M chip (M1 or newer), on macOS Sonoma or newer.",
          "First launch: open the .dmg, drag Snapper to Applications, open it, then approve it once under System Settings > Privacy & Security > Open Anyway. Step by step: " + origin + "/install.html",
          "",
          "Snapper, built by Bykorp",
        ].join("\n"),
        html: mailHtml(link, origin + "/install.html"),
      });
    } else if (process.env.OWNER_EMAIL) {
      // Not on the list: tell the owner so they can invite the person.
      await sendMail({
        to: process.env.OWNER_EMAIL,
        subject: "Snapper invite request",
        text: `${email} asked for a Snapper invite.`,
        html: `<p>${escapeHtml(email)} asked for a Snapper invite.</p>`,
      });
    }
  } catch (err) {
    console.error("request failed:", err.message);
    return res.status(500).json({ error: "Something went wrong. Please try again in a moment." });
  }
  return res.status(200).json({ message: NEUTRAL });
};

function safeParse(s) {
  try { return JSON.parse(s); } catch { return {}; }
}

function mailHtml(link, installUrl) {
  const safe = escapeHtml(link);
  const safeInstall = escapeHtml(installUrl);
  return `<!doctype html><html><body style="margin:0;background:#f4f4f7;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;color:#1b1b4d">
<table width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:32px 16px">
<table width="480" cellpadding="0" cellspacing="0" style="max-width:480px;background:#ffffff;border-radius:16px;padding:32px">
<tr><td>
<h1 style="margin:0 0 8px;font-size:24px">Your Snapper download</h1>
<p style="margin:0 0 24px;font-size:15px;line-height:1.5;color:#555a6e">You are invited. The button below downloads the latest version for macOS.</p>
<p style="margin:0 0 24px"><a href="${safe}" style="display:inline-block;background:#1b1b4d;color:#ffffff;text-decoration:none;font-weight:600;padding:12px 22px;border-radius:10px">Download Snapper</a></p>
<p style="margin:0 0 6px;font-size:13px;line-height:1.5;color:#555a6e">The link works for 7 days. Works on any Mac with an M chip (M1 or newer), on macOS Sonoma or newer.</p>
<p style="margin:0;font-size:13px;line-height:1.5;color:#555a6e">First launch: drag Snapper to Applications, open it, then approve it once under System Settings, Privacy &amp; Security, Open Anyway. <a href="${safeInstall}" style="color:#1b1b4d">Step by step</a>.</p>
</td></tr></table>
<p style="margin:16px 0 0;font-size:12px;color:#8a8fa3">Snapper, built by Bykorp</p>
</td></tr></table></body></html>`;
}
