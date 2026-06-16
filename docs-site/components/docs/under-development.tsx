import { Callout } from "@/components/ui/callout";

export function UnderDevelopment({ children }: { children?: React.ReactNode }) {
	return (
		<Callout type="warn" title="Under development">
			{children ??
				"This feature exists in upstream Better Auth but is not fully parity-tested in RubyAuth yet. Behavior may change."}
		</Callout>
	);
}
