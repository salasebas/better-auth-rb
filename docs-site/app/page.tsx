import Link from "next/link";
import Features from "@/components/features";
import Hero from "@/components/landing/hero";
import Section from "@/components/landing/section";
import { GITHUB_REPO } from "@/lib/constants";

async function getGitHubStars() {
	try {
		const response = await fetch(
			GITHUB_REPO.apiUrl,
			{
				next: {
					revalidate: 60,
				},
			},
		);
		if (!response?.ok) {
			return null;
		}
		const json = await response.json();
		const stars = parseInt(json.stargazers_count).toLocaleString();
		return stars;
	} catch {
		return null;
	}
}

export default async function HomePage() {
	const stars = await getGitHubStars();
	return (
		<main className="h-min mx-auto overflow-x-hidden">
			<div className="w-full bg-gradient-to-br from-zinc-50 to-zinc-100 dark:from-zinc-950 dark:via-black dark:to-zinc-950 border-b border-dashed border-zinc-200 dark:border-zinc-800">
				<div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
					<div className="w-full h-full">
						<div className="flex flex-col md:flex-row items-center justify-center min-h-12 gap-1 py-2 text-center md:text-left">
							<span className="font-medium flex flex-col md:flex-row md:items-center gap-1 md:gap-2 text-sm text-zinc-700 dark:text-zinc-300">
								<span className="text-zinc-900 dark:text-white/90 hover:text-zinc-950 text-xs md:text-sm dark:hover:text-zinc-100 transition-colors">
									A modern authentication framework for Ruby, inspired by Better Auth.
								</span>
								<span className="text-zinc-400 hidden md:block">|</span>
								<span className="text-zinc-500 dark:text-zinc-400 text-xs md:text-sm">
									This project is independent and is not affiliated with, maintained by, or endorsed by the Better Auth project.
								</span>
								<span className="text-zinc-400 hidden md:block">|</span>
								<Link
									href={GITHUB_REPO.url}
									className="font-semibold text-blue-600 dark:text-blue-400 hover:text-blue-700 hidden dark:hover:text-blue-300 transition-colors md:block"
								>
									View on GitHub →
								</Link>
							</span>
							<Link
								href={GITHUB_REPO.url}
								className="font-semibold text-blue-600 dark:text-blue-400 hover:text-blue-700 text-xs dark:hover:text-blue-300 transition-colors md:hidden"
							>
								View on GitHub →
							</Link>
						</div>
					</div>
				</div>
			</div>
			<Section
				className="mb-1 overflow-y-clip"
				crosses
				crossesOffset="lg:translate-y-[5.25rem]"
				customPaddings
				id="hero"
			>
				<Hero />
				<Features stars={stars} />
				<hr className="h-px bg-border" />
			</Section>
		</main>
	);
}
