import { notFound } from "next/navigation";
import type { NextRequest } from "next/server";
import { NextResponse } from "next/server";
import { getLLMText, LLM_TEXT_ERROR } from "../../../lib/llm-text";
import { source } from "../../../lib/source";

export const revalidate = false;

function normalizeSlug(slug: string[]): string[] {
	let normalized = [...slug];

	if (normalized[normalized.length - 1]?.endsWith(".md")) {
		normalized = [
			...normalized.slice(0, -1),
			normalized[normalized.length - 1].replace(/\.md$/, ""),
		];
	}

	if (normalized[0] === "docs") {
		normalized = normalized.slice(1);
	}

	return normalized;
}

export async function GET(
	_req: NextRequest,
	{ params }: { params: Promise<{ slug: string[] }> },
) {
	const slug = normalizeSlug((await params).slug);
	const page = source.getPage(slug);
	if (!page) notFound();

	try {
		const content = await getLLMText(page);
		return new NextResponse(content, {
			status: 200,
			headers: { "Content-Type": "text/markdown" },
		});
	} catch (error) {
		console.error("Error generating LLM text:", error);
		return new NextResponse(LLM_TEXT_ERROR, {
			status: 500,
			headers: { "Content-Type": "text/markdown" },
		});
	}
}

export function generateStaticParams() {
	return source.getPages().map((page) => ({
		slug: ["docs", ...page.slugs.map((segment, index) =>
			index === page.slugs.length - 1 ? `${segment}.md` : segment,
		)],
	}));
}
