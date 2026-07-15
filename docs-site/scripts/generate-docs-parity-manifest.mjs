import {execFileSync} from "node:child_process";
import {readFileSync, readdirSync, statSync, writeFileSync} from "node:fs";
import {dirname, join, relative} from "node:path";
import {fileURLToPath} from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..");
const localDocs = join(root, "docs-site/content/docs");
const versionPath = join(root, "reference/upstream-better-auth/VERSION.md");
const versionMetadata = readFileSync(versionPath, "utf8");
const pinnedVersion = versionMetadata.match(/\| Version \| \x60([^\x60]+)\x60 \|/)?.[1];
const pinnedCommit = versionMetadata.match(/\| Repository commit \| \x60([^\x60]+)\x60 \|/)?.[1];
if (!pinnedVersion || !pinnedCommit) throw new Error("VERSION.md is missing pinned Version or Repository commit metadata");
const generatedFrom = `reference/upstream-src/${pinnedVersion}/repository/docs/content/docs`;
const upstreamRoot = join(root, `reference/upstream-src/${pinnedVersion}/repository`);
const upstreamDocs = join(upstreamRoot, "docs/content/docs");
const scopePath = join(here, "docs-parity-scope.json");
const manifestPath = join(here, "docs-parity-manifest.json");
const actions = new Set(["port", "keep_local", "merge_local", "merge_into_other_relational", "skip_client", "skip_unported", "skip_upstream_product", "skip_version", "skip_external", "remove_if_local"]);
const exclusionActions = new Set(["merge_into_other_relational", "remove_if_local", "skip_client", "skip_unported", "skip_upstream_product", "skip_version", "skip_external"]);
const supportedActions = new Set(["port", "keep_local", "merge_local"]);

function walkMdx(directory) {
  const files = new Map();
  const visit = (current) => readdirSync(current).forEach((name) => {
    const path = join(current, name);
    if (statSync(path).isDirectory()) visit(path);
    else if (name.endsWith(".mdx")) files.set(relative(directory, path), path);
  });
  visit(directory);
  return files;
}

function lines(path) {
  return readFileSync(path, "utf8").split("\n").length - 1;
}

function statusFor(page, local, upstream, localLines, upstreamLines) {
  if (page.action === "remove_if_local") return local ? "unsupported_local_present" : "unsupported_absent";
  if (page.action.startsWith("skip_") || page.action === "merge_into_other_relational") return "excluded";
  if (page.action === "keep_local") return "keep_local";
  if (!local) return "missing";
  if (!upstream) return "local_only";
  return localLines < upstreamLines ? "thin" : "needs_manual_review";
}

export function validateScope(scope, {localFiles, upstreamFiles, rootPath = root} = {}) {
  if (!scope || !Array.isArray(scope.pages)) throw new Error("Scope must contain a pages array");
  const local = localFiles ?? walkMdx(localDocs);
  const upstream = upstreamFiles ?? walkMdx(upstreamDocs);
  const union = new Set([...local.keys(), ...upstream.keys()]);
  const seen = new Set();
  const scoped = new Set();
  for (const page of scope.pages) {
    if (!page || typeof page.slug !== "string" || !page.slug.endsWith(".mdx")) throw new Error("Each scope page must have an MDX slug");
    if (seen.has(page.slug)) throw new Error("Duplicate scope slug: " + page.slug);
    seen.add(page.slug);
    scoped.add(page.slug);
    if (!actions.has(page.action)) throw new Error("Invalid action for " + page.slug + ": " + page.action);
    if (typeof page.supported !== "boolean") throw new Error("supported must be boolean for " + page.slug);
    if (exclusionActions.has(page.action) && page.supported !== false) throw new Error("Exclusion action must be supported:false for " + page.slug);
    if (supportedActions.has(page.action) && page.supported !== true) throw new Error("Supported action must be supported:true for " + page.slug);
    if (exclusionActions.has(page.action) && (typeof page.reason !== "string" || page.reason.trim() === "")) throw new Error("A precise reason is required for " + page.slug);
    if (page.action === "remove_if_local" && local.has(page.slug)) throw new Error("remove_if_local cannot classify an existing local page: " + page.slug);
    if (page.reason !== undefined && typeof page.reason !== "string") throw new Error("reason must be a string for " + page.slug);
    if (page.ruby_source !== undefined && (typeof page.ruby_source !== "string" || !statSync(join(rootPath, page.ruby_source), {throwIfNoEntry: false}))) throw new Error("ruby_source does not exist for " + page.slug + ": " + page.ruby_source);
    if (page.action === "merge_into_other_relational") {
      if (page.merge_target === undefined) throw new Error("merge_target is required for " + page.slug);
      if (typeof page.merge_target !== "string" || !page.merge_target.endsWith(".mdx")) throw new Error("Invalid merge_target for " + page.slug);
      if (!union.has(page.merge_target)) throw new Error("merge_target is not a local or upstream MDX page for " + page.slug + ": " + page.merge_target);
    } else if (page.merge_target !== undefined) {
      throw new Error("merge_target is only valid for merge_into_other_relational: " + page.slug);
    }
  }
  if (scope.upstream_tag || scope.upstream_commit) assertPinnedPolicies(scope);
  const unclassified = [...union].filter((slug) => !scoped.has(slug)).sort();
  const orphan = [...scoped].filter((slug) => !union.has(slug)).sort();
  if (unclassified.length || orphan.length) {
    const detail = [unclassified.length && "unclassified: " + unclassified.join(", "), orphan.length && "orphan: " + orphan.join(", ")].filter(Boolean).join("; ");
    throw new Error("Scope must exactly match local/upstream MDX union (" + detail + ")");
  }
}

