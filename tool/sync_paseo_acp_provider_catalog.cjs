const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const vm = require("node:vm");

const expectedCommit = "7250009ab7ee72142a08344b8a0b7a12af666e53";
const upstreamRoot = process.argv[2];
const outputPath = process.argv[3];

if (!upstreamRoot || !outputPath) {
  console.error(
    "Usage: node tool/sync_paseo_acp_provider_catalog.cjs <paseo-root> <output-path>",
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
  "data",
  "acp-provider-catalog.ts",
);
const source = fs.readFileSync(sourcePath, "utf8");
const marker = "const CATALOG_DATA = ";
const start = source.indexOf(marker);
const end = source.indexOf("] as const;", start);
if (start < 0 || end < 0) {
  throw new Error(`Unable to locate CATALOG_DATA in ${sourcePath}`);
}

const arrayLiteral = source.slice(start + marker.length, end + 1);
const entries = vm.runInNewContext(`(${arrayLiteral})`, Object.create(null));
if (!Array.isArray(entries) || entries.length === 0) {
  throw new Error("Paseo ACP provider catalog is empty");
}

const dartString = (value) => JSON.stringify(value).replaceAll("$", "\\$");
const dartValue = (value) => {
  if (value === null) return "null";
  if (typeof value === "string") return dartString(value);
  if (typeof value === "boolean" || typeof value === "number") {
    return String(value);
  }
  if (Array.isArray(value)) {
    return `<String>[${value.map(dartValue).join(", ")}]`;
  }
  if (typeof value === "object") {
    return `<String, Object?>{${Object.entries(value)
      .map(([key, nested]) => `${dartString(key)}: ${dartValue(nested)}`)
      .join(", ")}}`;
  }
  throw new Error(`Unsupported catalog value: ${typeof value}`);
};

const lines = [
  "// GENERATED CODE - DO NOT MODIFY BY HAND.",
  "//",
  "// Vendored from Paseo 0.2.0 packages/app/src/data/acp-provider-catalog.ts.",
  "",
  "import 'acp_provider_catalog.dart';",
  "",
  "const acpProviderCatalog = <AcpProviderCatalogEntry>[",
];
for (const entry of entries) {
  lines.push("  AcpProviderCatalogEntry(");
  lines.push(`    id: ${dartString(entry.id)},`);
  lines.push(`    title: ${dartString(entry.title)},`);
  lines.push(`    description: ${dartString(entry.description)},`);
  lines.push(`    version: ${dartString(entry.version)},`);
  lines.push(`    iconName: ${dartValue(entry.iconId ?? null)},`);
  lines.push(`    installLink: ${dartString(entry.installLink)},`);
  lines.push(`    command: ${dartValue(entry.command)},`);
  if (entry.env) lines.push(`    env: ${dartValue(entry.env)},`);
  if (entry.params) lines.push(`    params: ${dartValue(entry.params)},`);
  lines.push("  ),");
}
lines.push("];", "");

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, lines.join("\n"), "utf8");
console.log(`Wrote ${entries.length} ACP providers to ${outputPath}`);
