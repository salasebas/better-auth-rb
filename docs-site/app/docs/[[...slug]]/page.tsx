import { Accordion, Accordions } from "fumadocs-ui/components/accordion";
import { File, Files, Folder } from "fumadocs-ui/components/files";
import { Step, Steps } from "fumadocs-ui/components/steps";
import { Tab, Tabs } from "fumadocs-ui/components/tabs";
import { TypeTable } from "fumadocs-ui/components/type-table";
import defaultMdxComponents from "fumadocs-ui/mdx";
import {
	DocsBody,
	DocsDescription,
	DocsPage,
	DocsTitle,
} from "fumadocs-ui/page";
import Link from "next/link";
import { notFound } from "next/navigation";
import { APIMethod } from "@/components/api-method";
import { Features } from "@/components/docs/features";
import {
	DatabaseTable,
	DividerText,
	Endpoint,
	ForkButton,
	GenerateAppleJwt,
	GenerateSecret,
	RubyAuthDisclaimer,
	UnderDevelopment,
} from "@/components/docs/mdx-components";
import { Callout } from "@/components/ui/callout";
import {
	docsVersions,
	resolveVersionFromSlug,
	scopeDocsHref,
} from "@/lib/docs-versions";
import { createMetadata } from "@/lib/metadata";
import { getSourceFor } from "@/lib/source";
import { cn } from "@/lib/utils";
import { LLMCopyButton, ViewOptions } from "./page.client";

export default async function Page({
	params,
}: {
	params: Promise<{ slug?: string[] }>;
}) {
	const { slug } = await params;
	const { version, relSlug } = resolveVersionFromSlug(slug ?? []);
	const src = getSourceFor(version.slug);
	const page = src.getPage(relSlug);

	if (!page) {
		return notFound();
	}

	const { body: MDX, toc } = await page.data.load();

	const GITHUB_OWNER = "salasebas";
	const GITHUB_REPO = "better-auth-rb";
	const githubBase = `https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/blob/${version.branch}/docs-site/content/docs`;

	// Keep every absolute /docs link scoped to the version being viewed.
	const scope = (href: string | undefined) => scopeDocsHref(href, version);
	const DefaultAnchor = defaultMdxComponents.a;

	return (
		<DocsPage
			toc={toc}
			full={false}
			tableOfContent={{
				style: "clerk",
			}}
			breadcrumb={{ enabled: false }}
			editOnGithub={{
				owner: GITHUB_OWNER,
				repo: GITHUB_REPO,
				sha: version.branch,
				path: `docs-site/content/docs/${page.path}`,
			}}
		>
			<div className="flex items-center justify-between gap-4">
				<DocsTitle className="mb-0">{page.data.title}</DocsTitle>
				<div className="flex items-center gap-2 not-prose shrink-0">
					<LLMCopyButton markdownUrl={`/llms.txt${page.url}.md`} />
					<ViewOptions
						markdownUrl={`${page.url}.mdx`}
						githubUrl={`${githubBase}/${page.path}`}
						rawMdUrl={`/llms.txt${page.url}.md`}
					/>
				</div>
			</div>
			{page.data.description && (
				<DocsDescription>{page.data.description}</DocsDescription>
			)}
			<DocsBody>
				<MDX
					components={{
						...defaultMdxComponents,
						Step,
						Steps,
						Tab,
						Tabs,
						Accordion,
						Accordions,
						File,
						Files,
						Folder,
						TypeTable,
						APIMethod,
						DatabaseTable,
						ForkButton,
						Features,
						Endpoint,
						GenerateAppleJwt,
						GenerateSecret,
						RubyAuthDisclaimer,
						UnderDevelopment,
						DividerText,
						Callout: ({
							children,
							type,
							...props
						}: {
							children: React.ReactNode;
							type?: "info" | "warn" | "error" | "success" | "warning";
							[key: string]: any;
						}) => (
							<Callout type={type} {...props}>
								{children}
							</Callout>
						),
						iframe: (props: React.ComponentProps<"iframe">) => (
							<iframe
								title="Embedded content"
								{...props}
								className="w-full h-[500px]"
							/>
						),
						a: (props: React.ComponentProps<"a">) => (
							<DefaultAnchor {...props} href={scope(props.href)} />
						),
						Link: ({
							href,
							className,
							...props
						}: React.ComponentProps<typeof Link>) => (
							<Link
								href={typeof href === "string" ? (scope(href) ?? href) : href}
								className={cn(
									"font-medium underline underline-offset-4",
									className,
								)}
								{...props}
							/>
						),
					}}
				/>
			</DocsBody>
		</DocsPage>
	);
}

export async function generateStaticParams() {
	return docsVersions.flatMap((v) => {
		const src = getSourceFor(v.slug);
		return src.generateParams().map((p) => ({
			slug: v.slug ? [v.slug, ...(p.slug ?? [])] : p.slug,
		}));
	});
}

export async function generateMetadata({
	params,
}: {
	params: Promise<{ slug?: string[] }>;
}) {
	const { slug } = await params;
	const { version, relSlug } = resolveVersionFromSlug(slug ?? []);
	const src = getSourceFor(version.slug);
	const page = src.getPage(relSlug);
	if (!page) return notFound();

	const title = version.slug
		? `${version.label} - ${page.data.title}`
		: page.data.title;

	const ogSearchParams = new URLSearchParams();
	ogSearchParams.set("heading", title);
	ogSearchParams.set("type", "documentation");
	ogSearchParams.set("mode", "dark");

	const ogUrl = `/api/og?${ogSearchParams.toString()}`;

	return createMetadata({
		title,
		description: page.data.description,
		openGraph: {
			title,
			description: page.data.description,
			type: "article",
			images: [
				{
					url: ogUrl,
					width: 1200,
					height: 630,
					alt: title,
				},
			],
		},
		twitter: {
			card: "summary_large_image",
			title,
			description: page.data.description,
			images: [ogUrl],
		},
	});
}