function assertPinnedPolicies(scope) {
  const required = {
    "guides/1-7-upgrade-guide.mdx": ["skip_version", false, "future-version/out-of-target"],
    "plugins/commet.mdx": ["skip_external", false, "external non-Stripe payment plugin"]
  };
  for (const [slug, [action, supported, reason]] of Object.entries(required)) {
    const page = scope.pages.find((entry) => entry.slug === slug);
    if (!page || page.action !== action || page.supported !== supported || page.reason !== reason) {
      throw new Error("Pinned policy mismatch for " + slug);
    }
  }
}

export function buildManifest({scope, localFiles, upstreamFiles} = {}) {
  const local = localFiles ?? walkMdx(localDocs);
  const upstream = upstreamFiles ?? walkMdx(upstreamDocs);
  validateScope(scope, {localFiles: local, upstreamFiles: upstream});
  return {
    upstream_tag: scope.upstream_tag,
    upstream_commit: scope.upstream_commit,
    generated_from: generatedFrom,
    pages: [...scope.pages].sort((a, b) => a.slug.localeCompare(b.slug)).map((page) => {
      const localPath = local.get(page.slug);
      const upstreamPath = upstream.get(page.slug);
      const current_local_lines = localPath ? lines(localPath) : 0;
      const upstream_lines = upstreamPath ? lines(upstreamPath) : 0;
      return {...page, local_exists: Boolean(localPath), upstream_exists: Boolean(upstreamPath), current_local_lines, upstream_lines, status: statusFor(page, Boolean(localPath), Boolean(upstreamPath), current_local_lines, upstream_lines)};
    })
  };
}

function verifyPin(scope) {
  if (scope.upstream_tag !== "v" + pinnedVersion || scope.upstream_commit !== pinnedCommit) throw new Error("Scope pin must match VERSION.md (expected v" + pinnedVersion + " / " + pinnedCommit + ")");
  const head = execFileSync("git", ["-C", upstreamRoot, "rev-parse", "HEAD"], {encoding: "utf8"}).trim();
  if (head !== pinnedCommit) throw new Error("Upstream git HEAD mismatch: expected " + pinnedCommit + ", got " + head);
}

export function selfTest() {
  const scope = JSON.parse(readFileSync(scopePath, "utf8"));
  verifyPin(scope);
  validateScope(scope);
}

function main(args) {
  if (args[0] === "--self-test") return selfTest();
  if (!["--write", "--check"].includes(args[0])) throw new Error("Usage: generate-docs-parity-manifest.mjs --write|--check|--self-test");
  const scope = JSON.parse(readFileSync(scopePath, "utf8"));
  verifyPin(scope);
  const output = JSON.stringify(buildManifest({scope}), null, 2) + "\n";
  if (args[0] === "--write") writeFileSync(manifestPath, output);
  else if (readFileSync(manifestPath, "utf8") !== output) throw new Error("docs-parity-manifest.json is stale; run docs:parity-generate");
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try { main(process.argv.slice(2)); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
