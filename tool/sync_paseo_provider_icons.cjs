const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const vm = require("node:vm");

const expectedCommit = "7250009ab7ee72142a08344b8a0b7a12af666e53";
const upstreamRoot = process.argv[2];
const outputPath = process.argv[3];

if (!upstreamRoot || !outputPath) {
  console.error(
    "Usage: node tool/sync_paseo_provider_icons.cjs <paseo-root> <output-path>",
  );
  process.exit(64);
}

const actualCommit = execFileSync(
  "git",
  ["-C", upstreamRoot, "rev-parse", "HEAD"],
  { encoding: "utf8" },
).trim();
if (actualCommit !== expectedCommit) {
  throw new Error(
    `Paseo checkout is ${actualCommit}; expected frozen ${expectedCommit}`,
  );
}

const sourcePath = path.join(
  upstreamRoot,
  "packages",
  "app",
  "src",
  "assets",
  "acp-provider-icons.ts",
);
const source = fs.readFileSync(sourcePath, "utf8");
const marker = "export const ACP_PROVIDER_ICON_SVGS = ";
const start = source.indexOf(marker);
const end = source.lastIndexOf("} as const;");

if (start < 0 || end < 0) {
  throw new Error(`Unable to locate ACP_PROVIDER_ICON_SVGS in ${sourcePath}`);
}

const objectLiteral = source.slice(start + marker.length, end + 1);
const icons = vm.runInNewContext(`(${objectLiteral})`, Object.create(null));
const entries = Object.entries(icons);

if (entries.length === 0) {
  throw new Error("Paseo provider icon catalog is empty");
}

const dartString = (value) => JSON.stringify(value).replaceAll("$", "\\$");
const lines = [
  "// GENERATED CODE - DO NOT MODIFY BY HAND.",
  "//",
  "// Vendored from Paseo 0.2.0 packages/app/src/assets/acp-provider-icons.ts.",
  "",
  "const acpProviderIconSvgs = <String, String>{",
  ...entries.map(
    ([provider, svg]) => `  ${dartString(provider)}: ${dartString(svg)},`,
  ),
  "};",
  "",
];

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, lines.join("\n"), "utf8");
console.log(`Wrote ${entries.length} provider SVGs to ${outputPath}`);
