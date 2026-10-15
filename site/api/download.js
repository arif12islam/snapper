// GET /api/download?token=...  Verifies the emailed link, then sends the browser to the newest .dmg.
const { readToken, latestDmg } = require("./_lib");

module.exports = async (req, res) => {
  res.setHeader("Cache-Control", "no-store");
  const data = readToken(req.query && req.query.token);
  if (!data) {
    res.status(410).setHeader("Content-Type", "text/plain; charset=utf-8");
    return res.send("This link has expired or is not valid. Request a new one from the Snapper page.");
  }
  try {
    const dmg = await latestDmg();
    res.statusCode = 302;
    res.setHeader("Location", dmg.url);
    return res.end();
  } catch (err) {
    console.error("download failed:", err.message);
    res.status(502).setHeader("Content-Type", "text/plain; charset=utf-8");
    return res.send("The download is not available right now. Please try again shortly.");
  }
};
