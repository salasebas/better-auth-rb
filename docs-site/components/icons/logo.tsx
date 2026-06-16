import type { SVGProps } from "react";
import { cn } from "@/lib/utils";

const gemPaths = (
	<>
		<polygon points="32 4 58 22 58 46 32 60 6 46 6 22" fill="#e9573f" />
		<polygon
			points="32 4 58 22 32 34 6 22"
			fill="#ffffff"
			fillOpacity="0.22"
		/>
		<polygon
			points="32 34 58 46 32 60 6 46"
			fill="#141c22"
			fillOpacity="0.18"
		/>
	</>
);

export const Logo = ({ className }: { className?: string }) => {
	return (
		<svg
			className={className || "h-5 w-5"}
			width="64"
			height="64"
			viewBox="0 0 64 64"
			fill="none"
			xmlns="http://www.w3.org/2000/svg"
			aria-hidden="true"
		>
			{gemPaths}
		</svg>
	);
};

export const LogoStroke = ({ className }: { className?: string }) => {
	return (
		<svg
			className={cn("size-7 w-7", className)}
			viewBox="0 0 64 64"
			fill="none"
			xmlns="http://www.w3.org/2000/svg"
			aria-hidden="true"
		>
			{gemPaths}
		</svg>
	);
};

/** @deprecated Use Logo instead */
export const BetterAuthLogo = (props: SVGProps<SVGSVGElement>) => {
	return (
		<svg
			{...props}
			width="64"
			height="64"
			viewBox="0 0 64 64"
			fill="none"
			xmlns="http://www.w3.org/2000/svg"
			aria-hidden="true"
		>
			{gemPaths}
		</svg>
	);
};
