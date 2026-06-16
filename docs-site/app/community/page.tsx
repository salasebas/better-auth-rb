import type { Metadata } from "next";
import { getCommunityStats } from "@/lib/community-stats";
import { BRAND_NAME } from "@/lib/branding";
import { createMetadata } from "@/lib/metadata";
import { CommunityPageClient } from "./community-client";

export const metadata: Metadata = createMetadata({
	title: "Community",
	description:
		`Join the ${BRAND_NAME} community — contributors, GitHub discussions, and ecosystem stats.`,
});

export const revalidate = 21600; // Revalidate every 6 hours

export default async function CommunityPage() {
	const stats = await getCommunityStats();

	return <CommunityPageClient stats={stats} />;
}
