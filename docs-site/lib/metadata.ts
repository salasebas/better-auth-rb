import type { Metadata } from "next";
import { BRAND_NAME } from "./branding";

export function createMetadata(override: Metadata): Metadata {
	return {
		...override,
		metadataBase: baseUrl,
		openGraph: {
			title: override.title ?? undefined,
			description: override.description ?? undefined,
			url: baseUrl.toString(),
			images: "/api/og",
			siteName: BRAND_NAME,
			...override.openGraph,
		},
		twitter: {
			card: "summary_large_image",
			title: override.title ?? undefined,
			description: override.description ?? undefined,
			images: "/api/og",
			...override.twitter,
		},
		icons: {
			icon: [{ url: "/favicon/favicon.svg", type: "image/svg+xml" }],
			apple: "/favicon/favicon.svg",
		},
	};
}

export const baseUrl =
	process.env.NODE_ENV === "development" ||
	(!process.env.VERCEL_PROJECT_PRODUCTION_URL && !process.env.VERCEL_URL)
		? new URL("http://localhost:3000")
		: new URL(
				`https://${process.env.VERCEL_PROJECT_PRODUCTION_URL || process.env.VERCEL_URL}`,
			);
