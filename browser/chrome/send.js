const q = new URLSearchParams(location.search);
const link = q.get("link");
document.getElementById("what").textContent = q.get("u") || "Open RefWare";
document.getElementById("go").addEventListener("click", () => {
  if (link && link.startsWith("refware://")) location.href = link;   // a real click, which Chrome requires
  setTimeout(() => window.close(), 1500);
});
