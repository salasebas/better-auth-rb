import { NextResponse } from "next/server";
import {
	BRAND_DESCRIPTION,
	BRAND_NAME,
	BRAND_TAGLINE,
} from "@/lib/branding";
import { source } from "../../lib/source";

export const revalidate = false;

const SKIP_CATEGORIES = new Set(["infrastructure", "ai-resources", "openapi"]);

interface PageInfo {
	title: string;
	description: string;
	url: string;
	category: string;
}

function groupPagesByCategory(pages: any[]): Map<string, PageInfo[]> {
	const grouped = new Map<string, PageInfo[]>();

	for (const page of pages) {
		const category = page.slugs[0] || "general";
		if (SKIP_CATEGORIES.has(category)) continue;

		const pageInfo: PageInfo = {
			title: page.data.title,
			description: page.data.description || "",
			url: `/llms.txt${page.url}.md`,
			category: category,
		};

		if (!grouped.has(category)) {
			grouped.set(category, []);
		}
		grouped.get(category)!.push(pageInfo);
	}

	return grouped;
}

function formatCategoryName(category: string): string {
	return category
		.split("-")
		.map((word) => word.charAt(0).toUpperCase() + word.slice(1))
		.join(" ");
}

export async function GET() {
	const pages = source.getPages();
	const groupedPages = groupPagesByCategory(pages);
	const siteUrl = process.env.NEXT_PUBLIC_URL ?? "http://localhost:3000";

	let content = `# ${BRAND_NAME}

> ${BRAND_TAGLINE}. ${BRAND_DESCRIPTION}. Server-side Ruby library — not affiliated with Better Auth Inc.

## Documentation index

Full URL: ${siteUrl}/llms.txt

## Table of Contents

`;

	const sortedCategories = Array.from(groupedPages.keys()).sort();

	for (const category of sortedCategories) {
		const categoryPages = groupedPages.get(category)!;
		const formattedCategory = formatCategoryName(category);

		content += `### ${formattedCategory}\n\n`;

		for (const page of categoryPages) {
			const description = page.description ? `: ${page.description}` : "";
			content += `- [${page.title}](${page.url})${description}\n`;
		}

		content += "\n";
	}

	return new NextResponse(content, {
		headers: {
			"Content-Type": "text/markdown",
		},
	});
}
