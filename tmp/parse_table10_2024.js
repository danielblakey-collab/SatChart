const fs = require("fs");

function cleanNum(x) { return Number(String(x).replace(/,/g, "")); }
function pad2(n) { return String(n).padStart(2, "0"); }

const inPath = process.argv[2];
if (!inPath) {
  console.error("Usage: node tmp/parse_table10_2024.js tmp/table10_2024.txt");
  process.exit(1);
}

const input = fs.readFileSync(inPath, "utf8");
const lines = input.split("\n").map(l => l.trim()).filter(Boolean);
const data = lines.filter(l => /^\d{1,2}\/\d{1,2}\s/.test(l));

console.log("date,districtKey,driftPermits,dualPermits,driftBoats,flags,notes");

for (const line of data) {
  const parts = line.split(/\s+/);
  const md = parts[0];
  const nums = parts.slice(1);
  if (nums.length < 10) continue;

  const [mStr, dStr] = md.split("/");
  const date = `2024-${pad2(cleanNum(mStr))}-${pad2(cleanNum(dStr))}`;

  const nkTotal = cleanNum(nums[0]), nkDual = cleanNum(nums[1]);
  const egTotal = cleanNum(nums[2]), egDual = cleanNum(nums[3]);
  const ugTotal = cleanNum(nums[4]), ugDual = cleanNum(nums[5]);
  const nuTotal = cleanNum(nums[6]), nuDual = cleanNum(nums[7]);
  const toTotal = cleanNum(nums[8]), toDual = 0;

  const rows = [
    ["naknek-kvichak", nkTotal, nkDual],
    ["egegik", egTotal, egDual],
    ["ugashik", ugTotal, ugDual],
    ["nushagak", nuTotal, nuDual],
    ["togiak", toTotal, toDual],
  ];

  for (const [dk, total, dual] of rows) {
    const boats = total - dual;
    console.log(`${date},${dk},${total},${dual},${boats},,`);
  }
}
