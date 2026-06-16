import {
	defineCollections,
	defineConfig,
	defineDocs,
} from "fumadocs-mdx/config";
import lastModified from "fumadocs-mdx/plugins/last-modified";
import * as z from "zod";

export const docs = defineDocs({
	dir: "./content/docs",
	docs: {
		postprocess: {
			includeProcessedMarkdown: true,
		},
		async: true,
	},
});

export const blogCollection = defineCollections({
	type: "doc",
	dir: "./content/blogs",
	schema: z.object({
		title: z.string(),
		description: z.string(),
		date: z.date(),
		draft: z.boolean().optional(),
		author: z
			.object({
				name: z.string(),
				avatar: z.string(),
				twitter: z.string().optional(),
			})
			.optional(),
		image: z.string().optional(),
		tags: z.array(z.string()).optional(),
	}),
	postprocess: {
		includeProcessedMarkdown: true,
	},
});

export default defineConfig({
	mdxOptions: {
		remarkNpmOptions: {
			persist: {
				id: "persist-install",
			},
		},
	},
	plugins: [lastModified()],
});
