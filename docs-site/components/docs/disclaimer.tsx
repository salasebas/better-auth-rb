import { Callout } from "@/components/ui/callout";

export function RubyAuthDisclaimer() {
	return (
		<Callout type="info" title="Independent Ruby project">
			RubyAuth is a community Ruby server library inspired by the Better Auth
			design. It is <strong>not</strong> an official Better Auth product, gem,
			or hosted service. API shapes follow the Ruby implementation in this
			repository, not the upstream TypeScript docs.
		</Callout>
	);
}
