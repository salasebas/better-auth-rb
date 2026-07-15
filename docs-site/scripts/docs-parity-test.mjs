import {spawnSync} from "node:child_process";
import {readFileSync} from "node:fs";
import {dirname, join} from "node:path";
import {fileURLToPath} from "node:url";
import {buildManifest, validateScope} from "./generate-docs-parity-manifest.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..");
const scopePath = join(here, "docs-parity-scope.json");
const portScript = join(here, "port-upstream-doc.mjs");

function expectFailure(label, callback, pattern) {
  try {
    callback();
  } catch (error) {
    if (pattern.test(String(error))) return;
    throw new Error(label + " failed with unexpected error: " + error.message);
  }
  throw new Error(label + " unexpectedly passed");
}

const fixturePath = join(root, "reference/upstream-better-auth/VERSION.md");
const files = new Map([["fixture.mdx", fixturePath]]);
const page = {slug: "fixture.mdx", action: "port", supported: true};
const fixture = {pages: [page]};

expectFailure("unknown local slug", () => validateScope(fixture, {localFiles: new Map([...files, ["unknown.mdx", fixturePath]]), upstreamFiles: files}), /unclassified: unknown\.mdx/);
expectFailure("bad action", () => validateScope({pages: [{...page, action: "nope"}]}, {localFiles: files, upstreamFiles: files}), /Invalid action/);
expectFailure("bad support", () => validateScope({pages: [{...page, supported: false}]}, {localFiles: files, upstreamFiles: files}), /Supported action/);
expectFailure("missing exclusion reason", () => validateScope({pages: [{...page, action: "skip_client", supported: false}]}, {localFiles: files, upstreamFiles: files}), /precise reason/);
expectFailure("remove existing local page", () => validateScope({pages: [{...page, action: "remove_if_local", supported: false, reason: "unsupported"}]}, {localFiles: files, upstreamFiles: files}), /remove_if_local cannot classify an existing local page/);
expectFailure("missing merge target", () => validateScope({pages: [{...page, action: "merge_into_other_relational", supported: false, reason: "merged"}]}, {localFiles: files, upstreamFiles: files}), /merge_target is required/);
expectFailure("unexpected merge target", () => validateScope({pages: [{...page, merge_target: "fixture.mdx"}]}, {localFiles: files, upstreamFiles: files}), /only valid/);

const scope = JSON.parse(readFileSync(scopePath, "utf8"));
validateScope(scope);
buildManifest({scope});
const testUtils = scope.pages.find((page) => page.slug === "plugins/test-utils.mdx");
if (testUtils?.action !== "skip_unported" || testUtils.supported !== false || !/under-development placeholder.*unsupported/.test(testUtils.reason)) {
  throw new Error("plugins/test-utils.mdx must remain an explicit unsupported placeholder");
}
for (const slug of ["guides/1-7-upgrade-guide.mdx", "plugins/commet.mdx"]) {
  const result = spawnSync(process.execPath, [portScript, slug], {cwd: root, encoding: "utf8"});
  if (result.status === 0 || !/Refusing to port/.test(result.stderr)) throw new Error("port-upstream-doc did not refuse " + slug);
}
