import { Callout } from "@/components/ui/callout";
import { INDEPENDENCE_NOTICE } from "@/lib/branding";
import { cn } from "@/lib/utils";

export function IndependentProjectNotice({
	className,
}: {
	className?: string;
}) {
	return (
		<Callout type="info" className={cn("pointer-events-auto", className)}>
			{INDEPENDENCE_NOTICE}
		</Callout>
	);
}
