import { createMDX } from "fumadocs-mdx/next";

/** @type {import('next').NextConfig} */
const nextConfig = {
	experimental: {
		optimizePackageImports: [
			"lucide-react",
			"framer-motion",
			"@radix-ui/react-tabs",
			"@radix-ui/react-scroll-area",
			"@radix-ui/react-popover",
			"@radix-ui/react-select",
			"@radix-ui/react-checkbox",
		],
	},
	images: {
		remotePatterns: [
			{
				protocol: "https",
				hostname: "**",
			},
			{
				protocol: "http",
				hostname: "**",
			},
		],
	},
	async redirects() {
		return [
			{
				source: "/docs",
				destination: "/docs/introduction",
				permanent: false,
			},
			{
				source: "/pricing",
				destination: "/",
				permanent: false,
			},
			{
				source: "/enterprise",
				destination: "/",
				permanent: false,
			},
			{
				source: "/products/:path*",
				destination: "/docs/introduction",
				permanent: false,
			},
			{
				source: "/careers",
				destination: "/",
				permanent: false,
			},
			{
				source: "/dashboard/:path*",
				destination: "/",
				permanent: true,
			},
			{
				source: "/terms",
				destination: "/legal/terms",
				permanent: true,
			},
			{
				source: "/privacy",
				destination: "/legal/privacy",
				permanent: true,
			},
			{
				source: "/docs/agent-tools/ask-ai",
				destination: "/docs/introduction",
				permanent: true,
			},
			{
				source: "/docs/agent-tools/llms-txt",
				destination: "/llms.txt",
				permanent: true,
			},
			{
				source: "/docs/agent-tools/:path*",
				destination: "/docs/introduction",
				permanent: true,
			},
			{
				source: "/docs/ai-resources/:path*",
				destination: "/docs/introduction",
				permanent: false,
			},
		];
	},
};

const withMDX = createMDX({
	contentDirBasePath: "/content/docs",
});
export default withMDX(nextConfig);
