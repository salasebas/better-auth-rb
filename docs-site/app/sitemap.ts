import type { MetadataRoute } from "next";
import { changelogs, source } from "@/lib/source";

const BASE_URL = "https://www.better-auth.com";

export default function sitemap(): MetadataRoute.Sitemap {
	const basePages: MetadataRoute.Sitemap = [
		{
			url: BASE_URL,
			lastModified: new Date(),
			changeFrequency: "daily",
			priority: 1.0,
		},
		{
			url: `${BASE_URL}/blog`,
			lastModified: new Date(),
			changeFrequency: "weekly",
			priority: 0.8,
		},
		{
			url: `${BASE_URL}/community`,
			lastModified: new Date(),
			changeFrequency: "weekly",
			priority: 0.8,
		},
		{
			url: `${BASE_URL}/changelogs`,
			lastModified: new Date(),
			changeFrequency: "weekly",
			priority: 0.8,
		},
		// /enterprise is preserved in the app, but hidden from public discovery for now.
	];

	const docPages: MetadataRoute.Sitemap = source.getPages().map((page) => ({
		url: `${BASE_URL}${page.url}`,
		lastModified: page.data.lastModified
			? new Date(page.data.lastModified)
			: new Date(),
		changeFrequency: "weekly",
		priority: 0.7,
	}));

	// Blog articles are preserved in docs/content/blogs, but hidden while Ruby-specific content is planned.

	const changelogPages: MetadataRoute.Sitemap = changelogs
		.getPages()
		.map((page) => ({
			url: `${BASE_URL}${page.url}`,
			lastModified: page.data.date ? new Date(page.data.date) : new Date(),
			changeFrequency: "monthly",
			priority: 0.6,
		}));

	return [
		...basePages,
		...docPages,
		...changelogPages,
	];
}
