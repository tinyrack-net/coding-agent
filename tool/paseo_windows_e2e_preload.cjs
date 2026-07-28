const childProcess = require("node:child_process");
const { syncBuiltinESMExports } = require("node:module");

if (process.platform === "win32") {
  const originalExecSync = childProcess.execSync;
  const originalSpawn = childProcess.spawn;

  childProcess.execSync = function execSync(command, options) {
    const match = /^which\s+([A-Za-z0-9_.-]+)$/.exec(command);
    if (!match) {
      return originalExecSync.call(this, command, options);
    }

    const output = originalExecSync.call(
      this,
      `where.exe ${match[1]}`,
      options,
    );
    const isBuffer = Buffer.isBuffer(output);
    const text = isBuffer ? output.toString() : String(output);
    const candidates = text
      .split(/\r?\n/)
      .map((entry) => entry.trim())
      .filter(Boolean);
    const executable =
      candidates.find((entry) => /\.(?:exe|cmd|bat|com)$/i.test(entry)) ??
      candidates[0];
    if (!executable) {
      return output;
    }
    const normalized = `${executable}\n`;
    return isBuffer ? Buffer.from(normalized) : normalized;
  };

  childProcess.spawn = function spawn(command, args, options) {
    const resolvedCommand =
      command.toLowerCase() === "npx" ? "npx.cmd" : command;
    if (/\.(?:cmd|bat)$/i.test(resolvedCommand)) {
      return originalSpawn.call(this, resolvedCommand, args, {
        ...options,
        shell: true,
      });
    }
    return originalSpawn.call(this, resolvedCommand, args, options);
  };

  syncBuiltinESMExports();
}
