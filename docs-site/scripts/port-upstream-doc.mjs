#!/usr/bin/env node
/**
 * Usage: node docs-site/scripts/port-upstream-doc.mjs plugins/2fa.mdx
 * Copies pinned upstream MDX, applies mechanical transforms, writes to content/docs/.
 * Does NOT auto-generate Ruby examples - executor must edit code blocks after.
 */

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptPath = fileURLToPath(import.meta.url);
const scriptDir = path.dirname(scriptPath);
const repoRoot = path.resolve(scriptDir, "../..");
const versionFile = path.join(
	repoRoot,
	"reference/upstream-better-auth/VERSION.md",
);
const versionMatch = readFileSync(versionFile, "utf8").match(
	/^\| Version \| `([0-9]+\.[0-9]+\.[0-9]+)` \|$/m,
);
if (!versionMatch) {
	throw new Error(`Could not read pinned upstream version from ${versionFile}`);
}
const upstreamVersion = versionMatch[1];
const upstreamRoot = path.join(
	repoRoot,
	`reference/upstream-src/${upstreamVersion}/repository/docs/content/docs`,
);
const localRoot = path.join(repoRoot, "docs-site/content/docs");
const manifestPath = path.join(
	repoRoot,
	"docs-site/scripts/docs-parity-manifest.json",
);

const blockedActions = new Set([
	"keep_local",
	"skip_client",
	"skip_upstream_product",
	"skip_unported",
	"skip_version",
	"skip_external",
	"remove_if_local",
	"merge_into_other_relational",
]);

const slug = process.argv[2];

if (!slug || slug.startsWith("-") || process.argv.length > 3) {
	console.error(
		"Usage: node docs-site/scripts/port-upstream-doc.mjs <docs-slug.mdx>",
	);
	process.exit(1);
}

if (slug.includes("..") || path.isAbsolute(slug) || !slug.endsWith(".mdx")) {
	console.error(`Invalid docs slug: ${slug}`);
	process.exit(1);
}

const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
const page = manifest.pages.find((entry) => entry.slug === slug);

if (!page) {
	console.error(`No manifest entry for ${slug}`);
	process.exit(1);
}

if (blockedActions.has(page.action)) {
	console.error(
		`Refusing to port ${slug}: manifest action is ${page.action}.`,
	);
	process.exit(1);
}

const upstreamPath = path.join(upstreamRoot, slug);
const targetPath = path.join(localRoot, slug);

if (!existsSync(upstreamPath)) {
	console.error(`Missing upstream source: ${upstreamPath}`);
	process.exit(1);
}

const source = readFileSync(upstreamPath, "utf8");
const output = applyTransforms(source);

mkdirSync(path.dirname(targetPath), { recursive: true });
writeFileSync(targetPath, output);

let diffStat = "";
try {
	diffStat = execFileSync(
		"git",
		["diff", "--stat", "--", path.relative(repoRoot, targetPath)],
		{ cwd: repoRoot, encoding: "utf8" },
	);
} catch (error) {
	diffStat = error.stdout?.toString() ?? "";
}

if (diffStat.trim()) {
	console.log(diffStat.trimEnd());
} else {
	console.log(`${path.relative(repoRoot, targetPath)} unchanged`);
}
console.log(
	"Replace TypeScript/JavaScript examples with Ruby or HTTP examples before committing.",
);

function applyTransforms(markdown) {
	let text = markdown;

	text = text.replace(/\[!code[^\]]*\]/g, "");
	text = text.replace(/import \{ betterAuth \} from "better-auth";?/g, 'require "better_auth"');
	text = text.replace(/import \{ admin \} from "better-auth\/plugins";?/g, "BetterAuth::Plugins.admin");
	text = text.replace(/\bbetterAuth\(\{/g, "BetterAuth.auth(");
	text = text.replace(/\badmin\(\)/g, "BetterAuth::Plugins.admin");
	text = text.replace(/\btwoFactor\(\)/g, "BetterAuth::Plugins.two_factor(...)");
	text = text.replace(
		/\bnpx auth(?:@latest)? migrate\b/g,
		"bundle exec better-auth migrate --cwd . --config config/better_auth.rb --yes",
	);
	text = text.replace(
		/\bnpx auth(?:@latest)? generate\b/g,
		"bundle exec better-auth generate --cwd . --dialect postgres --output db/better_auth/schema.sql --config config/better_auth.rb",
	);
	text = text.replace(/\bnpm install better-auth\b/g, 'gem "better_auth"\n\nbundle install');
	text = text.replace(/\bprocess\.env\.BETTER_AUTH_SECRET\b/g, 'ENV.fetch("BETTER_AUTH_SECRET")');
	text = text.replace(/\bauth\.api\.signInEmail\b/g, "auth.api.sign_in_email");
	text = text.replace(/\bsupported via Kysely adapter\b/g, "supported via RubyAuth SQL adapters");
	text = text.replace(/\bBetter Auth\b/g, "RubyAuth");

	const strippedLines = text
		.split(/\r?\n/)
		.filter((line) => !isClientPluginLine(line));

	return strippedLines.join("\n");
}

function isClientPluginLine(line) {
	return [
		/createAuthClient/,
		/auth-client\.ts/,
		/\/client\/plugins/,
		/better-auth\/client/,
		/\bauthClient\b/,
		/\w+Client\(\)/,
	].some((pattern) => pattern.test(line));
}
