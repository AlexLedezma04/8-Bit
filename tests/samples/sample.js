#!/usr/bin/env node
// A module.
import fs from "fs";

export async function read(path) {
  const text = await fs.promises.readFile(path, 'utf8');
  return `size: ${text.length}`; /* done */
}

console.log(read("a.txt"), null, undefined);
