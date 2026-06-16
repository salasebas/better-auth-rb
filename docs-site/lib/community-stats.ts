import { unstable_cache } from "next/cache";
import staticContributors from "./contributors-data.json";

export const GITHUB_REPO_URL = "https://github.com/salasebas/better-auth-rb";
export const RUBYGEMS_GEM_URL = "https://rubygems.org/gems/better_auth";

export interface CommunityStats {
	rubygemsDownloads: number;
	githubStars: number;
	contributors: number;
}

export interface ContributorInfo {
	login: string;
	avatar_url: string;
	html_url: string;
}

export function getContributors(): ContributorInfo[] {
	return staticContributors as ContributorInfo[];
}

const staticContributorsCount = staticContributors.length;

async function fetchRubygemsDownloads(): Promise<number> {
	try {
		const response = await fetch(
			"https://rubygems.org/api/v1/gems/better_auth.json",
			{ next: { revalidate: 3600 } },
		);

		if (!response.ok) {
			console.error("Failed to fetch RubyGems downloads:", response.status);
			return 0;
		}

		const data = await response.json();
		return data.downloads || 0;
	} catch (error) {
		console.error("Error fetching RubyGems downloads:", error);
		return 0;
	}
}

const githubHeaders = {
	Accept: "application/vnd.github.v3+json",
	...(process.env.GITHUB_TOKEN && {
		Authorization: `Bearer ${process.env.GITHUB_TOKEN}`,
	}),
};

async function fetchGitHubStats(): Promise<{
	stars: number;
	contributors: number;
}> {
	try {
		const [repoResponse, contributorsResponse] = await Promise.all([
			fetch("https://api.github.com/repos/salasebas/better-auth-rb", {
				next: { revalidate: 3600 },
				headers: githubHeaders,
			}),
			fetch(
				"https://api.github.com/repos/salasebas/better-auth-rb/contributors?per_page=1&anon=true",
				{
					next: { revalidate: 3600 },
					headers: githubHeaders,
				},
			),
		]);

		let stars = 0;
		if (repoResponse.ok) {
			const data = await repoResponse.json();
			stars = data.stargazers_count || 0;
		} else {
			console.error("Failed to fetch GitHub repo stats:", repoResponse.status);
		}

		let contributorsCount = staticContributorsCount;
		if (contributorsResponse.ok) {
			const linkHeader = contributorsResponse.headers.get("Link");
			if (linkHeader) {
				const match = linkHeader.match(/page=(\d+)>; rel="last"/);
				if (match) {
					contributorsCount = parseInt(match[1], 10);
				}
			}
		} else {
			console.error(
				"Failed to fetch contributors:",
				contributorsResponse.status,
			);
		}

		return { stars, contributors: contributorsCount };
	} catch (error) {
		console.error("Error fetching GitHub stats:", error);
		return { stars: 0, contributors: staticContributorsCount };
	}
}

export const getCommunityStats = unstable_cache(
	async (): Promise<CommunityStats> => {
		const [rubygemsDownloads, githubStats] = await Promise.all([
			fetchRubygemsDownloads(),
			fetchGitHubStats(),
		]);

		return {
			rubygemsDownloads,
			githubStars: githubStats.stars,
			contributors: githubStats.contributors,
		};
	},
	["community-stats"],
	{
		revalidate: 3600,
		tags: ["community-stats"],
	},
);
