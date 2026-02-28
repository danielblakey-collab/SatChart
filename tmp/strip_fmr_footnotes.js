#!/usr/bin/env node

// Read all stdin
const fs = require("fs");

const input = fs.readFileSync(0, "utf8"); // 0 = stdin

const output = input
  .split(/\r?\n/)
  .map((line) => {
    // Remove any footnote letters immediately after a leading date token.
    // Examples:
    //   "6/15 a  7 15 25 ..."   -> "6/15  7 15 25 ..."
    //   "7/10a,b  14 24 ..."    -> "7/10  14 24 ..."
    //   "  6/11 a,b 24 24 ..."  -> "  6/11 24 24 ..."
    return line.replace(
      /^(\s*\d{1,2}\/\d{1,2})[a-zA-Z., ]*/,
      "$1 "
    );
  })
  .join("\n");

process.stdout.write(output);
