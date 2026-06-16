export const BRAND_NAME = "RubyAuth";
export const BRAND_TAGLINE = "Authentication framework for Ruby";
export const BRAND_DESCRIPTION =
	"The most comprehensive authentication framework for Ruby";

export const INDEPENDENCE_NOTICE = `${BRAND_NAME} is an independent project, not affiliated with Better Auth. This documentation was adapted from the Better Auth docs (MIT license) to describe ${BRAND_NAME} behavior and APIs.`;

/** LLM docs index URL for hero prompts and tooling. */
export function getLlmsTxtUrl(): string {
	return (
		process.env.NEXT_PUBLIC_LLMS_TXT_URL ??
		`${process.env.NEXT_PUBLIC_URL ?? "http://localhost:3000"}/llms.txt`
	);
}

export const BRAND_ASSETS = {
	markLight: "/branding/rubyauth-mark-light.svg",
	markDark: "/branding/rubyauth-mark-dark.svg",
	wordmarkLight: "/branding/rubyauth-wordmark-light.svg",
	wordmarkDark: "/branding/rubyauth-wordmark-dark.svg",
	brandZip: "/branding/rubyauth-brand-assets.zip",
} as const;

const gemMark = (fill: string, highlight: string, shadow: string) => `
<polygon points="32 4 58 22 58 46 32 60 6 46 6 22" fill="${fill}"/>
<polygon points="32 4 58 22 32 34 6 22" fill="${highlight}"/>
<polygon points="32 34 58 46 32 60 6 46" fill="${shadow}"/>`;

export const logoMarkSvg = {
	light: `<svg width="64" height="64" viewBox="0 0 64 64" fill="none" xmlns="http://www.w3.org/2000/svg">${gemMark("#e9573f", "rgba(255,255,255,0.22)", "rgba(20,28,34,0.18)")}</svg>`,
	dark: `<svg width="64" height="64" viewBox="0 0 64 64" fill="none" xmlns="http://www.w3.org/2000/svg">${gemMark("#e9573f", "rgba(255,255,255,0.22)", "rgba(20,28,34,0.18)")}</svg>`,
};

export const logoWordmarkSvg = {
	light: `<svg width="320" height="64" viewBox="0 0 320 64" fill="none" xmlns="http://www.w3.org/2000/svg">
<g transform="translate(0 0)">${gemMark("#e9573f", "rgba(255,255,255,0.22)", "rgba(20,28,34,0.18)")}</g>
<text x="76" y="42" fill="#141c22" font-family="ui-sans-serif, system-ui, sans-serif" font-size="28" font-weight="600" letter-spacing="-0.02em">RubyAuth</text>
</svg>`,
	dark: `<svg width="320" height="64" viewBox="0 0 320 64" fill="none" xmlns="http://www.w3.org/2000/svg">
<g transform="translate(0 0)">${gemMark("#e9573f", "rgba(255,255,255,0.22)", "rgba(20,28,34,0.18)")}</g>
<text x="76" y="42" fill="#f5f5f5" font-family="ui-sans-serif, system-ui, sans-serif" font-size="28" font-weight="600" letter-spacing="-0.02em">RubyAuth</text>
</svg>`,
};
