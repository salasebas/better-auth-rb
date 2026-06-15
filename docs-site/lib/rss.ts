import { Feed } from "feed";
import { SHOW_UPSTREAM_BLOG_CONTENT } from "./constants";
import { blogs } from "./source";
import { baseUrl } from "./utils";

export function getRSS() {
	const feed = new Feed({
		title: "Better Auth Blog",
		description: "Latest updates, articles, and insights about Better Auth",
		generator: "better-auth",
		id: `${baseUrl}blog`,
		link: `${baseUrl}blog`,
		language: "en",
		image: `${baseUrl}release-og/blogs.png`,
		favicon: `${baseUrl}favicon/favicon-32x32.png`,
		copyright: `All rights reserved ${new Date().getFullYear()}, Better Auth Inc.`,
	});

	// Upstream blog entries stay in docs/content/blogs, but RSS should not expose them while hidden.
	const pages = SHOW_UPSTREAM_BLOG_CONTENT ? blogs.getPages() : [];

	for (const page of pages) {
		const url = page.url.replace("blogs/", "blog/");

		feed.addItem({
			id: url,
			title: page.data.title,
			description: page.data.description,
			image: page.data.image
				? `${baseUrl}${page.data.image.startsWith("/") ? page.data.image.slice(1) : page.data.image}`
				: undefined,
			link: `${baseUrl}${url.startsWith("/") ? url.slice(1) : url}`,
			date: new Date(page.data.lastModified || page.data.date),
			author: page.data.author
				? [
						{
							name: page.data.author.name,
							avatar: page.data.author.avatar,
							link: page.data.author.twitter,
						},
					]
				: [],
		});
	}

	return feed.rss2();
}
