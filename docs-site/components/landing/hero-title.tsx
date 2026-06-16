"use client";

import { motion } from "framer-motion";
import Link from "next/link";
import { IndependentProjectNotice } from "@/components/independent-project-notice";
import { BRAND_NAME, BRAND_TAGLINE } from "@/lib/branding";
import { GITHUB_REPO_URL } from "@/lib/community-stats";

export function HeroTitle() {
	return (
		<motion.div
			initial={{ opacity: 0, y: 12 }}
			animate={{ opacity: 1, y: 0 }}
			transition={{ duration: 0.5, ease: "easeOut" }}
			className="relative z-[2] w-full py-16 flex flex-col justify-center h-full pointer-events-none"
		>
			<div>
				<h1 className="pt-3 sm:pt-4 text-2xl md:text-3xl xl:text-4xl text-neutral-800 dark:text-neutral-200 tracking-tight leading-tight text-balance">
					{BRAND_NAME}
				</h1>
				<p className="mt-2 text-sm sm:text-base text-neutral-600 dark:text-neutral-400 max-w-xl">
					{BRAND_TAGLINE}
				</p>

				<div className="flex flex-wrap items-center gap-2 sm:gap-3 pt-4 sm:pt-5 pointer-events-auto">
					<Link
						href="/docs/installation"
						className="inline-flex items-center gap-1.5 px-4 sm:px-5 py-2 bg-neutral-900 text-neutral-100 dark:bg-neutral-100 dark:text-neutral-900 text-xs sm:text-sm font-medium hover:opacity-90 transition-colors"
					>
						Get Started
					</Link>
					<Link
						href={GITHUB_REPO_URL}
						target="_blank"
						rel="noopener noreferrer"
						className="inline-flex items-center gap-1.5 px-4 sm:px-5 py-2 border border-neutral-300 dark:border-neutral-700 text-neutral-800 dark:text-neutral-200 text-xs sm:text-sm font-medium hover:bg-neutral-100 dark:hover:bg-neutral-800/50 transition-colors"
					>
						GitHub
					</Link>
				</div>

				<IndependentProjectNotice className="mt-5 sm:mt-6 max-w-xl" />
			</div>
		</motion.div>
	);
}
