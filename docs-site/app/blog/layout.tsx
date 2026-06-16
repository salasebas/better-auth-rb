import { RootProvider } from "fumadocs-ui/provider/next";
import type { Metadata } from "next";
import { BRAND_NAME } from "@/lib/branding";
import { baseUrl, createMetadata } from "@/lib/metadata";

const description = `Latest updates, articles, and insights about ${BRAND_NAME}`;

export const metadata: Metadata = createMetadata({
	title: "Blog",
	description,
	openGraph: {
		url: "/blog",
		title: `Blog - ${BRAND_NAME}`,
		description,
		images: [`/api/og-release?heading=${encodeURIComponent(`${BRAND_NAME} Blog`)}`],
	},
	twitter: {
		images: [`/api/og-release?heading=${encodeURIComponent(`${BRAND_NAME} Blog`)}`],
		title: `Blog - ${BRAND_NAME}`,
		description,
	},
	alternates: {
		types: {
			"application/rss+xml": [
				{
					title: `${BRAND_NAME} Blog`,
					url: `${baseUrl.origin}/blog/rss.xml`,
				},
			],
		},
	},
});

export default function BlogLayout({
	children,
}: {
	children: React.ReactNode;
}) {
	return (
		<RootProvider>
			<div className="relative flex min-h-screen flex-col">
				<main className="flex-1">{children}</main>
			</div>
		</RootProvider>
	);
}
