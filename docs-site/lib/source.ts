import { loader } from "fumadocs-core/source";
import { toFumadocsSource } from "fumadocs-mdx/runtime/server";
import { blogCollection, docs } from "@/.source/server";

export const source = loader({
	baseUrl: "/docs",
	source: docs.toFumadocsSource(),
});

/**
 * Pick the docs source loader for a given version slug.
 */
export function getSourceFor(_versionSlug: string | null) {
	return source;
}

export const blogs = loader({
	baseUrl: "/blog",
	source: toFumadocsSource(blogCollection, []),
});
