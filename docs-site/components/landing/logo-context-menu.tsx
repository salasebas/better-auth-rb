"use client";

import { Code, Type } from "lucide-react";
import { useTheme } from "next-themes";
import type React from "react";
import { useEffect, useRef, useState } from "react";
import { toast } from "sonner";

interface LogoAssets {
	darkSvg: string;
	whiteSvg: string;
	darkWordmark: string;
	whiteWordmark: string;
}

interface ContextMenuProps {
	logo: React.ReactNode;
	logoAssets: LogoAssets;
}

export default function LogoContextMenu({
	logo,
	logoAssets,
}: ContextMenuProps) {
	const [showMenu, setShowMenu] = useState<boolean>(false);
	const menuRef = useRef<HTMLDivElement>(null);
	const logoRef = useRef<HTMLDivElement>(null);
	const { theme } = useTheme();

	const handleContextMenu = (e: React.MouseEvent<HTMLDivElement>) => {
		e.preventDefault();
		e.stopPropagation();
		const rect = logoRef.current?.getBoundingClientRect();
		if (rect) {
			setShowMenu(true);
		}
	};

	const copySvgToClipboard = (
		e: React.MouseEvent,
		svgContent: string,
		type: string,
	) => {
		e.preventDefault();
		e.stopPropagation();
		navigator.clipboard
			.writeText(svgContent)
			.then(() => {
				toast.success("", {
					description: `${type} copied to clipboard`,
				});
			})
			.catch(() => {
				toast.error("", {
					description: `Failed to copy ${type} to clipboard`,
				});
			});
		setShowMenu(false);
	};

	const downloadSvg = (
		e: React.MouseEvent,
		svgContent: string,
		fileName: string,
	) => {
		e.preventDefault();
		e.stopPropagation();
		const blob = new Blob([svgContent], { type: "image/svg+xml" });
		const url = URL.createObjectURL(blob);
		const link = document.createElement("a");
		link.href = url;
		link.download = fileName;
		document.body.appendChild(link);
		link.click();
		document.body.removeChild(link);
		URL.revokeObjectURL(url);
		toast.success("Downloading the asset...");
		setShowMenu(false);
	};

	useEffect(() => {
		const handleClickOutside = (event: MouseEvent) => {
			if (menuRef.current && !menuRef.current.contains(event.target as Node)) {
				setShowMenu(false);
			}
		};

		document.addEventListener("mousedown", handleClickOutside);
		return () => {
			document.removeEventListener("mousedown", handleClickOutside);
		};
	}, []);

	const getAsset = <T,>(darkAsset: T, lightAsset: T): T => {
		return theme === "dark" ? darkAsset : lightAsset;
	};

	return (
		<div className="relative">
			<div
				ref={logoRef}
				onContextMenu={handleContextMenu}
				className="cursor-pointer"
			>
				{logo}
			</div>

			{showMenu && (
				<div
					ref={menuRef}
					className="fixed mx-10 z-50 bg-[var(--rubygems-slate)] border border-border p-1 rounded-sm shadow-xl w-56 overflow-hidden animate-fd-dialog-in duration-500"
				>
					<div className="">
						<div className="flex p-0 gap-1 flex-col text-xs">
							<button
								onClick={(e) =>
									copySvgToClipboard(
										e,
										getAsset(logoAssets.darkSvg, logoAssets.whiteSvg),
										"Logo SVG",
									)
								}
								className="flex items-center gap-3 w-full p-2 text-white hover:bg-[var(--rubygems-slate-light)] rounded-md transition-colors cursor-pointer"
							>
								<div className="flex items-center">
									<span className="text-zinc-400/30">[</span>
									<Code className="h-[13.8px] w-[13.8px] mx-[3px]" />
									<span className="text-zinc-400/30">]</span>
								</div>
								<span>Copy Logo as SVG </span>
							</button>
							<hr className="border-border/[60%]" />
							<button
								onClick={(e) =>
									copySvgToClipboard(
										e,
										getAsset(logoAssets.darkWordmark, logoAssets.whiteWordmark),
										"Logo Wordmark",
									)
								}
								className="flex items-center gap-3 w-full p-2 text-white hover:bg-[var(--rubygems-slate-light)] rounded-md transition-colors cursor-pointer"
							>
								<div className="flex items-center">
									<span className="text-zinc-400/30">[</span>
									<Type className="h-[13.8px] w-[13.8px] mx-[3px]" />
									<span className="text-zinc-400/30">]</span>
								</div>
								<span>Copy Logo as Wordmark </span>
							</button>
							<hr className="border-border/[60%]" />
							<button
								onClick={(e) =>
									downloadSvg(
										e,
										getAsset(logoAssets.darkSvg, logoAssets.whiteSvg),
										`rubyauth-logo-${theme}.svg`,
									)
								}
								className="flex items-center gap-3 w-full p-2 text-white hover:bg-[var(--rubygems-slate-light)] rounded-md transition-colors cursor-pointer"
							>
								<div className="flex items-center">
									<span className="text-zinc-400/30">[</span>
									<Code className="h-[13.8px] w-[13.8px] mx-[3px]" />
									<span className="text-zinc-400/30">]</span>
								</div>
								<span>Download Logo SVG</span>
							</button>
						</div>
					</div>
				</div>
			)}
		</div>
	);
}
