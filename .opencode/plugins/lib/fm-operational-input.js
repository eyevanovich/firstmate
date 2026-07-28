import { spawn } from "node:child_process";
import { lstatSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const adapterRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

function safeEncoder(path) {
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || (stat.mode & 0o111) === 0) {
    throw new Error(`unsafe operational-input encoder: ${path}`);
  }
  return path;
}

function encoderFor(root) {
  const requested = `${root}/bin/fm-operational-input.sh`;
  try {
    return safeEncoder(requested);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
  return safeEncoder(`${adapterRoot}/bin/fm-operational-input.sh`);
}

// Cross-language adapter only. bin/fm-operational-input.sh owns the protocol,
// accepted kinds, marker bytes, and serialization grammar.
export function encodeFirstmateOperationalInput(root, kind, content) {
  return new Promise((resolveResult, reject) => {
    let script;
    try {
      script = encoderFor(root);
    } catch (error) {
      reject(error);
      return;
    }
    const child = spawn(script, ["encode", kind], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0 && stdout) {
        resolveResult(stdout);
        return;
      }
      reject(new Error(stderr.trim() || `operational-input encoder exited ${code ?? "unknown"}`));
    });
    child.stdin.end(content);
  });
}
