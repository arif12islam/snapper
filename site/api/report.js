// POST /api/report  Anonymous crash and error reports from Snapper (opt-in in the app's Settings).
// Each report is written to the function log (Vercel: Project, Logs) and, when REPORTS_EMAIL or OWNER_EMAIL is
// set, emailed there through Resend.
const { sendMail, escapeHtml } = require("./_lib");

const MAX_BYTES = 32 * 1024;
const FIELDS = ["id", "kind", "time", "app", "macOS", "model", "arch", "summary", "details"];

module.exports = async (req, res) => {
  res.setHeader("Cache-Control", "no-store");
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json({ error: "Method not allowed" });
  }

  const raw = typeof req.body === "string" ? req.body : JSON.stringify(req.body || {});
  if (Buffer.byteLength(raw) > MAX_BYTES) return res.status(413).json({ error: "Report too large" });
  const body = typeof req.body === "string" ? safeParse(req.body) : req.body || {};

  // Keep only the known fields, as short strings.
  const report = {};
  for (const key of FIELDS) {
    if (body[key] !== undefined) report[key] = String(body[key]).slice(0, key === "details" ? 16000 : 300);
  }
  if (!["crash", "error"].includes(report.kind) || !report.summary) {
    return res.status(400).json({ error: "Not a Snapper report" });
  }

  console.log("snapper-report", JSON.stringify(report));

  const to = process.env.REPORTS_EMAIL || process.env.OWNER_EMAIL;
  if (to) {
    try {
      const subject = `Snapper ${report.kind} report: ${report.app || "?"}, macOS ${report.macOS || "?"}`;
      const text = FIELDS.filter((k) => report[k]).map((k) => `${k}: ${report[k]}`).join("\n");
      await sendMail({ to, subject, text, html: `<pre>${escapeHtml(text)}</pre>` });
    } catch (err) {
      // The report is in the log already; the app should not retry.
      console.error("report email failed:", err.message);
    }
  }
  return res.status(200).json({ ok: true });
};

function safeParse(s) {
  try { return JSON.parse(s); } catch { return {}; }
}
