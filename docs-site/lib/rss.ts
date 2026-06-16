import { Feed } from "feed";
import { BRAND_NAME } from "./branding";
import { baseUrl } from "./metadata";
import { blogs } from "./source";

export function getRSS() {
	const feed = new Feed({
		title: `${BRAND_NAME} Blog`,
		description: `Latest updates, articles, and insights about ${BRAND_NAME}`,
		generator: "rubyauth",
		id: `${baseUrl}blog`,
		link: `${baseUrl}blog`,
		language: "en",
		image: `${baseUrl}api/og`,
		favicon: `${baseUrl}favicon/favicon.svg`,
		copyright: `All rights reserved ${new Date().getFullYear()}, ${BRAND_NAME}.`,
	});

	for (const page of blogs.getPages().sort((a, b) => {
		return new Date(b.data.date).getTime() - new Date(a.data.date).getTime();
	})) {
		const url = page.url.replace("blogs/", "blog/");

		feed.addItem({
			id: page.url,
			title: page.data.title,
			description: page.data.description,
			image: page.data.image
				? page.data.image.startsWith("/")
					? `${baseUrl}${page.data.image.slice(1)}`
					: page.data.image
				: undefined,
			link: url.startsWith("/") ? `${baseUrl}${url.slice(1)}` : url,
			date: new Date(page.data.date),
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
