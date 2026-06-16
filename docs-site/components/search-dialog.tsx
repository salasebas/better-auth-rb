"use client";

import { useDocsSearch } from "fumadocs-core/search/client";
import type {
	SearchItemType,
	SharedProps,
} from "fumadocs-ui/components/dialog/search";
import {
	SearchDialog,
	SearchDialogClose,
	SearchDialogContent,
	SearchDialogHeader,
	SearchDialogIcon,
	SearchDialogInput,
	SearchDialogList,
	SearchDialogListItem,
	SearchDialogOverlay,
} from "fumadocs-ui/components/dialog/search";
import { ArrowRight } from "lucide-react";
import { useRouter } from "next/navigation";
import { useMemo } from "react";
import { usePages } from "@/app/docs/provider";

export default function CustomSearchDialog(props: SharedProps) {
	const { search, setSearch, query } = useDocsSearch({
		type: "fetch",
	});
	const pages = usePages();
	const router = useRouter();

	const pageTreeAction = useMemo<SearchItemType | undefined>(() => {
		if (search.length === 0) return;

		const normalized = search.toLowerCase();
		for (const page of pages) {
			if (!page.name.toLowerCase().includes(normalized)) continue;

			return {
				id: "quick-action",
				type: "action",
				node: (
					<div className="inline-flex items-center gap-2 text-fd-muted-foreground">
						<ArrowRight className="size-4" />
						<p>
							Jump to{" "}
							<span className="font-medium text-fd-foreground">
								{page.name}
							</span>
						</p>
					</div>
				),
				onSelect: () => router.push(page.url),
			};
		}
	}, [router, search, pages]);

	return (
		<SearchDialog
			search={search}
			onSearchChange={setSearch}
			isLoading={query.isLoading}
			{...props}
		>
			<SearchDialogOverlay className="z-200" />
			<SearchDialogContent className="z-200 mt-12 md:mt-0">
				<SearchDialogHeader>
					<SearchDialogIcon />
					<SearchDialogInput />
					<SearchDialogClose className="hidden md:block" />
				</SearchDialogHeader>
				<SearchDialogList
					items={
						query.data !== "empty" || pageTreeAction
							? [
									...(pageTreeAction ? [pageTreeAction] : []),
									...(Array.isArray(query.data) ? query.data : []),
								]
							: null
					}
					Item={({ item, onClick }) => (
						<SearchDialogListItem
							item={item}
							onClick={onClick}
							className={
								item.type !== "action"
									? "max-h-24 [&>div:last-child]:line-clamp-2"
									: undefined
							}
						/>
					)}
				/>
			</SearchDialogContent>
		</SearchDialog>
	);
}
